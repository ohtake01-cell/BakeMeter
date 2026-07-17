#!/bin/bash
# shot0: kernelソースツリーへquirkを追記し、監査用diffを出す。
# ビルドも実機設定変更も一切しない(userland・ソースツリー内のみ)。
# 使い方: apply_shot0_patch.sh <kernel-source-dir>
set -euo pipefail

SRC_DIR=${1:?使い方: apply_shot0_patch.sh <kernel-source-dir>}
HERE=$(cd "$(dirname "$0")" && pwd)
SNIPPET="$HERE/../src/shot0_quirk.c"
QUIRKS="$SRC_DIR/drivers/pci/quirks.c"
EVID_DIR="$SRC_DIR/shot0_evidence"

[ -f "$SNIPPET" ] || { echo "ERROR: snippetが無い: $SNIPPET" >&2; exit 1; }
[ -f "$QUIRKS" ]  || { echo "ERROR: quirks.cが無い: $QUIRKS (kernelソースツリーを指定)" >&2; exit 1; }

if grep -q "SHOT0 BEGIN" "$QUIRKS"; then
  echo "既に適用済み(SHOT0 BEGINあり) — 二重適用しない"
  exit 0
fi

mkdir -p "$EVID_DIR"
cp -a "$QUIRKS" "$EVID_DIR/quirks.c.orig"

{ echo ""; cat "$SNIPPET"; } >> "$QUIRKS"

# 監査用diff(Codex監査観点: source diff)
DIFF_FILE="$EVID_DIR/shot0_quirks.diff"
diff -u "$EVID_DIR/quirks.c.orig" "$QUIRKS" > "$DIFF_FILE" || true

echo "== 適用完了。監査用diff: $DIFF_FILE =="
cat "$DIFF_FILE"
echo "== SHA256 =="
sha256sum "$SNIPPET" "$QUIRKS" "$DIFF_FILE"
echo
echo "次: verify_static.sh $SRC_DIR で掛け所の順序と定数を機械確認すること"
