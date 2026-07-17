#!/bin/bash
# shot0: 完全rollback。装填解除(next_entry/custom.cfg撤去)と、--purgeでshot0 kernel削除。
# デフォルト起動kernelは元々変えていないので、これで実機は装填前と同一状態に戻る。
# 使い方: sudo rollback_shot0.sh [--purge]
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "ERROR: root(sudo)が必要" >&2; exit 1; }
PURGE=${1:-}

echo "== 1. one-time予約の解除 =="
if grub-editenv /boot/grub/grubenv list | grep -q "^next_entry="; then
  grub-editenv /boot/grub/grubenv unset next_entry
  echo "next_entry を消去した"
else
  echo "next_entry は無い(未装填 or 既に消費済み)"
fi

echo "== 2. custom.cfg撤去 =="
if [ -f /boot/grub/custom.cfg ]; then
  if grep -q "SHOT0" /boot/grub/custom.cfg; then
    rm /boot/grub/custom.cfg
    echo "/boot/grub/custom.cfg (SHOT0) を削除した"
  else
    echo "WARN: custom.cfgはあるがSHOT0以外の内容 — 触らない。王へ報告。"
  fi
else
  echo "custom.cfg は無い"
fi

echo "== 3. shot0 kernelパッケージ =="
PKGS=$(dpkg -l | awk '/shot0/ && $1=="ii" {print $2}' || true)
if [ -z "$PKGS" ]; then
  echo "shot0パッケージは入っていない"
elif [ "$PURGE" = "--purge" ]; then
  # shellcheck disable=SC2086
  apt-get purge -y $PKGS
  update-grub
  echo "purge完了: $PKGS"
else
  echo "入っているshot0パッケージ(削除するなら --purge を付けて再実行):"
  echo "$PKGS"
fi

echo "== 4. 確認 =="
grub-editenv /boot/grub/grubenv list
echo "現行kernel: $(uname -r) / デフォルト起動は変更していない"
echo "rollback完了"
