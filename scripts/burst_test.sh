#!/bin/bash
# BakeMeter burst test — reproduce LLM-style bursty PCIe traffic on an eGPU
# and count link errors, WITHOUT waiting for a random freeze.
# Evidence survives a freeze: run the monitors below first (they write to disk).
#
# Usage: MODEL=your-model:tag bash burst_test.sh
# Monitors (run before, in separate shells or nohup):
#   nvidia-smi --query-gpu=timestamp,power.draw,utilization.gpu --format=csv -lms 200 > power.csv
#   journalctl -kf --no-pager | grep -iE --line-buffered "pcie|aer:|dmar" > kernel_pcie.log
#
# Error counting uses the sysfs AER counters (BadDLLP delta before/after).
# journalctl is printed only as a reference — it rate-limits AER messages and
# undercounted by ~34x in our measurements (see docs/findings.md §8).

MODEL="${MODEL:-qwen3.5:9b}"
BURSTS="${BURSTS:-8}"
TOKENS="${TOKENS:-40}"
OLLAMA="${BM_OLLAMA:-http://localhost:11434}"
LOG="${BM_TESTLOG:-$HOME/freeze_test/burst_test.log}"

# Pick the AER counter: BM_AER_DEV if set, else the busiest BadDLLP counter
# on the system (the counter lives on the link partner that saw the error,
# usually a TB/PCIe bridge above the GPU, not the GPU itself).
find_aer_dev() {
  if [ -n "$BM_AER_DEV" ] && [ -r "/sys/bus/pci/devices/$BM_AER_DEV/aer_dev_correctable" ]; then
    echo "$BM_AER_DEV"; return
  fi
  local f n best="" best_n=-1
  for f in /sys/bus/pci/devices/*/aer_dev_correctable; do
    [ -r "$f" ] || continue
    n=$(awk '/^BadDLLP/{print $2}' "$f")
    if [ "${n:-0}" -gt "$best_n" ]; then best_n="${n:-0}"; best=$(basename "$(dirname "$f")"); fi
  done
  [ -n "$best" ] && echo "$best"
}
read_baddllp() {
  awk '/^BadDLLP/{print $2}' "/sys/bus/pci/devices/$1/aer_dev_correctable" 2>/dev/null
}

AER_DEV=$(find_aer_dev)
BEFORE=""
[ -n "$AER_DEV" ] && BEFORE=$(read_baddllp "$AER_DEV")

mkdir -p "$(dirname "$LOG")"
echo "$(date +%T) burst test start: model=$MODEL bursts=$BURSTS tokens=$TOKENS aer_dev=${AER_DEV:-none} baddllp_before=${BEFORE:-n/a}" >> "$LOG"
for i in $(seq 1 "$BURSTS"); do
  echo "$(date +%T) burst $i start" >> "$LOG"
  curl -s --max-time 120 "$OLLAMA/api/generate" \
    -d "{\"model\":\"$MODEL\",\"stream\":false,\"prompt\":\"List some tourist spots.\",\"options\":{\"num_predict\":$TOKENS}}" >/dev/null
  echo "$(date +%T) burst $i done, 2s idle" >> "$LOG"
  sleep 2
done
echo "$(date +%T) burst test complete" >> "$LOG"

if [ -n "$BEFORE" ]; then
  AFTER=$(read_baddllp "$AER_DEV")
  echo "BadDLLP delta for this test ($AER_DEV, sysfs): $((AFTER - BEFORE))"
  echo "$(date +%T) baddllp_after=$AFTER delta=$((AFTER - BEFORE))" >> "$LOG"
else
  echo "sysfs AER counters unreadable — journal count below UNDERCOUNTS ~34x:"
fi
echo "journalctl errors in the last 10 minutes (rate-limited, reference only):"
journalctl -k --since "10 minutes ago" --no-pager 2>/dev/null | grep -c "AER: Correctable error message received"
