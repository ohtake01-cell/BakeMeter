#!/bin/bash
# shot0: 装填前準備(prepare) v3 — arm_oneshot_grub.sh の前提を1コマンドで整える。
# ============================ 王報告ゲート ============================
# GRUB本線に触る(王のsudo・実行前に王へ直前報告・Codex監査合格後のみ)。
# やること:
#   ①旧custom.cfg(TEST等・SHOT0以外)を取引dirへ退避(削除しない)
#   ②grubenvの残留next_entryを解除
#   ③GRUB_DEFAULT=0 → saved へ変更し、saved_entryを「現行kernelの名前付きID」
#     (submenu-ID>gnulinux-<現行ver>-advanced-ID)に固定 — 位置番号0はarmの
#     kernel install後のupdate-grubで別kernelを指し得るため使わない(Codex v2監査P1-1)
#   ④update-grub → 全項目を機械判定で検証
#
# 取引方式: 変更前に原本4点(/etc/default/grub・grub.cfg・grubenv・custom.cfg)を
# 取引dirへ一括保存+metaに実在情報を記録。失敗時trapは同一取引から全復元し、
# 成否を1件ずつ正直報告(必須原本の欠落はCRITICAL・「元々無し」はmetaで区別)。
# --undoも同一取引単位。custom.cfgが今存在するなら(arm後を含め)undoは中止。
# 前提: GRUB_DEFAULT=0 ちょうどのみfull実行。既にsavedは①②のみ(saved_entry不触)。
# 二重実行防止: lockdir + 未undo取引の検出。
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

exists_any() { [ -e "$1" ] || [ -L "$1" ]; }  # dangling symlinkも「存在」と扱う

# restore_file <原本> <実機パス> <required|optional>
#   required: 原本が無い=CRITICAL(バックアップ欠落)。optional: metaで「元々無し」確認済みの物のみ。
restore_file() {
  local src="$1" dst="$2" req="$3"
  if ! exists_any "$src"; then
    if [ "$req" = required ]; then
      echo "  restore: $dst ← ★CRITICAL: 必須原本 $src が欠落。手動確認要。" >&2; return 1
    fi
    echo "  restore: $dst ← 原本なし(metaで元々無しを確認済み)=スキップ"; return 0
  fi
  if cp -a "$src" "$dst"; then echo "  restore: $dst ← OK"; return 0
  else echo "  restore: $dst ← ★CRITICAL: 復元失敗。手動対応要: cp -a $src $dst" >&2; return 1; fi
}

meta_get() { sed -n "s/^$2=//p" "$1" | head -1; }

# ---------------- undo ----------------
if [ "${1:-}" = "--undo" ]; then
  trap CLEAN_LOCK EXIT
  [ -f "$LATEST" ] || { echo "ERROR: 未undoの取引が無い($LATEST)" >&2; exit 1; }
  TXN=$(cat "$LATEST"); [ -d "$TXN" ] || { echo "ERROR: 取引dirが無い: $TXN" >&2; exit 1; }
  if exists_any "$CUSTOM"; then
    echo "ERROR: 現在custom.cfgが存在する(armのSHOT0 entryか別物)。undoはそれを消さない/上書きしない。" >&2
    echo "  先に sudo rollback_shot0.sh で装填を解除してから --undo を再実行。王へ報告。" >&2
    exit 1
  fi
  CUSTOM_WAS=$(meta_get "$TXN/meta" custom_present)
  echo "== undo(取引 $TXN から復元) =="
  RC=0
  restore_file "$TXN/grub.default.orig" "$GRUB_FILE" required || RC=1
  restore_file "$TXN/grubenv.orig"      "$GRUBENV"   required || RC=1
  if [ "$CUSTOM_WAS" = yes ]; then
    restore_file "$TXN/custom.cfg.orig" "$CUSTOM" required || RC=1
  else
    echo "  restore: custom.cfg ← 元々無し(meta)=何もしない"
  fi
  if [ "$RC" -eq 0 ]; then
    # 混成状態でなければ再生成が正道。失敗したら既知正常grub.cfg原本を直接復元。
    if update-grub; then echo "  update-grub: OK(復元済み設定で再生成)"
    else
      echo "  update-grub失敗 → 既知正常grub.cfg原本を直接復元" >&2
      restore_file "$TXN/grub.cfg.orig" "$GRUB_CFG" required || RC=1
    fi
  else
    # 一部復元に失敗=混成状態。update-grubは実行せず既知正常grub.cfgへ直接戻す(Codex v2監査P1-3)。
    echo "  一部復元失敗のためupdate-grubは実行しない。既知正常grub.cfg原本を直接復元する。" >&2
    restore_file "$TXN/grub.cfg.orig" "$GRUB_CFG" required || RC=1
  fi
  if [ "$RC" -eq 0 ]; then mv "$LATEST" "$TXN/undone-$(date +%s)"
  else echo "★復元に失敗があるためlatest markerは残す(再試行可)。王へ報告。" >&2; fi
  echo "== undo後の状態 =="
  grep '^GRUB_DEFAULT=' "$GRUB_FILE" || true
  ENV_LIST=$(grub-editenv "$GRUBENV" list 2>&1) && printf '%s\n' "$ENV_LIST" | grep -E '^(saved_entry|next_entry)=' || echo "(saved_entry/next_entry無し or grubenv読取り不可: 上記参照)"
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
  "GRUB_DEFAULT=saved") MODE=partial ;;
  *) echo "ERROR: 現在の既定が '$CUR_DEF' — entry 0でもsavedでもないため既定保持を保証できない。王へ報告(実機は無変更)。" >&2; exit 1 ;;
esac

# grubenvは読めることを必須にする(読取り失敗を「next_entry無し」と誤判定しない)
ENV_LIST=$(grub-editenv "$GRUBENV" list) || { echo "ERROR: grubenvを読めない(実機は無変更)" >&2; exit 1; }
NEXT_NOW=$(printf '%s\n' "$ENV_LIST" | grep '^next_entry=' || true)

DEFAULT_TARGET=""
if [ "$MODE" = full ]; then
  # 現行kernelの名前付きentry ID(update-grub再生成後も同じkernelを指す)
  CUR_KREL=$(uname -r)
  SUB_ID=$(grep -o "gnulinux-advanced-[^']*" "$GRUB_CFG" | head -1 || true)
  KID=$(grep -o "gnulinux-$CUR_KREL-advanced-[^']*" "$GRUB_CFG" | head -1 || true)
  if [ -z "$SUB_ID" ] || [ -z "$KID" ]; then
    echo "ERROR: grub.cfgから現行kernelの名前付きentry IDを特定できない(SUB='$SUB_ID' KID='$KID')。" >&2
    echo "  位置番号0での固定は行わない(kernel追加後に別kernelを指すため)。王へ報告(実機は無変更)。" >&2
    exit 1
  fi
  DEFAULT_TARGET="$SUB_ID>$KID"
fi

echo "============================================================"
echo " SHOT0 prepare v3(王へ直前報告済みであること) mode=$MODE"
echo "   現在の既定: $CUR_DEF"
[ -n "$DEFAULT_TARGET" ] && echo "   固定先(名前付きID・現行kernel): $DEFAULT_TARGET"
[ -n "$NEXT_NOW" ] && echo "   ⚠残留 $NEXT_NOW → 解除する"
if exists_any "$CUSTOM"; then
  echo "   退避対象custom.cfg(削除しない・先頭3行):"; sed -n 1,3p "$CUSTOM" 2>/dev/null | sed 's/^/     | /' || echo "     | (リンク/読取り不可)"
else
  echo "   custom.cfg: 無し(退避不要)"
fi
echo "============================================================"
printf "上記を王へ報告し裁可を得たなら SHOT0-PREP と入力: "
read -r ANS
[ "$ANS" = "SHOT0-PREP" ] || { echo "中止(実機は無変更)"; exit 1; }

# ---------------- 取引開始(原本一括保存+meta) ----------------
TXN="$STATE_DIR/txn-$(date +%Y%m%dT%H%M%S)-$$"
mkdir "$TXN" || { echo "ERROR: 取引dirを作れない: $TXN (実機は無変更)" >&2; exit 1; }
cp -a "$GRUB_FILE" "$TXN/grub.default.orig"
cp -a "$GRUB_CFG"  "$TXN/grub.cfg.orig"
cp -a "$GRUBENV"   "$TXN/grubenv.orig"
CUSTOM_PRESENT=no
if exists_any "$CUSTOM"; then cp -a "$CUSTOM" "$TXN/custom.cfg.orig"; CUSTOM_PRESENT=yes; fi
for f in grub.default.orig grub.cfg.orig grubenv.orig; do
  exists_any "$TXN/$f" || { echo "ERROR: 必須原本の保存に失敗: $f (実機は無変更のまま中止)" >&2; exit 1; }
done
printf '%s\n' "mode=$MODE" "cur_def=$CUR_DEF" "custom_present=$CUSTOM_PRESENT" \
  "default_target=$DEFAULT_TARGET" "next_now=$NEXT_NOW" > "$TXN/meta"
printf '%s\n' "$TXN" > "$LATEST"
echo "OK: 取引 $TXN に原本を保存(custom_present=$CUSTOM_PRESENT)"

on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "ABORT(exit=$rc): 取引 $TXN から全ファイルを直接復元する(update-grubは実行しない)" >&2
    RC2=0
    restore_file "$TXN/grub.default.orig" "$GRUB_FILE" required || RC2=1
    restore_file "$TXN/grubenv.orig"      "$GRUBENV"   required || RC2=1
    if [ "$CUSTOM_PRESENT" = yes ]; then restore_file "$TXN/custom.cfg.orig" "$CUSTOM" required || RC2=1
    else rm -f "$CUSTOM" 2>/dev/null || true; fi
    restore_file "$TXN/grub.cfg.orig" "$GRUB_CFG" required || RC2=1
    if [ "$RC2" -eq 0 ]; then
      mv "$LATEST" "$TXN/aborted-$(date +%s)" 2>/dev/null || true
      echo "復元完了(起動系4点は取引前と同一ファイル)。王へ報告。" >&2
    else
      echo "★CRITICAL: 復元に失敗した項目がある。上のCRITICAL行を王のsudoで実行すること。latest markerは残す。" >&2
    fi
  fi
  CLEAN_LOCK
}
trap on_exit EXIT

# ---------------- 変更 ----------------
if exists_any "$CUSTOM"; then
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
  grub-set-default "$DEFAULT_TARGET"
  update-grub
fi

# ---------------- 検証(全項目・機械判定。grubenv読取り失敗はFAIL) ----------------
echo "== 検証 =="
V=0
ENV_LIST=$(grub-editenv "$GRUBENV" list) || { echo "[FAIL] grubenvを読めない"; V=1; ENV_LIST=""; }
if [ "$MODE" = full ]; then
  grep -q '^GRUB_DEFAULT=saved$' "$GRUB_FILE" && echo "[PASS] GRUB_DEFAULT=saved" || { echo "[FAIL] GRUB_DEFAULT"; V=1; }
  printf '%s\n' "$ENV_LIST" | grep -qF "saved_entry=$DEFAULT_TARGET" \
    && echo "[PASS] saved_entry=現行kernelの名前付きID" || { echo "[FAIL] saved_entryがID固定になっていない"; V=1; }
  grep -qF "$KID" "$GRUB_CFG" && echo "[PASS] 再生成grub.cfgに現行kernel ID残存" || { echo "[FAIL] grub.cfgに現行kernel IDが無い"; V=1; }
fi
if printf '%s\n' "$ENV_LIST" | grep -q '^next_entry='; then echo "[FAIL] next_entryが残留"; V=1; else echo "[PASS] next_entry無し"; fi
if exists_any "$CUSTOM"; then echo "[FAIL] custom.cfgが残存"; V=1; else echo "[PASS] custom.cfg無し(退避済み)"; fi
[ "$V" -ne 0 ] && exit 1   # FAILがあればon_exitが取引から全復元する

echo
echo "prepare完了(mode=$MODE)。既定起動は現行kernel($(uname -r))に名前で固定。"
echo "次: sudo bash shot0/scripts/arm_oneshot_grub.sh <image.deb> <headers.deb> (王の引き金)"
echo "取り消し: sudo bash shot0/scripts/prepare_grub_saved.sh --undo (取引 $TXN 単位で完全復元)"
