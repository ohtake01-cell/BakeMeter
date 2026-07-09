#!/bin/bash
# BakeMeter — PCIe/Thunderbolt link-error early-warning for eGPU LLM servers.
# Counts correctable AER errors ("bake" = corrupted packets) and sheds GPU load
# BEFORE the occasional fatal error freezes the machine.
#
# Background: on TB-attached eGPUs under Linux, fatal PCIe errors are usually
# preceded by hours of elevated correctable-error activity (see docs/findings.md).
# Run from cron every 5 minutes:
#   */5 * * * * bash /path/to/bake_meter.sh
#
# Config via environment (defaults in parentheses):
#   BM_LOG        CSV log path            (~/freeze_test/bake_meter.csv)
#   BM_ALERT      alert flag file         (~/BAKE_ALERT.txt)
#   BM_WARN       warn threshold /hour    (50)
#   BM_DANGER     danger threshold /hour  (200)
#   BM_SHED       "1" = unload all Ollama models at danger level (1)
#   BM_OLLAMA     Ollama API base         (http://localhost:11434)

LOG="${BM_LOG:-$HOME/freeze_test/bake_meter.csv}"
ALERT="${BM_ALERT:-$HOME/BAKE_ALERT.txt}"
WARN="${BM_WARN:-50}"
DANGER="${BM_DANGER:-200}"
SHED="${BM_SHED:-1}"
OLLAMA="${BM_OLLAMA:-http://localhost:11434}"

mkdir -p "$(dirname "$LOG")"
N=$(journalctl -k --since "1 hour ago" --no-pager 2>/dev/null | grep -c "AER: Correctable error message received")
TS=$(date "+%Y-%m-%d %H:%M")
LEVEL=OK
if [ "$N" -ge "$DANGER" ]; then LEVEL=DANGER
elif [ "$N" -ge "$WARN" ]; then LEVEL=WARN; fi
echo "$TS,$N,$LEVEL" >> "$LOG"

if [ "$LEVEL" = "DANGER" ]; then
  if [ "$SHED" = "1" ]; then
    # Shed load: unload all resident models. Data is safe; they reload on next use.
    for M in $(curl -s "$OLLAMA/api/ps" | python3 -c "import json,sys; print(' '.join(m['name'] for m in json.load(sys.stdin).get('models',[])))" 2>/dev/null); do
      curl -s "$OLLAMA/api/generate" -d "{\"model\":\"$M\",\"keep_alive\":0}" >/dev/null
    done
    echo "[$TS] DANGER: $N link errors/hour. All models unloaded to stop traffic. Possible freeze precursor." >> "$ALERT"
  else
    echo "[$TS] DANGER: $N link errors/hour. Reduce GPU traffic. Possible freeze precursor." >> "$ALERT"
  fi
elif [ "$LEVEL" = "WARN" ] && [ ! -f "$ALERT" ]; then
  echo "[$TS] WARN: $N link errors/hour. Watching." >> "$ALERT"
fi

# Auto-clear the alert after a sustained quiet period.
if [ "$LEVEL" = "OK" ] && [ -f "$ALERT" ]; then
  RECENT_BAD=$(tail -12 "$LOG" | grep -c -E "WARN|DANGER")
  [ "$RECENT_BAD" -le 1 ] && rm -f "$ALERT"
fi
