#!/bin/bash
# BakeMeter burst test — reproduce LLM-style bursty PCIe traffic on an eGPU
# and count link errors, WITHOUT waiting for a random freeze.
# Evidence survives a freeze: run the monitors below first (they write to disk).
#
# Usage: MODEL=your-model:tag bash burst_test.sh
#   BM_AERDEV=/sys/bus/pci/devices/<your-dev>/aer_dev_correctable  (recommended;
#   find yours with: grep -l . /sys/bus/pci/devices/*/aer_dev_correctable)
# Monitors (run before, in separate shells or nohup):
#   nvidia-smi --query-gpu=timestamp,power.draw,utilization.gpu --format=csv -lms 200 > power.csv
#   journalctl -kf --no-pager | grep -iE --line-buffered "pcie|aer:|dmar" > kernel_pcie.log

MODEL="${MODEL:-qwen3.5:9b}"
BURSTS="${BURSTS:-8}"
TOKENS="${TOKENS:-40}"
OLLAMA="${BM_OLLAMA:-http://localhost:11434}"
LOG="${BM_TESTLOG:-$HOME/freeze_test/burst_test.log}"
AERDEV="${BM_AERDEV:-}"

read_baddllp() { awk '/^BadDLLP/{print $2}' "$AERDEV" 2>/dev/null; }

mkdir -p "$(dirname "$LOG")"
echo "$(date +%T) burst test start: model=$MODEL bursts=$BURSTS tokens=$TOKENS" >> "$LOG"

# Real counter (sysfs AER). journalctl undercounts ~34x under load (findings #8),
# so it is printed only as a reference number below.
START=""
if [ -n "$AERDEV" ] && [ -r "$AERDEV" ]; then
  START=$(read_baddllp)
  echo "$(date +%T) sysfs BadDLLP at start: $START ($AERDEV)" >> "$LOG"
fi

for i in $(seq 1 "$BURSTS"); do
  echo "$(date +%T) burst $i start" >> "$LOG"
  curl -s --max-time 120 "$OLLAMA/api/generate" \
    -d "{\"model\":\"$MODEL\",\"stream\":false,\"prompt\":\"List some tourist spots.\",\"options\":{\"num_predict\":$TOKENS}}" >/dev/null
  echo "$(date +%T) burst $i done, 2s idle" >> "$LOG"
  sleep 2
done
echo "$(date +%T) burst test complete" >> "$LOG"

NJ=$(journalctl -k --since "10 minutes ago" --no-pager 2>/dev/null | grep -c "AER: Correctable error message received")
if [ -n "$START" ]; then
  END=$(read_baddllp)
  DELTA=$((END - START))
  echo "BadDLLP during test (sysfs, the real number): $DELTA"
  echo "journalctl count in the last 10 min (reference; undercounts ~34x): $NJ"
  echo "$(date +%T) result: sysfs_delta=$DELTA journal_10m=$NJ" >> "$LOG"
else
  echo "journalctl count in the last 10 min: $NJ"
  echo "WARNING: set BM_AERDEV to your aer_dev_correctable path for the real"
  echo "count — kernel rate-limiting makes this journalctl number ~34x too low"
  echo "under load (see docs/findings.md #8)."
  echo "$(date +%T) result: journal_10m=$NJ (no BM_AERDEV; undercounted)" >> "$LOG"
fi
