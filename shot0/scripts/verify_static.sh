#!/bin/bash
# shot0: 静的検証(非GPU・実機無変更)。実ソースツリーで設計の前提を機械確認する。
#   V1: pci_setup_device()内で pci_fixup_early が pci_read_bases より前に呼ばれること(掛け所)
#   V2: dev->cfg_size が early fixup より前に設定されること(pci_find_ext_capabilityの前提)
#   V3: 使用するPCI_REBAR_*定数が実ツリーに存在すること
#   V4: quirks.c にSHOT0が正しく1回だけ入っていること(適用後のみ)
#   V5: 実行中kernelの CONFIG_PCI_QUIRKS=y (built-in quirk前提)
#   V6: quirks.c が <linux/dmi.h> をincludeしていること(DMI機体ガードの前提)
#       + 実機DMIが MacPro6,1 であること(このスクリプトを実機で走らせた時のみ)
# 使い方: verify_static.sh <kernel-source-dir>
set -euo pipefail

SRC_DIR=${1:?使い方: verify_static.sh <kernel-source-dir>}
PROBE="$SRC_DIR/drivers/pci/probe.c"
QUIRKS="$SRC_DIR/drivers/pci/quirks.c"
REGS="$SRC_DIR/include/uapi/linux/pci_regs.h"
FAIL=0

say()  { echo "[$1] $2"; }
ok()   { say "PASS" "$1"; }
ng()   { say "FAIL" "$1"; FAIL=1; }

[ -f "$PROBE" ] || { echo "ERROR: $PROBE が無い" >&2; exit 1; }

# pci_setup_device() の本体だけ切り出す
BODY=$(awk '/^int pci_setup_device\(/{f=1} f{print} f&&/^}/{exit}' "$PROBE")
[ -n "$BODY" ] || { ng "V1: pci_setup_device() が probe.c に見つからない"; echo "$FAIL"; exit 1; }

# V1: fixup_early が pci_read_bases より前
L_FIXUP=$(echo "$BODY" | grep -n "pci_fixup_device(pci_fixup_early" | head -1 | cut -d: -f1 || true)
L_BASES=$(echo "$BODY" | grep -n "pci_read_bases" | head -1 | cut -d: -f1 || true)
if [ -n "$L_FIXUP" ] && [ -n "$L_BASES" ] && [ "$L_FIXUP" -lt "$L_BASES" ]; then
  ok "V1: pci_setup_device内 fixup_early(行$L_FIXUP) < pci_read_bases(行$L_BASES)"
else
  ng "V1: fixup_early($L_FIXUP)とpci_read_bases($L_BASES)の順序が確認できない — EARLY相の前提崩れ。中止して円卓へ"
fi

# V2: cfg_size 設定が fixup_early より前(pci_find_ext_capabilityはcfg_size>256が前提)
L_CFG=$(echo "$BODY" | grep -n "cfg_size" | head -1 | cut -d: -f1 || true)
if [ -n "$L_CFG" ] && [ -n "$L_FIXUP" ] && [ "$L_CFG" -lt "$L_FIXUP" ]; then
  ok "V2: cfg_size設定(行$L_CFG) < fixup_early(行$L_FIXUP)"
else
  ng "V2: cfg_size($L_CFG)がfixup_early($L_FIXUP)より前と確認できない — ext capability探索が失敗しquirkは何もしない(安全側)が、shotの意味が無い"
fi

# V3: 定数
for SYM in PCI_EXT_CAP_ID_REBAR PCI_REBAR_CAP PCI_REBAR_CTRL \
           PCI_REBAR_CTRL_BAR_IDX PCI_REBAR_CTRL_NBAR_MASK PCI_REBAR_CTRL_NBAR_SHIFT \
           PCI_REBAR_CTRL_BAR_SIZE PCI_REBAR_CTRL_BAR_SHIFT; do
  if grep -q "define[[:space:]]\+$SYM\b" "$REGS" 2>/dev/null; then
    ok "V3: $SYM あり"
  else
    ng "V3: $SYM が $REGS に無い"
  fi
done

# V4: SHOT0の入り方(適用後のみ検査)
if grep -q "SHOT0 BEGIN" "$QUIRKS" 2>/dev/null; then
  N_BEGIN=$(grep -c "SHOT0 BEGIN" "$QUIRKS")
  N_DECL=$(grep -c "DECLARE_PCI_FIXUP_EARLY(PCI_VENDOR_ID_NVIDIA, 0x2\(204\|504\), quirk_shot0_nvidia_bar1_64mib)" "$QUIRKS")
  if [ "$N_BEGIN" -eq 1 ] && [ "$N_DECL" -eq 2 ]; then
    ok "V4: SHOT0ブロック1個・DECLARE 2本(2204/2504)"
  else
    ng "V4: SHOT0の入り方が異常 (BEGIN=$N_BEGIN, DECLARE=$N_DECL)"
  fi
  if grep -E "DECLARE_PCI_FIXUP_(HEADER|FINAL|ENABLE)\(.*shot0" "$QUIRKS" >/dev/null; then
    ng "V4: EARLY以外の相にshot0が登録されている"
  else
    ok "V4: 相はEARLYのみ"
  fi
else
  say "SKIP" "V4: quirks.c未適用(apply_shot0_patch.sh後に再実行)"
fi

# V5: 実行中kernelのCONFIG_PCI_QUIRKS(このスクリプトを実機で走らせた時のみ意味あり)
RUNCFG="/boot/config-$(uname -r)"
if [ -r "$RUNCFG" ]; then
  if grep -q "^CONFIG_PCI_QUIRKS=y" "$RUNCFG"; then
    ok "V5: CONFIG_PCI_QUIRKS=y ($RUNCFG)"
  else
    ng "V5: CONFIG_PCI_QUIRKS=y でない ($RUNCFG)"
  fi
else
  say "SKIP" "V5: $RUNCFG が読めない(実機で再実行)"
fi

# V6: DMI機体ガードの前提(quirkはdmi_match(DMI_PRODUCT_NAME,"MacPro6,1")を使う)
if grep -q '#include <linux/dmi.h>' "$QUIRKS" 2>/dev/null; then
  ok "V6: quirks.c が <linux/dmi.h> をinclude済み"
else
  ng "V6: quirks.c に <linux/dmi.h> が無い — dmi_matchがビルドできない"
fi
DMI_PN="/sys/class/dmi/id/product_name"
if [ -r "$DMI_PN" ]; then
  PN=$(cat "$DMI_PN")
  if [ "$PN" = "MacPro6,1" ]; then
    ok "V6: 実機DMI product_name=MacPro6,1(ガードが実機で発火する)"
  else
    ng "V6: 実機DMIが $PN — この機体ではquirkは発火しない(機体を確認)"
  fi
else
  say "SKIP" "V6: $DMI_PN が読めない(実機で再実行)"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "静的検証: 全項目PASS(SKIP除く)"
else
  echo "静的検証: FAILあり — buildへ進まず円卓へ報告すること"
fi
exit "$FAIL"
