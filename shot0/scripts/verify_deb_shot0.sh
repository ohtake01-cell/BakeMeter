#!/bin/bash
# shot0: release gate — 差分buildで出来たdebに「新quirkの実行コード」が確実に入っている
# ことを機械確認する(Codex第5ラウンド裁定: ログ文字列の存在確認だけでは不足)。
# 検査項目(全てPASSで初めて装填候補):
#   G1: buildログに CC drivers/pci/quirks.o → 最終リンク → 対象deb生成 の順序がある
#   G2: image debから vmlinuz / System.map を取り出せる
#   G3: System.map に quirk_shot0_nvidia_bar1_64mib が存在する
#   G4: 展開したvmlinux内に新ログ文字列があり、旧版特有の文字列が無い
#   G5: image/headers のPackage・Versionが対で一致し、SHA256を記録する
# 実機・パッケージDB・GRUBには一切触れない(dpkg-deb -x を一時dirへ展開するのみ)。
# 使い方: verify_deb_shot0.sh <linux-image-*.deb> <linux-headers-*.deb> <build.log> <kernel-src-dir>
set -euo pipefail

IMG_DEB=${1:?使い方: verify_deb_shot0.sh <image.deb> <headers.deb> <build.log> <kernel-src-dir>}
HDR_DEB=${2:?headers debも指定}
BUILD_LOG=${3:?build.logを指定}
SRC_DIR=${4:?kernelソースdir(extract-vmlinux用)を指定}
FAIL=0
ok() { echo "[PASS] $1"; }
ng() { echo "[FAIL] $1"; FAIL=1; }

for f in "$IMG_DEB" "$HDR_DEB" "$BUILD_LOG" "$SRC_DIR/scripts/extract-vmlinux"; do
  [ -e "$f" ] || { echo "ERROR: $f が無い" >&2; exit 1; }
done

# G1: buildログの順序(行番号で比較)
L_CC=$(grep -n "CC[[:space:]]\+drivers/pci/quirks\.o" "$BUILD_LOG" | head -1 | cut -d: -f1 || true)
L_LD=$(grep -n "LD[[:space:]]\+vmlinux\b\|LD \[M\]\|Kernel: arch/x86/boot/bzImage" "$BUILD_LOG" | tail -1 | cut -d: -f1 || true)
L_DEB=$(grep -n "building package 'linux-image.*shot0'" "$BUILD_LOG" | head -1 | cut -d: -f1 || true)
if [ -n "$L_CC" ] && [ -n "$L_DEB" ] && [ "$L_CC" -lt "$L_DEB" ]; then
  ok "G1: quirks.o再コンパイル(行$L_CC) → image deb生成(行$L_DEB)の順序"
else
  ng "G1: buildログにquirks.o→deb生成の順序が無い (CC=$L_CC, DEB=$L_DEB)"
fi

# G2: debからvmlinuz/System.mapを取り出す
TMPD=$(mktemp -d -t shot0deb.XXXXXX)
trap 'rm -rf "$TMPD"' EXIT
dpkg-deb -x "$IMG_DEB" "$TMPD"
VMLINUZ=$(find "$TMPD/boot" -maxdepth 1 -name "vmlinuz-*shot0*" | head -1 || true)
SYSMAP=$(find "$TMPD/boot" -maxdepth 1 -name "System.map-*shot0*" | head -1 || true)
if [ -n "$VMLINUZ" ] && [ -n "$SYSMAP" ]; then
  ok "G2: deb内に $(basename "$VMLINUZ") / $(basename "$SYSMAP")"
else
  ng "G2: deb内にvmlinuz/System.mapが見つからない"
fi

# G3: シンボル存在(実行コードとして登録された証拠)
if [ -n "$SYSMAP" ] && grep -q " quirk_shot0_nvidia_bar1_64mib$" "$SYSMAP"; then
  ok "G3: System.mapに quirk_shot0_nvidia_bar1_64mib"
else
  ng "G3: System.mapにquirkシンボルが無い"
fi

# G4: 新文字列あり・旧版特有文字列なし(vmlinuzは圧縮のためextract-vmlinuxで展開)
NEW_STR="memory decode stop not verified"      # 第2ラウンドで追加(新版のみ)
OLD_STR="memory decode stop failed"            # 第1ラウンド版のみ(新版には無い)
if [ -n "$VMLINUZ" ]; then
  VMX="$TMPD/vmlinux.extracted"
  bash "$SRC_DIR/scripts/extract-vmlinux" "$VMLINUZ" > "$VMX" 2>/dev/null || true
  if [ -s "$VMX" ]; then
    HAS_NEW=$(strings "$VMX" | grep -c "$NEW_STR" || true)
    HAS_OLD=$(strings "$VMX" | grep -c "$OLD_STR" || true)
    if [ "$HAS_NEW" -ge 1 ] && [ "$HAS_OLD" -eq 0 ]; then
      ok "G4: 新文字列あり($HAS_NEW)・旧版特有文字列なし"
    else
      ng "G4: 文字列検査不合格 (new=$HAS_NEW, old=$HAS_OLD) — 旧quirk混入の疑い"
    fi
  else
    ng "G4: extract-vmlinuxで展開できない"
  fi
fi

# G5: Package/Version対の一致とSHA256記録
IMG_VER=$(dpkg-deb -f "$IMG_DEB" Version); IMG_PKG=$(dpkg-deb -f "$IMG_DEB" Package)
HDR_VER=$(dpkg-deb -f "$HDR_DEB" Version); HDR_PKG=$(dpkg-deb -f "$HDR_DEB" Package)
if [ "$IMG_VER" = "$HDR_VER" ] && [ "${IMG_PKG#linux-image-}" = "${HDR_PKG#linux-headers-}" ]; then
  ok "G5: image/headers対一致 ($IMG_PKG / $HDR_PKG @ $IMG_VER)"
else
  ng "G5: image/headersの対が不一致 (img=$IMG_PKG@$IMG_VER, hdr=$HDR_PKG@$HDR_VER)"
fi
echo "== SHA256(記録用) =="
sha256sum "$IMG_DEB" "$HDR_DEB"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "release gate: 全項目PASS — このdebは装填候補(実施は王の引き金・Codex合格後)"
else
  echo "release gate: FAILあり — 装填禁止。full build(make clean)へ切り替えを検討し円卓へ報告"
fi
exit "$FAIL"
