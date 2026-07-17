#!/bin/bash
# shot0: 実射後の証拠採取(全てread-only。設定変更・resize・rescan・unbindは一切しない)。
# cold boot後すぐ実行し、出力ディレクトリごと円卓報告へ添付する。
# 使い方: collect_logs_shot0.sh   (root不要だがdmesg制限時はsudo推奨)
set -euo pipefail

OUT="$HOME/shot0_logs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
echo "== shot0証拠採取 → $OUT =="

run() { # run <出力名> <コマンド...>  失敗しても続行(欠測は空ファイルで正直に残す)
  local NAME=$1; shift
  { "$@" ; } > "$OUT/$NAME" 2>&1 || echo "(exit=$? — 採取失敗を含む)" >> "$OUT/$NAME"
}

run 00_uname.txt         uname -a
run 01_cmdline.txt       cat /proc/cmdline
run 02_dmesg_full.txt    dmesg
run 03_dmesg_shot0.txt   sh -c "dmesg | grep -Ei 'shot0|rebar|BAR|10de|nvidia|pci .*(assign|resource)' || true"
run 04_lspci_tree.txt    lspci -tv
run 05_lspci_nvidia.txt  lspci -d 10de: -nnvv
run 06_lspci_nvidia_hex.txt lspci -d 10de: -nnxxxx
run 07_iomem.txt         cat /proc/iomem
run 08_nvidia_smi.txt    nvidia-smi
run 09_nvidia_smi_q.txt  nvidia-smi -q

# AERカウンタ(BakeMeterの水位と同じsysfs実カウンタ)
for DEV in /sys/bus/pci/devices/*/aer_dev_correctable; do
  BDF=$(basename "$(dirname "$DEV")")
  run "10_aer_${BDF}.txt" cat "$DEV"
done

# 判定サマリ(成功/中止条件の正本はClaude設計書 — ここは事実の抜き出しのみ)
{
  echo "# shot0 採取サマリ $(date '+%Y-%m-%d %H:%M:%S')"
  echo "kernel: $(uname -r)"
  echo
  echo "## BAR1割当て(lspci Region 1)"
  grep -E "^[0-9a-f]|Region 1" "$OUT/05_lspci_nvidia.txt" | grep -B1 "Region 1" || echo "(NVIDIAデバイス未検出)"
  echo
  echo "## ReBAR現在値(lspci Physical Resizable BAR)"
  grep -A3 "Resizable BAR" "$OUT/05_lspci_nvidia.txt" || echo "(ReBAR表示無し)"
  echo
  echo "## quirk発火ログ(dmesg shot0)"
  grep -i shot0 "$OUT/02_dmesg_full.txt" || echo "(shot0ログ無し — quirkが走っていない可能性)"
  echo
  echo "## nvidia-smi先頭"
  head -15 "$OUT/08_nvidia_smi.txt"
} > "$OUT/99_SUMMARY.txt"

( cd "$OUT" && sha256sum ./* > SHA256SUMS )

echo "== サマリ =="
cat "$OUT/99_SUMMARY.txt"
echo
echo "採取完了: $OUT (SHA256SUMS付き)。円卓へ報告すること。"
