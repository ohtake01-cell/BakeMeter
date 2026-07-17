#!/bin/bash
# shot0: prepare_grub_saved.sh の非破壊fixture試験(root不要・実機のGRUB一切不触)。
# SHOT0_*フックで全パスを一時dirへ向け、本物のgrub-editenvだけを使って全経路を実走する。
# Linux(grub-editenvがある機)で: bash shot0/test/run_prepare_fixture.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
PREP="$HERE/../scripts/prepare_grub_saved.sh"
command -v grub-editenv >/dev/null || { echo "SKIP: grub-editenvが無い(Linuxで実行)"; exit 0; }
KREL=$(uname -r)
FAILS=0
say() { echo; echo "===== $* ====="; }
chk() { if eval "$2"; then echo "  PASS: $1"; else echo "  FAIL: $1"; FAILS=1; fi; }

mkfix() { # 新しいfixture一式を作る。$1=GRUB_DEFAULT値 $2=entry0のkernel版
  FIX=$(mktemp -d -t shot0prep.XXXXXX)
  echo "GRUB_DEFAULT=$1" > "$FIX/grub.default"
  echo "GRUB_TIMEOUT=0" >> "$FIX/grub.default"
  cat > "$FIX/grub.cfg" <<EOF
menuentry 'Ubuntu' --class ubuntu \$menuentry_id_option 'gnulinux-simple-AAAA-BBBB' {
	linux /boot/vmlinuz-$2 root=UUID=aaaa ro quiet
	initrd /boot/initrd.img-$2
}
submenu 'Advanced options for Ubuntu' \$menuentry_id_option 'gnulinux-advanced-AAAA-BBBB' {
	menuentry 'Ubuntu, with Linux $KREL' \$menuentry_id_option 'gnulinux-$KREL-advanced-AAAA-BBBB' {
		linux /boot/vmlinuz-$KREL root=UUID=aaaa ro quiet
		initrd /boot/initrd.img-$KREL
	}
}
EOF
  grub-editenv "$FIX/grubenv" create
  grub-editenv "$FIX/grubenv" set next_entry=TEST-3060-window-onetime
  printf '# TEST-3060-window-onetime (old experiment)\nmenuentry %s {\n}\n' "'TEST'" > "$FIX/custom.cfg"
  mkdir -p "$FIX/state"
  cat > "$FIX/dpkg_none" <<'S'
#!/bin/bash
exit 0
S
  cat > "$FIX/dpkg_shot0" <<'S'
#!/bin/bash
printf 'ii \tlinux-image-7.0.12+shot0\n'
S
  cat > "$FIX/dpkg_broken" <<'S'
#!/bin/bash
exit 2
S
  chmod +x "$FIX/dpkg_none" "$FIX/dpkg_shot0" "$FIX/dpkg_broken"
  ENVV=(SHOT0_GRUB_FILE="$FIX/grub.default" SHOT0_GRUB_CFG="$FIX/grub.cfg"
        SHOT0_GRUBENV="$FIX/grubenv" SHOT0_CUSTOM="$FIX/custom.cfg"
        SHOT0_STATE_DIR="$FIX/state" SHOT0_LOCK="$FIX/lock"
        SHOT0_UPDATE_GRUB=/bin/true SHOT0_DPKG_QUERY="$FIX/dpkg_none")
}
snap() { sha256sum "$FIX/grub.default" "$FIX/grubenv" 2>/dev/null | awk '{print $1}' | tr '\n' ' '; }

say "T1: dry-run(完全read-only: state dirもlockも作らない)"
mkfix 0 "$KREL"; S0=$(snap)
env "${ENVV[@]}" SHOT0_STATE_DIR="$FIX/state-noexist" SHOT0_LOCK="$FIX/lock-noexist" bash "$PREP" --dry-run >/dev/null
chk "exit=0で完走" "true"
chk "ファイル無変更" "[ '$S0' = \"\$(snap)\" ]"
chk "state dirを作らない" "[ ! -e '$FIX/state-noexist' ]"
chk "lockを作らない" "[ ! -e '$FIX/lock-noexist' ]"

say "T2: full prepare成功(0→saved・ID固定・custom退避・next_entry解除)"
mkfix 0 "$KREL"
echo SHOT0-PREP | env "${ENVV[@]}" bash "$PREP" > "$FIX/t2.out"
chk "GRUB_DEFAULT=saved" "grep -q '^GRUB_DEFAULT=saved$' '$FIX/grub.default'"
chk "saved_entry=名前付きID" "grub-editenv '$FIX/grubenv' list | grep -qF 'saved_entry=gnulinux-advanced-AAAA-BBBB>gnulinux-$KREL-advanced-AAAA-BBBB'"
chk "next_entry解除" "! grub-editenv '$FIX/grubenv' list | grep -q '^next_entry='"
chk "custom.cfg退避(実体は取引dirに残存)" "[ ! -e '$FIX/custom.cfg' ] && ls '$FIX'/state/txn-*/custom.cfg.moved >/dev/null"
chk "meta+SHA記録" "grep -q '== sha256 ==' '$FIX'/state/txn-*/meta"
chk "readback検証全PASS表示" "! grep -q FAIL '$FIX/t2.out'"

say "T3: update-grub失敗→取引から全復元(abort trap)"
mkfix 0 "$KREL"; S0=$(snap); C0=$(sha256sum "$FIX/custom.cfg" | awk '{print $1}')
echo SHOT0-PREP | env "${ENVV[@]}" SHOT0_UPDATE_GRUB=/bin/false bash "$PREP" > "$FIX/t3.out" 2>&1 || true
chk "GRUB_DEFAULT/grubenvが原状" "[ '$S0' = \"\$(snap)\" ]"
chk "custom.cfgも原状復帰" "[ \"\$(sha256sum '$FIX/custom.cfg' | awk '{print \$1}')\" = '$C0' ]"
chk "latest markerが残らない" "[ ! -f '$FIX/state/latest' ]"

say "T4: undo(prepare後→完全復元)"
mkfix 0 "$KREL"; S0=$(snap); C0=$(sha256sum "$FIX/custom.cfg" | awk '{print $1}')
echo SHOT0-PREP | env "${ENVV[@]}" bash "$PREP" >/dev/null
env "${ENVV[@]}" bash "$PREP" --undo > "$FIX/t4.out"
chk "GRUB_DEFAULT/grubenvが原状" "[ '$S0' = \"\$(snap)\" ]"
chk "custom.cfg復元" "[ \"\$(sha256sum '$FIX/custom.cfg' | awk '{print \$1}')\" = '$C0' ]"
chk "latest markerが消える" "[ ! -f '$FIX/state/latest' ]"

say "T5: undo拒否(custom.cfg存在時/shot0 kernel残存時)"
mkfix 0 "$KREL"
echo SHOT0-PREP | env "${ENVV[@]}" bash "$PREP" >/dev/null
printf '# SHOT0 one-time entry (arm made)\n' > "$FIX/custom.cfg"
env "${ENVV[@]}" bash "$PREP" --undo >/dev/null 2>&1 && chk "custom存在でundo中止" false || chk "custom存在でundo中止" true
rm "$FIX/custom.cfg"
env "${ENVV[@]}" SHOT0_DPKG_QUERY="$FIX/dpkg_shot0" bash "$PREP" --undo >/dev/null 2>&1 \
  && chk "shot0 pkg残存でundo中止" false || chk "shot0 pkg残存でundo中止" true
env "${ENVV[@]}" SHOT0_DPKG_QUERY="$FIX/dpkg_broken" bash "$PREP" --undo >/dev/null 2>&1 \
  && chk "照会失敗でもundo中止(fail-closed)" false || chk "照会失敗でもundo中止(fail-closed)" true
env "${ENVV[@]}" bash "$PREP" --undo >/dev/null && chk "障害物撤去後はundo成功" true || chk "障害物撤去後はundo成功" false

say "T6: entry 0が別kernelなら無変更で中止"
mkfix 0 "9.9.9-other"; S0=$(snap)
echo SHOT0-PREP | env "${ENVV[@]}" bash "$PREP" >/dev/null 2>&1 && chk "中止する" false || chk "中止する" true
chk "無変更" "[ '$S0' = \"\$(snap)\" ]"

say "T7: partialモード(saved_entry=0は正規化・不明値は中止)"
mkfix saved "$KREL"
grub-editenv "$FIX/grubenv" set saved_entry=0
echo SHOT0-PREP | env "${ENVV[@]}" bash "$PREP" >/dev/null
chk "0→名前付きIDへ正規化" "grub-editenv '$FIX/grubenv' list | grep -qF 'saved_entry=gnulinux-advanced-AAAA-BBBB>gnulinux-$KREL-advanced-AAAA-BBBB'"
mkfix saved "$KREL"
grub-editenv "$FIX/grubenv" set saved_entry=gnulinux-9.9.9-other-advanced-AAAA-BBBB
S0=$(snap)
echo SHOT0-PREP | env "${ENVV[@]}" bash "$PREP" >/dev/null 2>&1 && chk "不明saved_entryは中止" false || chk "不明saved_entryは中止" true
chk "無変更" "[ '$S0' = \"\$(snap)\" ]"

say "T8: 二重実行防止(未undo取引が残っていれば中止)"
mkfix 0 "$KREL"
echo SHOT0-PREP | env "${ENVV[@]}" bash "$PREP" >/dev/null
echo SHOT0-PREP | env "${ENVV[@]}" bash "$PREP" >/dev/null 2>&1 && chk "二重prepare中止" false || chk "二重prepare中止" true

say "T10: entry 0が非Linux entry(chainloader+毒コメント入り)なら中止"
mkfix 0 "$KREL"
cat > "$FIX/grub.cfg" <<EOF
menuentry 'Other OS' \$menuentry_id_option 'other-AAAA' {
	# fallback memo: /boot/vmlinuz-$KREL
	chainloader /EFI/other/bootx64.efi
}
menuentry 'Ubuntu' --class ubuntu \$menuentry_id_option 'gnulinux-simple-AAAA-BBBB' {
	linux /boot/vmlinuz-$KREL root=UUID=aaaa ro quiet
}
submenu 'Advanced options for Ubuntu' \$menuentry_id_option 'gnulinux-advanced-AAAA-BBBB' {
	menuentry 'x' \$menuentry_id_option 'gnulinux-$KREL-advanced-AAAA-BBBB' {
		linux /boot/vmlinuz-$KREL root=UUID=aaaa ro
	}
}
EOF
S0=$(snap)
echo SHOT0-PREP | env "${ENVV[@]}" bash "$PREP" >/dev/null 2>&1 && chk "非Linux entry0では中止" false || chk "非Linux entry0では中止" true
chk "無変更" "[ '$S0' = \"\$(snap)\" ]"

say "T10b: entry 0がsubmenuなら中止"
mkfix 0 "$KREL"
cat > "$FIX/grub.cfg" <<EOF
submenu 'Advanced options for Ubuntu' \$menuentry_id_option 'gnulinux-advanced-AAAA-BBBB' {
	menuentry 'x' \$menuentry_id_option 'gnulinux-$KREL-advanced-AAAA-BBBB' {
		linux /boot/vmlinuz-$KREL root=UUID=aaaa ro
	}
}
EOF
S0=$(snap)
echo SHOT0-PREP | env "${ENVV[@]}" bash "$PREP" >/dev/null 2>&1 && chk "submenu先頭では中止" false || chk "submenu先頭では中止" true
chk "無変更" "[ '$S0' = \"\$(snap)\" ]"

say "T9: 別階層ID連結の反証(submenu外にKIDがあるgrub.cfgは中止)"
mkfix 0 "$KREL"
cat > "$FIX/grub.cfg" <<EOF
menuentry 'Ubuntu' --class ubuntu \$menuentry_id_option 'gnulinux-simple-AAAA-BBBB' {
	linux /boot/vmlinuz-$KREL root=UUID=aaaa ro quiet
	initrd /boot/initrd.img-$KREL
}
submenu 'Advanced options for Ubuntu' \$menuentry_id_option 'gnulinux-advanced-AAAA-BBBB' {
	menuentry 'Ubuntu, with Linux 9.9.9-other' \$menuentry_id_option 'gnulinux-9.9.9-other-advanced-AAAA-BBBB' {
		linux /boot/vmlinuz-9.9.9-other root=UUID=aaaa ro quiet
	}
}
menuentry 'Outside' \$menuentry_id_option 'gnulinux-$KREL-advanced-AAAA-BBBB' {
	linux /boot/vmlinuz-$KREL root=UUID=aaaa ro quiet
}
EOF
S0=$(snap)
echo SHOT0-PREP | env "${ENVV[@]}" bash "$PREP" >/dev/null 2>&1 && chk "submenu外KIDでは中止(連結しない)" false || chk "submenu外KIDでは中止(連結しない)" true
chk "無変更" "[ '$S0' = \"\$(snap)\" ]"

echo
if [ "$FAILS" -eq 0 ]; then echo "== prepare fixture試験 全PASS =="; else echo "== FAILあり =="; fi
exit "$FAILS"
