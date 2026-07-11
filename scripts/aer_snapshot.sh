#!/bin/bash
# BakeMeter AER snapshot — record one labeled point-in-time reading of the
# AER counters + link state + GPU state, as one JSON line. Chain several
# around the phases of a workload and diff the counters to attribute errors
# to phases, e.g. for one image generation:
#
#   bash aer_snapshot.sh before_request  img-042
#   ... LLM / prompt handling ...
#   bash aer_snapshot.sh after_llm       img-042
#   ... model load ...
#   bash aer_snapshot.sh after_load      img-042
#   ... sampler ...
#   bash aer_snapshot.sh after_sampler   img-042
#   ... cleanup / next model ...
#   bash aer_snapshot.sh after_cleanup   img-042
#
# The second argument tags every line with a session/request id so snapshots
# can be joined back to your own request logs.
#
# Config via environment (defaults in parentheses):
#   BM_SNAPLOG   JSONL output path (~/freeze_test/aer_snapshots.jsonl)
#   BM_AER_DEV   PCI BDF of the AER-reporting device (auto-detected — the
#                counter lives on the link partner above the GPU, see
#                docs/findings.md §8)

LABEL="${1:-unlabeled}"
SESSION="${2:-}"
SNAPLOG="${BM_SNAPLOG:-$HOME/freeze_test/aer_snapshots.jsonl}"

find_aer_dev() {
  if [ -n "$BM_AER_DEV" ] && [ -r "/sys/bus/pci/devices/$BM_AER_DEV/aer_dev_correctable" ]; then
    echo "$BM_AER_DEV"; return
  fi
  local d best="" best_n=-1 n gpu f
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
    for f in /sys/bus/pci/devices/*/aer_dev_correctable; do
      [ -r "$f" ] || continue
      n=$(awk '/^BadDLLP/{print $2}' "$f")
      if [ "${n:-0}" -gt "$best_n" ]; then best_n="${n:-0}"; best=$(basename "$(dirname "$f")"); fi
    done
  fi
  [ -n "$best" ] && echo "$best"
}

# Turn "Name value" counter files into a JSON object; empty object if unreadable.
counters_json() {
  [ -r "$1" ] || { echo "{}"; return; }
  awk 'NF==2 {printf "%s\"%s\":%s", sep, $1, $2; sep=","} END {print ""}' "$1" | sed 's/^/{/; s/$/}/'
}

AER_DEV=$(find_aer_dev)
DEVDIR="/sys/bus/pci/devices/$AER_DEV"

TS=$(date "+%Y-%m-%d %H:%M:%S")
EPOCH=$(date +%s)
COR=$(counters_json "$DEVDIR/aer_dev_correctable")
NONFATAL=$(counters_json "$DEVDIR/aer_dev_nonfatal")
FATAL=$(counters_json "$DEVDIR/aer_dev_fatal")
SPEED=$(cat "$DEVDIR/current_link_speed" 2>/dev/null || echo "n/a")
WIDTH=$(cat "$DEVDIR/current_link_width" 2>/dev/null || echo "n/a")
# memory.used,memory.total,utilization.gpu,power.draw,temperature.gpu
GPU=$(nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu,power.draw,temperature.gpu \
      --format=csv,noheader,nounits 2>/dev/null | head -1 || true)

mkdir -p "$(dirname "$SNAPLOG")"
printf '{"ts":"%s","epoch":%s,"label":"%s","session":"%s","aer_dev":"%s","correctable":%s,"nonfatal":%s,"fatal":%s,"link_speed":"%s","link_width":"%s","gpu_mem_util_pwr_temp":"%s"}\n' \
  "$TS" "$EPOCH" "$LABEL" "$SESSION" "${AER_DEV:-none}" "$COR" "$NONFATAL" "$FATAL" "$SPEED" "$WIDTH" "${GPU:-n/a}" \
  >> "$SNAPLOG"

# Echo the headline number so interactive use is immediately useful.
BADDLLP=$(awk '/^BadDLLP/{print $2}' "$DEVDIR/aer_dev_correctable" 2>/dev/null)
echo "snapshot [$LABEL] aer_dev=${AER_DEV:-none} BadDLLP=${BADDLLP:-n/a} -> $SNAPLOG"
