#!/bin/bash
# shot0: 装填前準備(prepare) v2 — arm_oneshot_grub.sh の前提を1コマンドで整える。
# ============================ 王報告ゲート ============================
# GRUB本線に触る(王のsudo・実行前に王へ直前報告・Codex監査合格後のみ)。
# やること:
#   ①旧custom.cfg(TEST等・SHOT0以外)を取引dirへ退避(削除しない)
#   ②grubenvの残留next_entryを解除(残っていると次回起動がentry 0にならない)
#   ③GRUB_DEFAULT=0 → saved へ変更 + grub-set-default 0(既定起動の挙動を保持)
#   ④update-grub → 検証(saved化/saved_entry=0/next_entry無し/grub.cfgに現行kernel)
#
# 取引方式(Codex監査対応): 変更前に「/etc/default/grub・/boot/grub/grub.cfg・
# grubenv・custom.cfg」の原本を取引dirへ一括保存。失敗時はtrapが同じ取引から
# 全ファイルを復元し、復元の成否を1件ずつ正直に報告する。--undoも同じ取引単位。
# 前提検査: GRUB_DEFAULT=0 ちょうどの環境のみ本編を実行(=2や名前指定は中止)。
# 既にsavedの環境は①②のみ行い、saved_entryには触らない(既定を変えない)。
# 二重実行防止: lock + 未undo取引が残っていれば中止。
# =====================================================================
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "ERROR: root(sudo)が必要" >&2; exit 1; }

GRUB_FILE=/etc/default/grub
GRUB_CFG=/boot/grub/grub.cfg
GRUBENV=/boot/grub/grubenv
CUSTOM=/boot/grub/custom.cfg
STATE_DIR=/var/backups/shot0-prepare
LATEST="$STATE_DIR/latest"
LOCK=/run/shot0-prepare.lock

mkdir -p "$STATE_DIR"
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "ERROR: 別のprepare/undoが実行中($LOCK)。二重実行しない。" >&2; exit 1
fi
CLEAN_LOCK() { rmdir "$LOCK" 2>/dev/null || true; }

restore_file() { # restore_file <取引内の原本> <実機パス>
  local src="$1" dst="$2"
  if [ ! -e "$src" ]; then echo "  restore: $dst ← 原本なし(取引時に存在せず)=スキップ"; return 0; fi
  if cp -a "$src" "$dst"; then echo "  restore: $dst ← OK"; return 0
  else echo "  restore: $dst ← ★CRITICAL: 復元失敗。手動対応要: cp -a $src $dst" >&2; return 1; fi
}

# ---------------- undo ----------------
if [ "${1:-}" = "--undo" ]; then
  trap CLEAN_LOCK EXIT
  [ -f "$LATEST" ] || { echo "ERROR: 未undoの取引が無い($LATEST)" >&2; exit 1; }
  TXN=$(cat "$LATEST"); [ -d "$TXN" ] || { echo "ERROR: 取引dirが無い: $TXN" >&2; exit 1; }
  if { [ -e "$CUSTOM" ] || [ -L "$CUSTOM" ]; } && [ -e "$TXN/custom.cfg.orig" ]; then
    echo "ERROR: 現在custom.cfgが存在する(arm後の可能性)。上書きundoしない。先にrollback_shot0.shで整理し王へ報告。" >&2
    exit 1
  fi
  echo "== undo(取引 $TXN から全ファイル復元) =="
  RC=0
  restore_file "$TXN/grub.default.orig" "$GRUB_FILE" || RC=1
  restore_file "$TXN/grubenv.orig"      "$GRUBENV"   || RC=1
  restore_file "$TXN/custom.cfg.orig"   "$CUSTOM"    || RC=1
  if update-grub; then echo "  update-grub: OK(復元した設定で再生成)"
  else
    echo "  update-grub失敗 → 取引保存のgrub.cfg原本を直接復元する" >&2
    restore_file "$TXN/grub.cfg.orig" "$GRUB_CFG" || RC=1
  fi
  [ "$RC" -eq 0 ] && mv "$LATEST" "$TXN/undone-$(date +%s)" || echo "★復元に失敗があるためlatest markerは残す(再試行可)" >&2
  echo "== undo後の状態 =="
  grep '^GRUB_DEFAULT=' "$GRUB_FILE"; grub-editenv "$GRUBENV" list | grep -E '^(saved_entry|next_entry)=' || echo "(saved_entry/next_entry無し)"
  exit "$RC"
fi

# ---------------- preflight(実機無変更) ----------------
trap CLEAN_LOCK EXIT
for tool in update-grub grub-set-default grub-editenv; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool が無い(実機は無変更)" >&2; exit 1; }
done
if [ -f "$LATEST" ]; then
  echo "ERROR: 未undoのprepare取引が残っている($(cat "$LATEST"))。二重prepare禁止。戻すなら --undo。" >&2; exit 1
fi
N_DEF=$(grep -c '^GRUB_DEFAULT=' "$GRUB_FILE" || true)
CUR_DEF=$(grep '^GRUB_DEFAULT=' "$GRUB_FILE" | head -1 || true)
[ "$N_DEF" -eq 1 ] || { echo "ERROR: GRUB_DEFAULT行が1行でない($N_DEF行)。手動確認要(実機は無変更)。" >&2; exit 1; }
MODE=""
case "$CUR_DEF" in
  "GRUB_DEFAULT=0")     MODE=full ;;
  "GRUB_DEFAULT=saved") MODE=partial ;;  # 既にsaved: custom退避+next_entry解除のみ。saved_entryは触らない
  *) echo "ERROR: 現在の既定が '$CUR_DEF' — entry 0でも savedでもないため、既定保持を保証できない。王へ報告(実機は無変更)。" >&2; exit 1 ;;
esac
NEXT_NOW=$(grub-editenv "$GRUBENV" list 2>/dev/null | grep '^next_entry=' || true)

echo "============================================================"
echo " SHOT0 prepare v2(王へ直前報告済みであること) mode=$MODE"
echo "   現在の既定: $CUR_DEF"
[ -n "$NEXT_NOW" ] && echo "   ⚠残留 $NEXT_NOW → 解除する(次回起動を汚染するため)"
if [ -e "$CUSTOM" ] || [ -L "$CUSTOM" ]; then
  echo "   退避対象custom.cfg(削除しない・先頭3行):"; sed -n 1,3p "$CUSTOM" | sed 's/^/     | /'
else
  echo "   custom.cfg: 無し(退避不要)"
fi
if [ "$MODE" = full ]; then
  echo "   変更: GRUB_DEFAULT=saved / grub-set-default 0 / update-grub(既定起動=先頭entryのまま)"
else
  echo "   変更: custom退避+next_entry解除のみ(GRUB_DEFAULT/saved_entryは触らない)"
fi
echo "============================================================"
printf "上記を王へ報告し裁可を得たなら SHOT0-PREP と入力: "
read -r ANS
[ "$ANS" = "SHOT0-PREP" ] || { echo "中止(実機は無変更)"; exit 1; }

# ---------------- 取引開始(原本一括保存) ----------------
TXN="$STATE_DIR/txn-$(date +%Y%m%dT%H%M%S)-$$"
mkdir "$TXN" || { echo "ERROR: 取引dirを作れない: $TXN (実機は無変更)" >&2; exit 1; }
cp -a "$GRUB_FILE" "$TXN/grub.default.orig"
cp -a "$GRUB_CFG"  "$TXN/grub.cfg.orig"
cp -a "$GRUBENV"   "$TXN/grubenv.orig"
{ [ -e "$CUSTOM" ] || [ -L "$CUSTOM" ]; } && cp -a "$CUSTOM" "$TXN/custom.cfg.orig"
printf '%s\n' "mode=$MODE" "cur_def=$CUR_DEF" "next_now=$NEXT_NOW" > "$TXN/meta"
printf '%s\n' "$TXN" > "$LATEST"
echo "OK: 取引 $TXN に原本4点を保存"

on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "ABORT(exit=$rc): 取引 $TXN から全ファイルを復元する" >&2
    RC2=0
    restore_file "$TXN/grub.default.orig" "$GRUB_FILE" || RC2=1
    restore_file "$TXN/grubenv.orig"      "$GRUBENV"   || RC2=1
    restore_file "$TXN/custom.cfg.orig"   "$CUSTOM"    || RC2=1
    restore_file "$TXN/grub.cfg.orig"     "$GRUB_CFG"  || RC2=1
    if [ "$RC2" -eq 0 ]; then
      mv "$LATEST" "$TXN/aborted-$(date +%s)" 2>/dev/null || true
      echo "復元完了(起動系は取引前と同一ファイル)。王へ報告。" >&2
    else
      echo "★CRITICAL: 復元に失敗した項目がある。上のCRITICAL行のコマンドを王のsudoで実行すること。" >&2
    fi
  fi
  CLEAN_LOCK
}
trap on_exit EXIT

# ---------------- 変更 ----------------
if [ -e "$CUSTOM" ] || [ -L "$CUSTOM" ]; then
  mv "$CUSTOM" "$TXN/custom.cfg.moved"
  echo "OK: custom.cfg → $TXN/custom.cfg.moved (退避・削除していない)"
fi
if [ -n "$NEXT_NOW" ]; then
  grub-editenv "$GRUBENV" unset next_entry
  echo "OK: 残留next_entryを解除(原本はgrubenv.origに保存済み)"
fi
if [ "$MODE" = full ]; then
  sed -i "s/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/" "$GRUB_FILE"
  [ "$(grep -c '^GRUB_DEFAULT=saved$' "$GRUB_FILE")" -eq 1 ] || { echo "ERROR: saved化を検証できない" >&2; exit 1; }
  grub-set-default 0
  update-grub
fi

# ---------------- 検証(全項目・機械判定) ----------------
echo "== 検証 =="
V=0
if [ "$MODE" = full ]; then
  grep -q '^GRUB_DEFAULT=saved$' "$GRUB_FILE" && echo "[PASS] GRUB_DEFAULT=saved" || { echo "[FAIL] GRUB_DEFAULT"; V=1; }
  grub-editenv "$GRUBENV" list | grep -q '^saved_entry=0$' && echo "[PASS] saved_entry=0" || { echo "[FAIL] saved_entry"; V=1; }
  grep -q "$(uname -r)" "$GRUB_CFG" && echo "[PASS] grub.cfgに現行kernel($(uname -r))" || { echo "[FAIL] grub.cfgが不完全の疑い"; V=1; }
fi
grub-editenv "$GRUBENV" list | grep -q '^next_entry=' && { echo "[FAIL] next_entryが残留"; V=1; } || echo "[PASS] next_entry無し"
{ [ ! -e "$CUSTOM" ] && [ ! -L "$CUSTOM" ]; } && echo "[PASS] custom.cfg無し(退避済み)" || { echo "[FAIL] custom.cfgが残存"; V=1; }
[ "$V" -ne 0 ] && exit 1   # FAILがあればon_exitが取引から全復元する

echo
echo "prepare完了(mode=$MODE)。既定起動は変更前と同じ挙動。"
echo "次: sudo bash shot0/scripts/arm_oneshot_grub.sh <image.deb> <headers.deb> (王の引き金)"
echo "取り消し: sudo bash shot0/scripts/prepare_grub_saved.sh --undo (取引 $TXN 単位で完全復元)"
