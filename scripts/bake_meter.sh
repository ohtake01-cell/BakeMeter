#!/bin/bash
# BakeMeter v2.1 — PCIe/Thunderbolt link-error early-warning for eGPU LLM servers.
# Counts correctable AER errors ("bake" = corrupted packets) and sheds GPU load
# BEFORE the occasional fatal error freezes the machine.
#
# Background: on TB-attached eGPUs under Linux, fatal PCIe errors are usually
# preceded by hours of elevated correctable-error activity (see docs/findings.md).
# Run from cron every 5 minutes:
#   */5 * * * * bash /path/to/bake_meter.sh
#
# v2 measurement: reads the kernel's own AER counters from sysfs
# (aer_dev_correctable) and logs the DELTA since the previous run. journalctl
# grep — the v1 method — undercounts by ~34x under load because the kernel
# rate-limits AER log lines ("callbacks suppressed"), and its 1-hour window
# keeps alarming long after a burst has stopped. sysfs counters miss nothing.
# If sysfs is unavailable the script falls back to journalctl and says so in
# the "source" column.
#
# Config via environment (defaults in parentheses):
#   BM_LOG           CSV log path                  (~/freeze_test/bake_meter.csv)
#   BM_ALERT         alert flag file               (~/BAKE_ALERT.txt)
#   BM_STATE         internal state file           (<BM_LOG dir>/bake_meter.state)
#   BM_STATE_JSON    machine-readable status JSON  (<BM_LOG dir>/bake_state.json)
#                    — written atomically every run; point external gates
#                    (e.g. "block image generation while DANGER") at this.
#                    NOTE: this default is self-contained. A deployment that
#                    published the file somewhere container-visible under an
#                    older layout must set BM_STATE_JSON to that path so its
#                    downstream gates keep reading the live file.
#   BM_AER_DEV       PCI BDF to watch, e.g. 0000:18:01.0. Empty = autodetect
#                    the busiest device (highest BadDLLP = the link partner
#                    above the eGPU) once and PIN it in the state file. We
#                    watch one device, never a sum across all of them: a summed
#                    total lurches when a device drops off the bus and returns,
#                    which is exactly the false-DANGER this meter must avoid.
#   BM_WARN_DELTA    warn threshold, errors per run interval    (1000)
#   BM_DANGER_DELTA  danger threshold, errors per run interval  (5000)
#                    — provisional values measured on a TB2 host with sysfs
#                    counts ~34x the journal counts; recalibrate from your CSV.
#   BM_WARN          journalctl-fallback warn threshold /hour   (50)
#   BM_DANGER        journalctl-fallback danger threshold /hour (200)
#   BM_COOLDOWN_MIN  minutes to stay in COOLDOWN after DANGER   (30)
#                    — measured: the danger state outlives the traffic; one
#                    fatal error struck ~30 min after the link went idle
#                    (docs/findings.md §6). The timer is only the floor:
#                    COOLDOWN also does not lift while any WARN/DANGER
#                    reading sits in the last 6 samples (~30 min at the
#                    5-min cron cadence). Gates should treat COOLDOWN as
#                    "no heavy GPU loads yet".
#   BM_SHED          "1" = unload all Ollama models on entering DANGER (1)
#   BM_OLLAMA        Ollama API base               (http://localhost:11434)
#
# CSV columns: timestamp,delta,level,baddllp_total,journal_1h,source
# Levels: OK / WARN / DANGER / COOLDOWN

LOG="${BM_LOG:-$HOME/freeze_test/bake_meter.csv}"
ALERT="${BM_ALERT:-$HOME/BAKE_ALERT.txt}"
LOGDIR="$(dirname "$LOG")"
STATE="${BM_STATE:-$LOGDIR/bake_meter.state}"
STATE_JSON="${BM_STATE_JSON:-$LOGDIR/bake_state.json}"
AER_DEV_OVERRIDE="${BM_AER_DEV:-}"   # if set, pin this exact PCI BDF
WARN_DELTA="${BM_WARN_DELTA:-1000}"
DANGER_DELTA="${BM_DANGER_DELTA:-5000}"
WARN_H="${BM_WARN:-50}"
DANGER_H="${BM_DANGER:-200}"
COOLDOWN_MIN="${BM_COOLDOWN_MIN:-30}"
SHED="${BM_SHED:-1}"
OLLAMA="${BM_OLLAMA:-http://localhost:11434}"
SYSFS="${BM_SYSFS_ROOT:-/sys/bus/pci/devices}"   # overridable for testing

mkdir -p "$LOGDIR"

# --- read counters ---------------------------------------------------------

# Read BadDLLP from ONE device's aer_dev_correctable. We watch a single pinned
# device, never a sum across all devices: when a TB eGPU drops off the bus its
# file vanishes, and summing whatever devices remain would make the total lurch
# (down on drop-off, up on return) and fire a false DANGER — the exact failure
# this meter exists to prevent. A missing file yields an empty result, which
# routes cleanly to the journalctl fallback below.
read_baddllp() {
  [ -n "$1" ] || return
  awk '$1=="BadDLLP"{print $2; found=1} END{exit !found}' \
    "$SYSFS/$1/aer_dev_correctable" 2>/dev/null
}

# Autodetect the device to watch: the one with the highest BadDLLP is the noisy
# link partner above the eGPU (docs/findings.md §8). Pinned after the first run
# so it never switches devices mid-life (switching would re-create the lurch).
find_aer_dev() {
  local f n best="" best_n=-1
  for f in "$SYSFS"/*/aer_dev_correctable; do
    [ -r "$f" ] || continue
    n=$(awk '$1=="BadDLLP"{print $2}' "$f")
    if [ "${n:-0}" -gt "$best_n" ]; then best_n="${n:-0}"; best=$(basename "$(dirname "$f")"); fi
  done
  [ -n "$best" ] && echo "$best"
}

JOURNAL_1H=$(journalctl -k --since "1 hour ago" --no-pager 2>/dev/null |
  grep -c "AER: Correctable error message received")
TS=$(date "+%Y-%m-%d %H:%M")
EPOCH=$(date +%s)

# Previous run's state: prev_total prev_level last_danger_epoch pinned_aer_dev
PREV_TOTAL="" PREV_LEVEL="OK" LAST_DANGER=0 PINNED_DEV=""
[ -f "$STATE" ] && read -r PREV_TOTAL PREV_LEVEL LAST_DANGER PINNED_DEV < "$STATE"
LAST_DANGER="${LAST_DANGER:-0}"
# Guard: only a non-negative integer is a usable baseline. Anything else
# (the old -1 fallback sentinel, "none", a half-written state file) would
# turn the lifetime total into a fake burst on recovery — treat as first run.
case "$PREV_TOTAL" in ''|*[!0-9]*) PREV_TOTAL="" ;; esac
[ -z "$PREV_LEVEL" ] && PREV_TOTAL=""   # truncated state (missing fields) = no baseline
case "$LAST_DANGER" in ''|*[!0-9]*) LAST_DANGER=0 ;; esac

# Resolve which device to read: explicit override wins, else the device pinned
# on a previous run, else autodetect once and pin it going forward.
if [ -n "$AER_DEV_OVERRIDE" ]; then AER_DEV="$AER_DEV_OVERRIDE"
elif [ -n "$PINNED_DEV" ] && [ "$PINNED_DEV" != "none" ]; then AER_DEV="$PINNED_DEV"
else AER_DEV="$(find_aer_dev)"; fi

TOTAL=$(read_baddllp "$AER_DEV")
STORE_TOTAL="$TOTAL"
if [ -n "$TOTAL" ]; then
  # sysfs path: alarm on the delta since last run.
  if [ -z "$PREV_TOTAL" ]; then
    DELTA=0; SOURCE=sysfs_first_run          # baseline only — never alarm on a
                                             # lifetime total mistaken for a burst
  elif [ "$TOTAL" -lt "$PREV_TOTAL" ]; then
    DELTA=0; SOURCE=sysfs_reset              # counter went backwards = reboot
  else
    DELTA=$((TOTAL - PREV_TOTAL)); SOURCE=sysfs
  fi
  N="$DELTA"; WARN_AT="$WARN_DELTA"; DANGER_AT="$DANGER_DELTA"
else
  # Fallback: v1 journalctl method (undercounts ~34x under load — see header).
  TOTAL=-1; STORE_TOTAL="${PREV_TOTAL:-none}"; DELTA=$JOURNAL_1H; SOURCE=journalctl
  N="$JOURNAL_1H"; WARN_AT="$WARN_H"; DANGER_AT="$DANGER_H"
fi

# --- level -----------------------------------------------------------------

LEVEL=OK
if [ "$N" -ge "$DANGER_AT" ]; then LEVEL=DANGER
elif [ "$N" -ge "$WARN_AT" ]; then LEVEL=WARN; fi

# The danger state outlives the traffic (findings §6): hold COOLDOWN for
# BM_COOLDOWN_MIN minutes after the last DANGER reading, and even after the
# timer expires do not lift it until the recent samples are quiet (no
# WARN/DANGER in the last 6 rows — a real incident re-entered DANGER twice
# within 40 min of "recovering").
[ "$LEVEL" = "DANGER" ] && LAST_DANGER=$EPOCH
COOLDOWN_UNTIL=$((LAST_DANGER + COOLDOWN_MIN * 60))
if [ "$LEVEL" != "DANGER" ] && [ "$LAST_DANGER" -gt 0 ]; then
  if [ "$EPOCH" -lt "$COOLDOWN_UNTIL" ]; then
    LEVEL=COOLDOWN
  elif tail -6 "$LOG" 2>/dev/null | grep -qE ",(WARN|DANGER),"; then
    LEVEL=COOLDOWN
  fi
fi

echo "$TS,$DELTA,$LEVEL,$TOTAL,$JOURNAL_1H,$SOURCE" >> "$LOG"

# --- act -------------------------------------------------------------------

list_resident() {
  curl -s --max-time 10 "$OLLAMA/api/ps" 2>/dev/null | python3 -c \
    "import json,sys; print(' '.join(m['name'] for m in json.load(sys.stdin).get('models',[])))" \
    2>/dev/null
}

# Count resident models, distinguishing a verified zero from a failed check.
# Echoes an integer on success, or "unknown" when Ollama is unreachable or
# returns invalid JSON — so a failed verification is never logged as a
# successful unload.
count_resident() {
  local out
  out=$(curl -s --max-time 10 "$OLLAMA/api/ps" 2>/dev/null) || { echo unknown; return; }
  [ -n "$out" ] || { echo unknown; return; }
  printf '%s' "$out" | python3 -c \
    "import json,sys
try: print(len(json.load(sys.stdin).get('models',[])))
except Exception: print('unknown')" 2>/dev/null || echo unknown
}

if [ "$LEVEL" = "DANGER" ] && [ "$PREV_LEVEL" != "DANGER" ]; then
  # Shed once, on the transition into DANGER — not every 5 min while it lasts.
  if [ "$SHED" = "1" ]; then
    for M in $(list_resident); do
      curl -s --max-time 10 "$OLLAMA/api/generate" -d "{\"model\":\"$M\",\"keep_alive\":0}" >/dev/null
    done
    LEFT=$(count_resident)
    case "$LEFT" in
      0)  MSG="[$TS] DANGER: $N link errors ($SOURCE). All models unloaded to stop traffic (unload verified). Possible freeze precursor." ;;
      unknown|'') MSG="[$TS] DANGER: $N link errors ($SOURCE). Unload requested but COULD NOT verify (Ollama unreachable) — check manually. Possible freeze precursor." ;;
      *)  MSG="[$TS] DANGER: $N link errors ($SOURCE). Unload requested but $LEFT model(s) still resident — check manually. Possible freeze precursor." ;;
    esac
    echo "$MSG" >> "$ALERT"
  else
    echo "[$TS] DANGER: $N link errors ($SOURCE). Reduce GPU traffic. Possible freeze precursor." >> "$ALERT"
  fi
elif [ "$LEVEL" = "WARN" ] && [ ! -f "$ALERT" ]; then
  echo "[$TS] WARN: $N link errors ($SOURCE). Watching." >> "$ALERT"
fi

# Auto-clear the alert only after the cooldown has expired AND a sustained
# quiet period (≤1 elevated reading in the last hour of samples).
if [ "$LEVEL" = "OK" ] && [ -f "$ALERT" ]; then
  RECENT_BAD=$(tail -12 "$LOG" | grep -c -E "WARN|DANGER|COOLDOWN")
  [ "$RECENT_BAD" -le 1 ] && rm -f "$ALERT"
fi

# --- publish machine-readable state (atomic) -------------------------------
# External gates (web UI, image-generation pipelines) should read this file
# and refuse heavy GPU loads while level is DANGER or COOLDOWN. Treat a stale
# file (epoch older than ~10 min) as "meter not running" and fail CLOSED for
# heavy loads like image generation — flying blind is how storms slip
# through — while letting lightweight interactive traffic continue.
TMP="$STATE_JSON.tmp.$$"
# `delta_5m` is kept as an alias of `delta` for backward compatibility: the
# v2 state file published `delta_5m`, and downstream gates parse that name.
# New readers may use `delta`; both always carry the same value.
printf '{"level":"%s","delta":%s,"delta_5m":%s,"baddllp_total":%s,"journal_1h":%s,"source":"%s","aer_dev":"%s","ts":"%s","epoch":%s,"cooldown_until_epoch":%s}\n' \
  "$LEVEL" "$DELTA" "$DELTA" "$TOTAL" "$JOURNAL_1H" "$SOURCE" "${AER_DEV:-none}" "$TS" "$EPOCH" "$COOLDOWN_UNTIL" > "$TMP" \
  && mv -f "$TMP" "$STATE_JSON"

printf '%s %s %s %s\n' "${STORE_TOTAL:-none}" "$LEVEL" "$LAST_DANGER" "${AER_DEV:-none}" > "$STATE.tmp.$$" \
  && mv -f "$STATE.tmp.$$" "$STATE"
