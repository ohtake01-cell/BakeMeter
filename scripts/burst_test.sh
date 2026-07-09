#!/bin/bash
# BakeMeter burst test — reproduce LLM-style bursty PCIe traffic on an eGPU
# and count link errors, WITHOUT waiting for a random freeze.
# Evidence survives a freeze: run the monitors below first (they write to disk).
#
# Usage: MODEL=your-model:tag bash burst_test.sh
# Monitors (run before, in separate shells or nohup):
#   nvidia-smi --query-gpu=timestamp,power.draw,utilization.gpu --format=csv -lms 200 > power.csv
#   journalctl -kf --no-pager | grep -iE --line-buffered "pcie|aer:|dmar" > kernel_pcie.log

MODEL="${MODEL:-qwen3.5:9b}"
BURSTS="${BURSTS:-8}"
TOKENS="${TOKENS:-40}"
OLLAMA="${BM_OLLAMA:-http://localhost:11434}"
LOG="${BM_TESTLOG:-$HOME/freeze_test/burst_test.log}"

mkdir -p "$(dirname "$LOG")"
echo "$(date +%T) burst test start: model=$MODEL bursts=$BURSTS tokens=$TOKENS" >> "$LOG"
for i in $(seq 1 "$BURSTS"); do
  echo "$(date +%T) burst $i start" >> "$LOG"
  curl -s --max-time 120 "$OLLAMA/api/generate" \
    -d "{\"model\":\"$MODEL\",\"stream\":false,\"prompt\":\"List some tourist spots.\",\"options\":{\"num_predict\":$TOKENS}}" >/dev/null
  echo "$(date +%T) burst $i done, 2s idle" >> "$LOG"
  sleep 2
done
echo "$(date +%T) burst test complete" >> "$LOG"
echo "Errors in the last 10 minutes:"
journalctl -k --since "10 minutes ago" --no-pager 2>/dev/null | grep -c "AER: Correctable error message received"
