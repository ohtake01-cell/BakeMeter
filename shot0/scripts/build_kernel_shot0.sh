#!/bin/bash
# shot0: kernel packageのbuild(userland作業のみ)。
#   - installしない / GRUBに触らない / 実機設定を一切変えない
#   - 王国は3090単独で稼働中のため nice -n19 でビルド(数時間見込み・Xeon E5 12core)
# 使い方: build_kernel_shot0.sh
#   環境変数: BUILD_ROOT(既定 ~/shot0_build)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
BUILD_ROOT=${BUILD_ROOT:-"$HOME/shot0_build"}
KVER=$(uname -r)
RUNCFG="/boot/config-$KVER"

echo "== shot0 kernel build: 実行中kernel=$KVER =="

# ---- preflight(足りない物は列挙して止まる。勝手にapt installしない) ----
MISSING=()
for CMD in gcc make flex bison bc fakeroot dpkg-deb rsync; do
  command -v "$CMD" >/dev/null || MISSING+=("$CMD")
done
# bindeb-pkg/依存工程が要求するパッケージを先に全数検査(逐次停止の往復を防ぐ)
# gawk=modules.builtin.ranges生成(実機で不足実証) / zstd=モジュール圧縮 / dwarves=BTF(pahole)
for PKG in build-essential debhelper libdw-dev libelf-dev libssl-dev libncurses-dev kmod cpio gawk zstd dwarves; do
  dpkg -s "$PKG" >/dev/null 2>&1 || MISSING+=("$PKG")
done
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "ERROR: 不足: ${MISSING[*]}" >&2
  echo "  実行: sudo apt-get install -y ${MISSING[*]}" >&2
  exit 1
fi
[ -r "$RUNCFG" ] || { echo "ERROR: $RUNCFG が読めない" >&2; exit 1; }
grep -q "^CONFIG_PCI_QUIRKS=y" "$RUNCFG" || { echo "ERROR: CONFIG_PCI_QUIRKS=y でない — built-in quirk前提が崩れる" >&2; exit 1; }

AVAIL_GB=$(df -BG --output=avail "$HOME" | tail -1 | tr -dc '0-9')
if [ "$AVAIL_GB" -lt 50 ]; then
  echo "ERROR: 空きディスク${AVAIL_GB}GB < 50GB — kernel buildには足りない可能性" >&2
  exit 1
fi

mkdir -p "$BUILD_ROOT"
cd "$BUILD_ROOT"

# ---- source取得(apt-get source。deb-src必須) ----
SRC_DIR=$(find "$BUILD_ROOT" -maxdepth 1 -type d -name "linux-*" | head -1 || true)
if [ -z "$SRC_DIR" ]; then
  echo "== apt-get source linux-image-unsigned-$KVER =="
  if ! apt-get source "linux-image-unsigned-$KVER"; then
    echo "ERROR: apt-get source失敗。/etc/apt/sources.list の deb-src 有効化が必要:" >&2
    echo "  sudo sed -i 's/^# deb-src/deb-src/' /etc/apt/sources.list && sudo apt-get update" >&2
    echo "  (Ubuntu 26.04のdeb822形式なら /etc/apt/sources.list.d/ubuntu.sources の Types: に deb-src を追加)" >&2
    exit 1
  fi
  SRC_DIR=$(find "$BUILD_ROOT" -maxdepth 1 -type d -name "linux-*" | head -1)
fi
[ -n "$SRC_DIR" ] || { echo "ERROR: ソースツリーが見つからない" >&2; exit 1; }
echo "== ソースツリー: $SRC_DIR =="

# ---- quirk適用 + 静的検証(FAILなら進まない) ----
bash "$HERE/apply_shot0_patch.sh" "$SRC_DIR"
bash "$HERE/verify_static.sh" "$SRC_DIR"

# ---- config: 実行中configを引き継ぎ、署名鍵とdebug情報だけ外す ----
cd "$SRC_DIR"
cp "$RUNCFG" .config
scripts/config --set-str SYSTEM_TRUSTED_KEYS ""
scripts/config --set-str SYSTEM_REVOCATION_KEYS ""
scripts/config --disable DEBUG_INFO || true
scripts/config --enable DEBUG_INFO_NONE || true
scripts/config --disable DEBUG_INFO_DWARF5 || true
scripts/config --disable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT || true
make olddefconfig
grep -q "^CONFIG_PCI_QUIRKS=y" .config || { echo "ERROR: build configでCONFIG_PCI_QUIRKS=yが落ちた" >&2; exit 1; }

# ---- build(deb生成のみ・install無し) ----
echo "== build開始: nice -n19 make -j$(nproc) bindeb-pkg LOCALVERSION=+shot0 =="
nice -n19 make -j"$(nproc)" bindeb-pkg LOCALVERSION=+shot0

echo "== 生成物とSHA256(円卓報告用) =="
sha256sum "$BUILD_ROOT"/linux-*shot0*.deb
echo
echo "buildここまで。installとGRUB予約は arm_oneshot_grub.sh — 実行前に王へ直前報告すること。"
