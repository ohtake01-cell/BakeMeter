#!/bin/bash
# shot0: 装填前準備(prepare) — arm_oneshot_grub.sh の前提を1コマンドで整える。
# ============================ 王報告ゲート ============================
# このスクリプトはGRUB本線に触る(王のsudo・実行前に王へ直前報告・Codex監査後のみ)。
# やること:
#   ①旧custom.cfg(TEST-3060-window-onetime等・SHOT0以外)をバックアップ名へ退避(削除しない)
#   ②GRUB_DEFAULT=0 → saved へ変更(/etc/default/grubをバックアップしてから)
#   ③grub-set-default 0 で「既定起動=先頭entry(現行kernel系列)」の挙動を保持
#   ④update-grub → 検証を表示
# 失敗時: /etc/default/grubをバックアップから自動復元して退く(fail-closed)。
# 取り消し: sudo prepare_grub_saved.sh --undo で最新バックアップから復元。
# =====================================================================
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "ERROR: root(sudo)が必要" >&2; exit 1; }

GRUB_FILE=/etc/default/grub
CUSTOM=/boot/grub/custom.cfg
TS=$(date +%Y%m%dT%H%M%S)

if [ "${1:-}" = "--undo" ]; then
  GB=$(ls -t "$GRUB_FILE".bak-preSHOT0-* 2>/dev/null | head -1)
  [ -n "$GB" ] || { echo "ERROR: $GRUB_FILE のバックアップが無い" >&2; exit 1; }
  cp -a "$GB" "$GRUB_FILE"
  CB=$(ls -t "$CUSTOM".bak-preSHOT0-* 2>/dev/null | head -1)
  if [ -n "$CB" ] && [ ! -e "$CUSTOM" ]; then
    cp -a "$CB" "$CUSTOM"
    echo "OK: custom.cfg を $CB から復元"
  fi
  grub-editenv /boot/grub/grubenv unset saved_entry || true
  update-grub
  echo "== undo完了 =="
  grep '^GRUB_DEFAULT=' "$GRUB_FILE"
  exit 0
fi

# ---- preflight(実機無変更) ----
for tool in update-grub grub-set-default grub-editenv; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool が無い(実機は無変更)" >&2; exit 1; }
done
grep -q '^GRUB_DEFAULT=' "$GRUB_FILE" || { echo "ERROR: $GRUB_FILE にGRUB_DEFAULT行が無い" >&2; exit 1; }
CUR_DEF=$(grep '^GRUB_DEFAULT=' "$GRUB_FILE" | head -1)

echo "============================================================"
echo " SHOT0 prepare(王へ直前報告済みであること)"
echo "   現在の既定: $CUR_DEF"
if [ -e "$CUSTOM" ] || [ -L "$CUSTOM" ]; then
  echo "   退避対象custom.cfg(削除しない・先頭3行):"
  sed -n 1,3p "$CUSTOM" | sed 's/^/     | /'
else
  echo "   custom.cfg: 無し(退避不要)"
fi
echo "   変更: GRUB_DEFAULT=saved / grub-set-default 0 / update-grub"
echo "   既定起動は entry 0(現行kernel系列)のまま変わらない"
echo "============================================================"
printf "上記を王へ報告し裁可を得たなら SHOT0-PREP と入力: "
read -r ANS
[ "$ANS" = "SHOT0-PREP" ] || { echo "中止(実機は無変更)"; exit 1; }

# ---- 変更開始(失敗時は/etc/default/grubを自動復元) ----
cp -a "$GRUB_FILE" "$GRUB_FILE.bak-preSHOT0-$TS"
echo "OK: バックアップ $GRUB_FILE.bak-preSHOT0-$TS"
restore_on_fail() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    cp -a "$GRUB_FILE.bak-preSHOT0-$TS" "$GRUB_FILE" || true
    echo "ABORT(exit=$rc): $GRUB_FILE はバックアップから復元済み。" >&2
    echo "  update-grub前の失敗なら実機の起動既定は不変。update-grub中の失敗なら" >&2
    echo "  sudo update-grub を再実行して旧設定でgrub.cfgを焼き直すこと。王へ報告。" >&2
  fi
}
trap restore_on_fail EXIT

if [ -e "$CUSTOM" ] || [ -L "$CUSTOM" ]; then
  mv "$CUSTOM" "$CUSTOM.bak-preSHOT0-$TS"
  echo "OK: custom.cfg → $CUSTOM.bak-preSHOT0-$TS (退避・削除していない)"
fi

sed -i "s/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/" "$GRUB_FILE"
grep -q '^GRUB_DEFAULT=saved$' "$GRUB_FILE" || { echo "ERROR: saved化を書込み後に検証できない" >&2; exit 1; }
grub-set-default 0
update-grub

# ---- 検証(全て表示) ----
echo "== 検証 =="
grep '^GRUB_DEFAULT=' "$GRUB_FILE"
grub-editenv /boot/grub/grubenv list | grep -E '^(saved_entry|next_entry)=' || echo "WARN: saved_entryがgrubenvに見えない"
if [ ! -e "$CUSTOM" ] && [ ! -L "$CUSTOM" ]; then echo "custom.cfg: 無し(退避済み)"; fi
echo
echo "prepare完了。既定起動=entry 0(現行kernel系列)のまま。"
echo "次: sudo bash shot0/scripts/arm_oneshot_grub.sh <image.deb> <headers.deb> (王の引き金)"
echo "取り消し: sudo bash shot0/scripts/prepare_grub_saved.sh --undo"
