#!/bin/bash
# BakeMeter gate check — "is it safe to START heavy GPU work right now?"
# Reads the bake_state.json written by bake_meter.sh (v2) and answers with an
# exit code, so any script can gate model swaps, image generation or batch
# jobs behind the meter:
#
#   bash gate_check.sh && run_my_heavy_gpu_job
#
# Exit codes:
#   0  allow            (level OK; or WARN unless BM_GATE_STRICT=1)
#   2  blocked          (DANGER, or COOLDOWN — the danger state outlives the
#                        traffic; fatal errors have struck ~30 min after
#                        traffic stopped, see docs/findings.md §6/§9)
#   3  blocked, no data (state file missing/unreadable/stale — the meter is
#                        not running. Fail-closed: DON'T start heavy work
#                        blind. Light interactive use is your call.)
#
# Config via environment (defaults in parentheses):
#   BM_STATE          state JSON path (~/freeze_test/bake_state.json)
#   BM_GATE_MAX_AGE   seconds before the state counts as stale (600)
#   BM_GATE_STRICT    "1" = also block on WARN (0)

STATE_JSON="${BM_STATE:-$HOME/freeze_test/bake_state.json}"
MAX_AGE="${BM_GATE_MAX_AGE:-600}"
STRICT="${BM_GATE_STRICT:-0}"

if [ ! -r "$STATE_JSON" ]; then
  echo "gate: BLOCKED (no meter state at $STATE_JSON — is bake_meter.sh in cron?)" >&2
  exit 3
fi

read -r LEVEL EPOCH DELTA <<EOF
$(python3 -c "
import json,sys
try:
    s = json.load(open(sys.argv[1]))
    print(s.get('level','UNKNOWN'), int(s.get('epoch',0)), s.get('delta','?'))
except Exception:
    print('UNPARSEABLE 0 ?')
" "$STATE_JSON")
EOF

NOW=$(date +%s)
AGE=$((NOW - EPOCH))

if [ "$LEVEL" = "UNPARSEABLE" ] || [ "$EPOCH" -le 0 ]; then
  echo "gate: BLOCKED (state file unreadable/unparseable)" >&2
  exit 3
fi
if [ "$AGE" -gt "$MAX_AGE" ]; then
  echo "gate: BLOCKED (state is ${AGE}s old, max ${MAX_AGE}s — meter stopped?)" >&2
  exit 3
fi

case "$LEVEL" in
  OK)
    echo "gate: allow (level OK, delta=$DELTA, age=${AGE}s)"
    exit 0 ;;
  WARN)
    if [ "$STRICT" = "1" ]; then
      echo "gate: BLOCKED (level WARN, delta=$DELTA, strict mode)" >&2
      exit 2
    fi
    echo "gate: allow with warning (level WARN, delta=$DELTA — consider postponing)"
    exit 0 ;;
  DANGER|COOLDOWN)
    echo "gate: BLOCKED (level $LEVEL, delta=$DELTA, age=${AGE}s — keep the link quiet)" >&2
    exit 2 ;;
  *)
    echo "gate: BLOCKED (unknown level '$LEVEL')" >&2
    exit 3 ;;
esac
