#!/bin/bash
# shot0: 装填前準備(prepare) v4 — arm_oneshot_grub.sh の前提を1コマンドで整える。
# ============================ 王報告ゲート ============================
# GRUB本線に触る(王のsudo・実行前に王へ直前報告・Codex監査合格後のみ)。
# 円卓17:16王命の要件: ①原本退避+内容/SHA記録 ②現行kernelへ確実に戻れるsaved_entry
# ③TEST custom.cfgは削除せず退避 ④update-grub後のreadback検証 ⑤段階表示+復元 ⑥dry-run。
#
# 安全設計(Codex監査v2/v3の全指摘反映):
#  - saved_entryは「名前付きID(submenu>gnulinux-<ver>-advanced-…)」で固定。位置番号は使わない。
#  - entry 0が実際に起動するkernel(先頭linux行)と実行中kernelの一致を検査。不一致=中止。
#  - partialモード(既にsaved)はsaved_entryが実行中kernelへ解決する場合のみ通し、名前付きIDへ正規化。
#  - 取引dirへ原本4点+SHA+metaを保存。失敗trapは同一取引から直接復元(update-grubしない)。
#  - undo: custom.cfgが存在すれば中止 / shot0 kernelパッケージが残っていれば中止(--purge先行) /
#    一部復元失敗なら混成のままupdate-grubせず既知正常grub.cfgを直接復元。
#  - 二重実行防止: lockdir+未undo取引検出。grubenv読取り失敗は明示FAIL。
#
# 試験用フック(本番は未設定のまま使う・値を変えるのは非破壊試験のみ):
#   SHOT0_GRUB_FILE / SHOT0_GRUB_CFG / SHOT0_GRUBENV / SHOT0_CUSTOM /
#   SHOT0_STATE_DIR / SHOT0_LOCK / SHOT0_UPDATE_GRUB / SHOT0_DPKG_QUERY
# 使い方: sudo prepare_grub_saved.sh [--dry-run|--undo]
# =====================================================================
set -euo pipefail

GRUB_FILE="${SHOT0_GRUB_FILE:-/etc/default/grub}"
GRUB_CFG="${SHOT0_GRUB_CFG:-/boot/grub/grub.cfg}"
GRUBENV="${SHOT0_GRUBENV:-/boot/grub/grubenv}"
CUSTOM="${SHOT0_CUSTOM:-/boot/grub/custom.cfg}"
STATE_DIR="${SHOT0_STATE_DIR:-/var/backups/shot0-prepare}"
LOCK="${SHOT0_LOCK:-/run/shot0-prepare.lock}"
UPDATE_GRUB="${SHOT0_UPDATE_GRUB:-update-grub}"
DPKG_QUERY="${SHOT0_DPKG_QUERY:-dpkg-query}"
LATEST="$STATE_DIR/latest"
MODE_ARG="${1:-}"

if [ -z "${SHOT0_GRUB_FILE:-}" ] && [ "$(id -u)" -ne 0 ]; then
  [ "$MODE_ARG" = "--dry-run" ] || { echo "ERROR: root(sudo)が必要(--dry-runも本番パスはroot要)" >&2; exit 1; }
fi

exists_any() { [ -e "$1" ] || [ -L "$1" ]; }
meta_get() { sed -n "s/^$2=//p" "$1" | head -1; }
phase() { echo "◆段階: $*"; }

restore_file() { # <原本> <実機パス> <required|optional>
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

mkdir -p "$STATE_DIR"
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "ERROR: 別のprepare/undoが実行中($LOCK)。二重実行しない。" >&2; exit 1
fi
CLEAN_LOCK() { rmdir "$LOCK" 2>/dev/null || true; }

# ---------------- undo ----------------
if [ "$MODE_ARG" = "--undo" ]; then
  trap CLEAN_LOCK EXIT
  [ -f "$LATEST" ] || { echo "ERROR: 未undoの取引が無い($LATEST)" >&2; exit 1; }
  TXN=$(cat "$LATEST"); [ -d "$TXN" ] || { echo "ERROR: 取引dirが無い: $TXN" >&2; exit 1; }
  if exists_any "$CUSTOM"; then
    echo "ERROR: 現在custom.cfgが存在する(armのSHOT0 entryか別物)。undoはそれを消さない/上書きしない。" >&2
    echo "  先に sudo rollback_shot0.sh --purge で装填とshot0 kernelを撤去してから再実行。王へ報告。" >&2
    exit 1
  fi
  # shot0 kernelが残ったままGRUB_DEFAULT=0へ戻すと、entry 0がshot0を指す(Codex v3監査P1-3)
  SHOT0_PKGS=$("$DPKG_QUERY" -W -f='${db:Status-Abbrev}\t${Package}\n' 2>/dev/null \
               | awk -F'\t' '$2 ~ /shot0/ && $1 !~ /^un/ {print $2}' || true)
  if [ -n "$SHOT0_PKGS" ]; then
    echo "ERROR: shot0 kernelパッケージが残っている($SHOT0_PKGS)。" >&2
    echo "  GRUB_DEFAULT=0へ戻すとentry 0がshot0 kernelを指すため、先に sudo rollback_shot0.sh --purge。王へ報告。" >&2
    exit 1
  fi
  phase "undo開始(取引 $TXN)"
  RC=0
  restore_file "$TXN/grub.default.orig" "$GRUB_FILE" required || RC=1
  restore_file "$TXN/grubenv.orig"      "$GRUBENV"   required || RC=1
  CUSTOM_WAS=$(meta_get "$TXN/meta" custom_present)
  if [ "$CUSTOM_WAS" = yes ]; then restore_file "$TXN/custom.cfg.orig" "$CUSTOM" required || RC=1
  else echo "  restore: custom.cfg ← 元々無し(meta)=何もしない"; fi
  if [ "$RC" -eq 0 ]; then
    if "$UPDATE_GRUB"; then echo "  update-grub: OK(復元済み設定で再生成)"
    else
      echo "  update-grub失敗 → 既知正常grub.cfg原本を直接復元" >&2
      restore_file "$TXN/grub.cfg.orig" "$GRUB_CFG" required || RC=1
    fi
  else
    echo "  一部復元失敗=混成状態のためupdate-grubは実行しない。既知正常grub.cfg原本を直接復元。" >&2
    restore_file "$TXN/grub.cfg.orig" "$GRUB_CFG" required || RC=1
  fi
  if [ "$RC" -eq 0 ]; then mv "$LATEST" "$TXN/undone-$(date +%s)"; phase "undo完了"
  else echo "★復元に失敗があるためlatest markerは残す(再試行可)。王へ報告。" >&2; fi
  grep '^GRUB_DEFAULT=' "$GRUB_FILE" || true
  if ENV_LIST=$(grub-editenv "$GRUBENV" list 2>&1); then
    printf '%s\n' "$ENV_LIST" | grep -E '^(saved_entry|next_entry)=' || echo "(saved_entry/next_entry無し)"
  else echo "WARN: grubenv読取り不可: $ENV_LIST" >&2; fi
  exit "$RC"
fi

# ---------------- preflight(実機無変更) ----------------
trap CLEAN_LOCK EXIT
phase "前提検査(実機無変更)"
for tool in grub-editenv; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool が無い(実機は無変更)" >&2; exit 1; }
done
command -v "${UPDATE_GRUB%% *}" >/dev/null || { echo "ERROR: $UPDATE_GRUB が無い(実機は無変更)" >&2; exit 1; }
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
ENV_LIST=$(grub-editenv "$GRUBENV" list) || { echo "ERROR: grubenvを読めない(実機は無変更)" >&2; exit 1; }
NEXT_NOW=$(printf '%s\n' "$ENV_LIST" | grep '^next_entry=' || true)
SAVED_NOW=$(printf '%s\n' "$ENV_LIST" | sed -n 's/^saved_entry=//p' | head -1)

CUR_KREL=$(uname -r)
# entry 0が実際に起動するkernel(grub.cfg先頭のlinux行)と実行中kernelの一致検査(Codex v3監査P1-1)
ENTRY0_KVER=$(grep -m1 -o 'vmlinuz-[^ ]*' "$GRUB_CFG" | head -1 | sed 's/^vmlinuz-//' || true)
# 実行中kernelの名前付きIDを「同一階層」から構造的に抽出(Codex v3監査P2-1)
IDPAIR=$(awk -v kver="$CUR_KREL" -v sq="'" '
  /^submenu / { i = index($0, "gnulinux-advanced-"); if (i) { r = substr($0, i); q = index(r, sq); cur = substr(r, 1, q-1) } }
  cur != "" {
    s = "gnulinux-" kver "-advanced-"
    i = index($0, s)
    if (i) { r = substr($0, i); q = index(r, sq); print cur ">" substr(r, 1, q-1); exit }
  }
' "$GRUB_CFG" || true)
DEFAULT_TARGET="$IDPAIR"

if [ "$MODE" = full ]; then
  if [ -z "$ENTRY0_KVER" ] || [ "$ENTRY0_KVER" != "$CUR_KREL" ]; then
    echo "ERROR: entry 0が起動するkernel('$ENTRY0_KVER')と実行中kernel('$CUR_KREL')が不一致。" >&2
    echo "  既定保持を保証できないため中止。王へ報告(実機は無変更)。" >&2
    exit 1
  fi
  [ -n "$DEFAULT_TARGET" ] || { echo "ERROR: grub.cfgから実行中kernelの名前付きID(同一階層)を特定できない。中止(実機は無変更)。" >&2; exit 1; }
else
  # partial: 既存saved_entryが実行中kernelへ解決する場合のみ通す(Codex v3監査P1-2)
  [ -n "$DEFAULT_TARGET" ] || { echo "ERROR: 名前付きIDを特定できずpartial検証不能。中止(実機は無変更)。" >&2; exit 1; }
  if [ "$SAVED_NOW" = "$DEFAULT_TARGET" ]; then
    : # 既に名前付きIDで実行中kernelを指している
  elif [ "$SAVED_NOW" = "0" ] && [ "$ENTRY0_KVER" = "$CUR_KREL" ]; then
    : # 数値0だがentry 0=実行中kernelを実測確認 → 名前付きIDへ正規化する(挙動不変)
  else
    echo "ERROR: 既存saved_entry='$SAVED_NOW'が実行中kernel($CUR_KREL)へ解決すると確認できない。" >&2
    echo "  勝手に変更しない。王へ報告(実機は無変更)。" >&2
    exit 1
  fi
fi

echo "============================================================"
echo " SHOT0 prepare v4(王へ直前報告済みであること) mode=$MODE"
echo "   現在の既定: $CUR_DEF / saved_entry='${SAVED_NOW:-無し}'"
echo "   entry 0のkernel: ${ENTRY0_KVER:-特定不能} / 実行中: $CUR_KREL"
echo "   固定先(名前付きID): $DEFAULT_TARGET"
[ -n "$NEXT_NOW" ] && echo "   ⚠残留 $NEXT_NOW → 解除する"
if exists_any "$CUSTOM"; then
  echo "   退避対象custom.cfg(削除しない・先頭3行):"; sed -n 1,3p "$CUSTOM" 2>/dev/null | sed 's/^/     | /' || echo "     | (リンク/読取り不可)"
else
  echo "   custom.cfg: 無し(退避不要)"
fi
echo "============================================================"
if [ "$MODE_ARG" = "--dry-run" ]; then
  echo "dry-run: ここまでの検査のみ・実機は無変更で終了(取引も作らない)"
  exit 0
fi
printf "上記を王へ報告し裁可を得たなら SHOT0-PREP と入力: "
read -r ANS
[ "$ANS" = "SHOT0-PREP" ] || { echo "中止(実機は無変更)"; exit 1; }

# ---------------- 取引開始(原本一括保存+SHA+meta) ----------------
phase "取引開始(原本退避)"
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
{ printf '%s\n' "mode=$MODE" "cur_def=$CUR_DEF" "custom_present=$CUSTOM_PRESENT" \
    "default_target=$DEFAULT_TARGET" "next_now=$NEXT_NOW" "saved_now=$SAVED_NOW" "ts=$(date -Iseconds)"
  echo "== sha256 =="
  (cd "$TXN" && sha256sum ./*.orig)
} > "$TXN/meta"
printf '%s\n' "$TXN" > "$LATEST"
echo "OK: 取引 $TXN に原本を保存(custom_present=$CUSTOM_PRESENT)"
sed -n '/== sha256 ==/,$p' "$TXN/meta"

on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "ABORT(exit=$rc): 取引 $TXN から全ファイルを直接復元する(update-grubは実行しない)" >&2
    RC2=0
    restore_file "$TXN/grub.default.orig" "$GRUB_FILE" required || RC2=1
    restore_file "$TXN/grubenv.orig"      "$GRUBENV"   required || RC2=1
    if [ "$CUSTOM_PRESENT" = yes ]; then restore_file "$TXN/custom.cfg.orig" "$CUSTOM" required || RC2=1
    else
      rm -f "$CUSTOM" 2>/dev/null || true
      if exists_any "$CUSTOM"; then echo "  restore: ★CRITICAL: 残骸custom.cfgを除去できない" >&2; RC2=1; fi
    fi
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
phase "変更適用"
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
fi
grub-editenv "$GRUBENV" set "saved_entry=$DEFAULT_TARGET"
if [ "$MODE" = full ]; then
  phase "update-grub(再生成)"
  "$UPDATE_GRUB"
fi

# ---------------- 検証(readback・機械判定) ----------------
phase "readback検証"
V=0
ENV_OK=1
ENV_LIST=$(grub-editenv "$GRUBENV" list) || { echo "[FAIL] grubenvを読めない"; V=1; ENV_OK=0; ENV_LIST=""; }
if [ "$MODE" = full ]; then
  grep -q '^GRUB_DEFAULT=saved$' "$GRUB_FILE" && echo "[PASS] GRUB_DEFAULT=saved" || { echo "[FAIL] GRUB_DEFAULT"; V=1; }
  grep -qF "${DEFAULT_TARGET#*>}" "$GRUB_CFG" && echo "[PASS] 再生成grub.cfgに現行kernel ID残存" || { echo "[FAIL] grub.cfgに現行kernel IDが無い"; V=1; }
fi
if [ "$ENV_OK" -eq 1 ]; then
  printf '%s\n' "$ENV_LIST" | grep -qF "saved_entry=$DEFAULT_TARGET" \
    && echo "[PASS] saved_entry=現行kernelの名前付きID" || { echo "[FAIL] saved_entryがID固定になっていない"; V=1; }
  printf '%s\n' "$ENV_LIST" | grep -q '^next_entry=' && { echo "[FAIL] next_entryが残留"; V=1; } || echo "[PASS] next_entry無し"
else
  echo "[SKIP] saved_entry/next_entry検証(grubenv読取り不可のため判定不能=FAIL扱い)"
fi
if exists_any "$CUSTOM"; then echo "[FAIL] custom.cfgが残存"; V=1; else echo "[PASS] custom.cfg無し(退避済み)"; fi
[ "$V" -ne 0 ] && exit 1   # FAILがあればon_exitが取引から全復元する

echo
phase "prepare完了(mode=$MODE)"
echo "既定起動は現行kernel($CUR_KREL)へ名前付きIDで固定(armのkernel追加後も不変)。"
echo "次: sudo bash shot0/scripts/arm_oneshot_grub.sh <image.deb> <headers.deb> (王の引き金)"
echo "取り消し: sudo bash shot0/scripts/prepare_grub_saved.sh --undo (取引 $TXN 単位で完全復元)"
