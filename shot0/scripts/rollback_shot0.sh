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
# Codex P1第2〜3ラウンド: 所有判定は全行を許可パターンで照合(arm側と同一判定)。
# SHOT0の生成物だけで構成された実ファイルのみ削除 — 混在・シンボリックリンクは触らない。
custom_cfg_is_shot0_only() {
  local f=/boot/grub/custom.cfg
  [ -L "$f" ] && return 1
  head -1 "$f" | grep -q '^# SHOT0 one-time entry' || return 1
  [ "$(grep -c "^menuentry 'SHOT0-oneshot' {$" "$f")" -eq 1 ] || return 1
  awk '
    /^# SHOT0/ {next}
    /^menuentry '\''SHOT0-oneshot'\'' \{$/ {next}
    /^[ \t]+(search|linux|initrd) [^;{}$]*$/ {next}
    /^\}$/ {next}
    /^[ \t]*$/ {next}
    {exit 1}
  ' "$f" || return 1
  return 0
}
# -e/-Lどちらかで「何かが居る」なら所有判定へ(壊れたリンクも素通りさせない)
if [ -e /boot/grub/custom.cfg ] || [ -L /boot/grub/custom.cfg ]; then
  if custom_cfg_is_shot0_only; then
    rm /boot/grub/custom.cfg
    echo "/boot/grub/custom.cfg (SHOT0専用と厳密判定) を削除した"
  else
    echo "WARN: custom.cfgはあるがSHOT0専用の実ファイルでない(他用途/リンクの可能性) — 触らない。王へ報告。"
  fi
else
  echo "custom.cfg は無い"
fi

echo "== 3. shot0 kernelパッケージ =="
# Codex P1対応: ii以外の半端状態(iF=half-configured/iU=unpacked/rc=設定残り等)も対象にする。
# DKMS失敗やdpkg中断で残った半端パッケージを見逃さない。unのみ除外(未導入)。
PKGS=$(dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\n' 2>/dev/null \
       | awk -F'\t' '$2 ~ /shot0/ && $1 !~ /^un/ {print $2}' || true)
if [ -z "$PKGS" ]; then
  echo "shot0パッケージは入っていない(半端状態も無し)"
elif [ "$PURGE" = "--purge" ]; then
  echo "対象(状態込み):"
  dpkg -l | awk '/shot0/ {print "  " $1 " " $2}'
  # shellcheck disable=SC2086
  apt-get purge -y $PKGS
  update-grub
  echo "purge完了: $PKGS"
  # 残骸検査(パッケージ管理外に残ったファイルを未検知にしない)
  RESIDUE=$(ls -d /boot/*shot0* /lib/modules/*shot0* 2>/dev/null || true)
  if [ -n "$RESIDUE" ]; then
    echo "WARN: purge後も残骸あり — 王へ報告(勝手に消さない):" >&2
    echo "$RESIDUE" >&2
  else
    echo "残骸なし(/boot・/lib/modules確認済み)"
  fi
else
  echo "入っているshot0パッケージ(状態込み・削除するなら --purge を付けて再実行):"
  dpkg -l | awk '/shot0/ {print "  " $1 " " $2}'
fi

echo "== 4. 確認 =="
grub-editenv /boot/grub/grubenv list
echo "現行kernel: $(uname -r) / デフォルト起動は変更していない"
echo "rollback完了"
