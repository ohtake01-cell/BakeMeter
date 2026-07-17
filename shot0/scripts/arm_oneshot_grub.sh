#!/bin/bash
# shot0: 一回限りGRUB装填(実戦済みの型: custom.cfg + grub-reboot)。
# ============================ 王報告ゲート ============================
# このスクリプトは実機を変更する(kernel deb install + custom.cfg + next_entry)。
# 王命(2026-07-17): kernel適用・GRUB予約・再起動・配線変更は王へ直前報告してから。
# 実行条件: Codex監査合格済み / 3060単体・右下口(成功実績の口) / 王同席 / 明るい時間
# 再起動そのものは常に王の手。このスクリプトはrebootしない。
# 失敗時: 電源長押し→次回起動はデフォルト(現行kernel)へ自動復帰(next_entryは一回で消える)。
# =====================================================================
# 使い方: sudo arm_oneshot_grub.sh <linux-image-*.deb> <linux-headers-*.deb>
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "ERROR: root(sudo)が必要" >&2; exit 1; }
IMG_DEB=${1:?使い方: arm_oneshot_grub.sh <linux-image-*.deb> <linux-headers-*.deb>}
HDR_DEB=${2:?headers debも指定すること(DKMS/nvidiaビルドに必須)}
[ -f "$IMG_DEB" ] && [ -f "$HDR_DEB" ] || { echo "ERROR: debファイルが無い" >&2; exit 1; }

NEWVER=$(dpkg-deb -f "$IMG_DEB" Package | sed 's/^linux-image-//')
case "$NEWVER" in *shot0*) : ;; *) echo "ERROR: shot0以外のkernel debを装填しようとしている: $NEWVER" >&2; exit 1;; esac

echo "============================================================"
echo " SHOT0 装填前チェックリスト(王へ直前報告済みであること)"
echo "   1. Codex監査: 合格済みか"
echo "   2. 接続: 3060単体・右下口・2枚同時cold boot禁止の遵守"
echo "   3. 王の同席・明るい時間"
echo "   4. 装填内容: dpkg -i $IMG_DEB"
echo "               dpkg -i $HDR_DEB"
echo "               /boot/grub/custom.cfg に一回限りentry『SHOT0-oneshot』"
echo "               grub-reboot 'SHOT0-oneshot'(次回起動1回のみ)"
echo "   5. デフォルト起動kernelは現行($(uname -r))のまま変えない"
echo "============================================================"
printf "上記を王へ報告し裁可を得たなら SHOT0-ARM と入力: "
read -r ANSWER
[ "$ANSWER" = "SHOT0-ARM" ] || { echo "中止(何も変更していない)"; exit 1; }

# ---- 前提: grub-rebootが効く設定か(変更はしない・確認のみ) ----
if ! grep -q '^GRUB_DEFAULT=saved' /etc/default/grub; then
  echo "ERROR: /etc/default/grub が GRUB_DEFAULT=saved でない。grub-rebootが効かない。" >&2
  echo "  王へ報告の上、GRUB_DEFAULT=saved + update-grub を先に実施すること(本スクリプトは勝手に書き換えない)" >&2
  exit 1
fi

# ---- kernel install(デフォルトentryはsavedのままなので起動既定は変わらない) ----
dpkg -i "$IMG_DEB" "$HDR_DEB"

# ---- DKMS: nvidiaモジュールが新kernel向けに存在するか ----
if command -v dkms >/dev/null; then
  dkms autoinstall -k "$NEWVER" || true
fi
if ! modinfo -k "$NEWVER" nvidia >/dev/null 2>&1; then
  echo "ERROR: 新kernel($NEWVER)用nvidiaモジュールが無い。nvidia-smi検証が成立しないため中止。" >&2
  echo "  dkms status を確認し、build後に再実行。装填(custom.cfg/next_entry)はまだ行っていない。" >&2
  exit 1
fi
echo "OK: nvidiaモジュール確認 ($(modinfo -k "$NEWVER" -F version nvidia 2>/dev/null || echo version不明))"

# ---- 一回限りentry(custom.cfg) ----
[ -f "/boot/vmlinuz-$NEWVER" ] || { echo "ERROR: /boot/vmlinuz-$NEWVER が無い" >&2; exit 1; }
[ -f "/boot/initrd.img-$NEWVER" ] || { echo "ERROR: /boot/initrd.img-$NEWVER が無い(update-initramfs待ち?)" >&2; exit 1; }
CMDLINE=$(sed 's/BOOT_IMAGE=[^ ]* //' /proc/cmdline)
# /bootが独立パーティションならGRUBからのパスは /vmlinuz-*、rootfs直下なら /boot/vmlinuz-*
if findmnt -no UUID /boot >/dev/null 2>&1; then
  ROOT_UUID=$(findmnt -no UUID /boot)
  KPATH="/vmlinuz-$NEWVER"
  IPATH="/initrd.img-$NEWVER"
else
  ROOT_UUID=$(findmnt -no UUID /)
  KPATH="/boot/vmlinuz-$NEWVER"
  IPATH="/boot/initrd.img-$NEWVER"
fi

if [ -f /boot/grub/custom.cfg ] && ! grep -q "SHOT0" /boot/grub/custom.cfg; then
  echo "ERROR: 既存の/boot/grub/custom.cfgがshot0以外の内容 — 上書きしない。王へ報告。" >&2
  exit 1
fi
cat > /boot/grub/custom.cfg <<EOF
# SHOT0 one-time entry ($(date '+%Y-%m-%d %H:%M')) — rollback_shot0.sh で撤去
menuentry 'SHOT0-oneshot' {
	search --no-floppy --fs-uuid --set=root $ROOT_UUID
	linux $KPATH $CMDLINE
	initrd $IPATH
}
EOF

# ---- 次回1回のみSHOT0で起動(デフォルトは不変) ----
grub-reboot "SHOT0-oneshot"

echo "== 装填結果 =="
grub-editenv /boot/grub/grubenv list
echo "------------------------------------------------------------"
echo "装填完了。next_entry=SHOT0-oneshot(1回で自動消滅)。"
echo "再起動は王の手で。起動後は collect_logs_shot0.sh で証拠採取。"
echo "凍結時: 電源長押し→現行kernel($(uname -r))で自動復帰→rollback_shot0.sh"
