#!/bin/bash
# BakeMeter v2 — PCIe/Thunderbolt link-error early-warning for eGPU LLM servers.
# Counts correctable AER errors ("bake" = corrupted packets) and sheds GPU load
# BEFORE the occasional fatal error freezes the machine.
#
# v2 reads the kernel's sysfs AER counters (BadDLLP in aer_dev_correctable)
# and works on per-interval deltas. v1 grepped journalctl, which undercounted
# by ~34x in our measurements because the kernel rate-limits AER console
# output ("callbacks suppressed") — see docs/findings.md §8. journalctl is
# kept only as a reference column and as a fallback when sysfs is unreadable.
#
# Run from cron every 5 minutes:
#   */5 * * * * bash /path/to/bake_meter.sh
#
# Config via environment (defaults in parentheses):
#   BM_LOG        CSV log path                  (~/freeze_test/bake_meter.csv)
#                 columns: ts,delta,level,baddllp_total,journal_1h,source
#   BM_ALERT      alert flag file               (~/BAKE_ALERT.txt)
#   BM_STATE      machine-readable state JSON   (~/freeze_test/bake_state.json)
#   BM_STATEDIR   internal state file           (~/freeze_test/.bake_meter.state)
#   BM_AER_DEV    PCI BDF of the AER-reporting device, e.g. 0000:18:01.0
#                 (auto-detected: the counter increments on the device that
#                 OBSERVED the error — the link partner, usually a TB/PCIe
#                 bridge above the GPU — not on the GPU itself)
#   BM_WARN       warn threshold per interval   (1000)
#   BM_DANGER     danger threshold per interval (5000)
#   BM_COOLDOWN   seconds to hold COOLDOWN after the last DANGER (3600)
#   BM_SHED       "1" = unload all Ollama models on entering DANGER (1)
#   BM_OLLAMA     Ollama API base               (http://localhost:11434)
#
# Thresholds are PROVISIONAL (measured on one TB2 rig; sysfs counts are ~34x
# the journalctl counts the old 50/200-per-hour defaults were based on).
# Collect a few days of CSV on your own rig and recalibrate.

LOG="${BM_LOG:-$HOME/freeze_test/bake_meter.csv}"
ALERT="${BM_ALERT:-$HOME/BAKE_ALERT.txt}"
STATE_JSON="${BM_STATE:-$HOME/freeze_test/bake_state.json}"
STATE="${BM_STATEDIR:-$HOME/freeze_test/.bake_meter.state}"
WARN="${BM_WARN:-1000}"
DANGER="${BM_DANGER:-5000}"
COOLDOWN="${BM_COOLDOWN:-3600}"
SHED="${BM_SHED:-1}"
OLLAMA="${BM_OLLAMA:-http://localhost:11434}"

mkdir -p "$(dirname "$LOG")" "$(dirname "$STATE_JSON")"

read_baddllp() {
  awk '/^BadDLLP/{print $2}' "/sys/bus/pci/devices/$1/aer_dev_correctable" 2>/dev/null
}

# Locate the AER counter to watch. Walk up from the NVIDIA GPU collecting
# every ancestor that exposes aer_dev_correctable, then pick the one with the
# highest BadDLLP count (ties go to the link partner just above the GPU).
find_aer_dev() {
  if [ -n "$BM_AER_DEV" ] && [ -r "/sys/bus/pci/devices/$BM_AER_DEV/aer_dev_correctable" ]; then
    echo "$BM_AER_DEV"; return
  fi
  local d best="" best_n=-1 n gpu
  gpu=$(grep -l '^0x10de' /sys/bus/pci/devices/*/vendor 2>/dev/null | head -1)
  if [ -n "$gpu" ]; then
    d=$(readlink -f "$(dirname "$gpu")")
    while [ "$d" != "/" ] && [ "$d" != "/sys/devices" ]; do
      if [ -r "$d/aer_dev_correctable" ]; then
        n=$(awk '/^BadDLLP/{print $2}' "$d/aer_dev_correctable")
        if [ "${n:-0}" -gt "$best_n" ]; then best_n="${n:-0}"; best=$(basename "$d"); fi
      fi
      d=$(dirname "$d")
    done
  fi
  if [ -z "$best" ]; then
    # No NVIDIA GPU found on PCI — fall back to the busiest counter anywhere.
    local f
    for f in /sys/bus/pci/devices/*/aer_dev_correctable; do
      [ -r "$f" ] || continue
      n=$(awk '/^BadDLLP/{print $2}' "$f")
      if [ "${n:-0}" -gt "$best_n" ]; then best_n="${n:-0}"; best=$(basename "$(dirname "$f")"); fi
    done
  fi
  [ -n "$best" ] && echo "$best"
}

TS=$(date "+%Y-%m-%d %H:%M")
EPOCH=$(date +%s)
JOURNAL_1H=$(journalctl -k --since "1 hour ago" --no-pager 2>/dev/null | grep -c "AER: Correctable error message received")

AER_DEV=$(find_aer_dev)
TOTAL=""
[ -n "$AER_DEV" ] && TOTAL=$(read_baddllp "$AER_DEV")

PREV_TOTAL="" PREV_LEVEL="" LAST_DANGER=0
[ -f "$STATE" ] && . "$STATE"

SOURCE=sysfs
if [ -z "$TOTAL" ]; then
  # sysfs unreadable — fall back to v1 journal counting and say so.
  DELTA=$JOURNAL_1H
  TOTAL="${PREV_TOTAL:-0}"
  SOURCE=journalctl_fallback
elif [ -z "$PREV_TOTAL" ]; then
  # First run: record the baseline only. The boot-time backlog is cumulative,
  # not fresh traffic — alarming on it would be a false positive.
  DELTA=0
  SOURCE=sysfs_first_run
elif [ "$TOTAL" -lt "$PREV_TOTAL" ]; then
  # Counter went backwards = the machine rebooted and counters reset.
  DELTA=$TOTAL
  SOURCE=sysfs_reset
else
  DELTA=$((TOTAL - PREV_TOTAL))
fi

# The journal fallback counts a rate-limited 1-hour window, so the sysfs
# per-interval thresholds don't apply — use the old v1 per-hour thresholds.
W="$WARN"; D="$DANGER"
if [ "$SOURCE" = "journalctl_fallback" ]; then
  W="${BM_WARN_JOURNAL:-50}"; D="${BM_DANGER_JOURNAL:-200}"
fi

LEVEL=OK
if [ "$DELTA" -ge "$D" ]; then LEVEL=DANGER; LAST_DANGER=$EPOCH
elif [ "$DELTA" -ge "$W" ]; then LEVEL=WARN; fi

# A DANGER reading marks a lingering danger state, not just live traffic:
# fatal errors have struck ~30 min after traffic stopped, and error storms
# have continued with no model loaded (findings §6, §9). Hold COOLDOWN so
# external gates keep the link quiet even after the current reading is calm.
if [ "$LEVEL" = "OK" ] && [ "$LAST_DANGER" -gt 0 ] && [ $((EPOCH - LAST_DANGER)) -lt "$COOLDOWN" ]; then
  LEVEL=COOLDOWN
fi

echo "$TS,$DELTA,$LEVEL,$TOTAL,$JOURNAL_1H,$SOURCE" >> "$LOG"

# Machine-readable state for external gates (e.g. refuse to start an image
# generation or a model swap while level != OK). Written atomically; treat
# a stale epoch (>10 min old) as UNKNOWN on the consumer side.
printf '{"level":"%s","delta":%s,"baddllp_total":%s,"journal_1h":%s,"source":"%s","aer_dev":"%s","ts":"%s","epoch":%s}\n' \
  "$LEVEL" "$DELTA" "$TOTAL" "$JOURNAL_1H" "$SOURCE" "${AER_DEV:-none}" "$TS" "$EPOCH" \
  > "$STATE_JSON.tmp" && mv "$STATE_JSON.tmp" "$STATE_JSON"

printf 'PREV_TOTAL=%s\nPREV_LEVEL=%s\nLAST_DANGER=%s\n' "$TOTAL" "$LEVEL" "$LAST_DANGER" \
  > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"

if [ "$LEVEL" = "DANGER" ] && [ "$PREV_LEVEL" != "DANGER" ]; then
  # Shed once, on the transition into DANGER. Re-shedding every interval while
  # danger persists is a no-op that spams the API and the alert file.
  if [ "$SHED" = "1" ]; then
    for M in $(curl -s "$OLLAMA/api/ps" | python3 -c "import json,sys; print(' '.join(m['name'] for m in json.load(sys.stdin).get('models',[])))" 2>/dev/null); do
      curl -s "$OLLAMA/api/generate" -d "{\"model\":\"$M\",\"keep_alive\":0}" >/dev/null
    done
    sleep 2
    LEFT=$(curl -s "$OLLAMA/api/ps" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('models',[])))" 2>/dev/null)
    if [ "$LEFT" = "0" ]; then
      MSG="All models unloaded to stop traffic (unload verified)."
    elif [ -n "$LEFT" ]; then
      MSG="Model unload attempted but $LEFT still resident — check manually."
    else
      MSG="Model unload attempted; could not verify (Ollama API unreachable)."
    fi
    echo "[$TS] DANGER: $DELTA link errors this interval ($SOURCE). $MSG Possible freeze precursor — keep the link quiet for at least $((COOLDOWN / 60)) min." >> "$ALERT"
  else
    echo "[$TS] DANGER: $DELTA link errors this interval ($SOURCE). Reduce GPU traffic. Possible freeze precursor." >> "$ALERT"
  fi
elif [ "$LEVEL" = "WARN" ] && [ ! -f "$ALERT" ]; then
  echo "[$TS] WARN: $DELTA link errors this interval ($SOURCE). Watching." >> "$ALERT"
fi

# Auto-clear the alert only once the cooldown has fully passed AND the recent
# log shows a sustained quiet period.
if [ "$LEVEL" = "OK" ] && [ -f "$ALERT" ]; then
  RECENT_BAD=$(tail -12 "$LOG" | grep -c -E "WARN|DANGER|COOLDOWN")
  [ "$RECENT_BAD" -le 1 ] && rm -f "$ALERT"
fi
