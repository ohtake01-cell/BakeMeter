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

# ---- 前提チェック(Codex P1対応: 実機を変更する前に全て確認し、半端状態を作らない) ----
# 1. grub-rebootが効く設定か(変更はしない・確認のみ)
if ! grep -q '^GRUB_DEFAULT=saved' /etc/default/grub; then
  echo "ERROR: /etc/default/grub が GRUB_DEFAULT=saved でない。grub-rebootが効かない。" >&2
  echo "  王へ報告の上、GRUB_DEFAULT=saved + update-grub を先に実施すること(本スクリプトは勝手に書き換えない)" >&2
  exit 1
fi
# 2. 既存custom.cfgの所有判定(Codex P1第2〜3ラウンド: 全行を許可パターンで照合)。
#    「SHOT0の生成物だけで構成された実ファイル」以外は上書きしない。
#    字下げmenuentry・source・submenu等の混入、シンボリックリンクは全て不合格。
custom_cfg_is_shot0_only() {
  local f=/boot/grub/custom.cfg
  [ -L "$f" ] && return 1	# リンク先破壊を防ぐ: シンボリックリンクは所有と見なさない
  head -1 "$f" | grep -q '^# SHOT0 one-time entry' || return 1
  [ "$(grep -c "^menuentry 'SHOT0-oneshot' {$" "$f")" -eq 1 ] || return 1
  # 全行がSHOT0テンプレートの許可パターンのみで構成されること
  awk '
    /^# SHOT0/ {next}
    /^menuentry '\''SHOT0-oneshot'\'' \{$/ {next}
    /^[ \t]+(search|linux|initrd) / {next}
    /^\}$/ {next}
    /^[ \t]*$/ {next}
    {exit 1}
  ' "$f" || return 1
  return 0
}
if [ -f /boot/grub/custom.cfg ] && ! custom_cfg_is_shot0_only; then
  echo "ERROR: 既存の/boot/grub/custom.cfgがSHOT0専用の形でない(他用途エントリの可能性) — 上書きしない。王へ報告。" >&2
  echo "  (実機にはまだ何も変更を加えていない)" >&2
  exit 1
fi
# 3. 道具が揃っているか
for tool in grub-reboot grub-editenv dpkg findmnt; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool が無い(実機は無変更)" >&2; exit 1; }
done

# ---- ここから実機を変更する。失敗時は現在地を正直に報告する(Codex P1: 半端状態の未検知防止) ----
PHASE="未変更"
report_state() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "============================================================" >&2
    echo "ABORT(exit=$rc): 到達段階=$PHASE" >&2
    case "$PHASE" in
      未変更) echo "実機は無変更のまま。" >&2 ;;
      install実行中)
        echo "dpkg -i の途中で失敗 — パッケージが半端状態(iU/iF等)で残っている可能性。" >&2
        echo "確認: dpkg -l | grep shot0 / 撤去: sudo rollback_shot0.sh --purge (半端状態も掃除する)" >&2 ;;
      install済み)
        echo "半端状態: kernel debはinstall済み・装填(custom.cfg/next_entry)は未実施。" >&2
        echo "撤去する場合: sudo rollback_shot0.sh --purge (ii以外の半端パッケージも掃除する)" >&2 ;;
      装填済み)
        echo "install+custom.cfgまで完了・next_entry設定中に失敗。" >&2
        echo "状態確認: grub-editenv /boot/grub/grubenv list / 撤去: sudo rollback_shot0.sh --purge" >&2 ;;
    esac
    echo "王へこの表示のまま報告すること。" >&2
    echo "============================================================" >&2
  fi
}
trap report_state EXIT

# ---- kernel install(デフォルトentryはsavedのままなので起動既定は変わらない) ----
# P1第2ラウンド: dpkg実行前にPHASEを進める(途中失敗を「無変更」と誤報しない)
PHASE="install実行中"
dpkg -i "$IMG_DEB" "$HDR_DEB"
PHASE="install済み"

# ---- DKMS: nvidiaモジュールが新kernel向けに存在するか ----
if command -v dkms >/dev/null; then
  dkms autoinstall -k "$NEWVER" || true
fi
if ! modinfo -k "$NEWVER" nvidia >/dev/null 2>&1; then
  echo "ERROR: 新kernel($NEWVER)用nvidiaモジュールが無い。nvidia-smi検証が成立しないため中止。" >&2
  echo "  dkms status を確認し、build後に再実行。装填(custom.cfg/next_entry)はまだ行っていない。" >&2
  echo "  kernel debはinstall済みのため、やめる場合は sudo rollback_shot0.sh --purge で撤去。" >&2
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

# (前提チェック済みだが、install中に書き換わった場合の再確認・同じ厳密判定)
if [ -f /boot/grub/custom.cfg ] && ! custom_cfg_is_shot0_only; then
  echo "ERROR: /boot/grub/custom.cfgがinstall中にSHOT0専用でない形へ変化 — 上書きしない。王へ報告。" >&2
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
PHASE="装填済み"
grub-reboot "SHOT0-oneshot"

echo "== 装填結果 =="
grub-editenv /boot/grub/grubenv list
echo "------------------------------------------------------------"
echo "装填完了。next_entry=SHOT0-oneshot(1回で自動消滅)。"
echo "再起動は王の手で。起動後は collect_logs_shot0.sh で証拠採取。"
echo "凍結時: 電源長押し→現行kernel($(uname -r))で自動復帰→rollback_shot0.sh"
