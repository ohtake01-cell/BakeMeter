#!/bin/bash
# BakeMeter regression tests — run the real script against a fake sysfs tree
# (BM_SYSFS_ROOT) and assert the state machine, including the recovery paths
# that once misfired in production (fallback poisoning the baseline, see
# docs/incident-2026-07-12.md item 5).
#
#   bash scripts/test_bake_meter.sh            # uses scripts/bake_meter.sh
#   BM_SCRIPT=path/to/script bash test_bake_meter.sh
#
# No root, no real counters, no Ollama needed (BM_SHED=0 throughout).

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${BM_SCRIPT:-$HERE/bake_meter.sh}"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
SYS="$T/sys"; DEV="0000:18:01.0"; D="$T/data"
AER="$SYS/$DEV/aer_dev_correctable"
mkdir -p "$SYS/$DEV"

PASS=0; FAIL=0

meter() { # run one metering cycle; COOLDOWN_MIN overrides the cooldown floor
  BM_LOG="$D/bake.csv" BM_ALERT="$D/ALERT.txt" BM_SHED=0 \
  BM_SYSFS_ROOT="$SYS" BM_AER_DEV="$DEV" BM_COOLDOWN_MIN="${COOLDOWN_MIN:-30}" \
  bash "$SCRIPT" 2>/dev/null
}

check() { # $1=name $2=want "delta,level,source"
  local last got
  last=$(tail -1 "$D/bake.csv")
  got=$(echo "$last" | awk -F, '{print $2","$3","$6}')
  if [ "$got" = "$2" ]; then
    PASS=$((PASS+1)); echo "ok   $1  ($got)"
  else
    FAIL=$((FAIL+1)); echo "FAIL $1  want=$2 got=$got  line=[$last]"
  fi
}

fresh() { rm -rf "$D"; mkdir -p "$D"; }
counter() { printf 'BadDLLP %s\nTOTAL_ERR_COR %s\n' "$1" "$1" > "$AER"; }
gone() { rm -f "$AER"; }

echo "# basic state machine"
fresh; counter 100000
meter; check "first run = baseline only"        "0,OK,sysfs_first_run"
counter 101000
meter; check "delta 1000 = WARN"                "1000,WARN,sysfs"
counter 107000
meter; check "delta 6000 = DANGER"              "6000,DANGER,sysfs"
counter 107000
meter; check "quiet after danger = COOLDOWN"    "0,COOLDOWN,sysfs"
counter 50
meter; check "counter regression = reboot, no alarm" "0,COOLDOWN,sysfs_reset"

echo "# cooldown lift: timer floor passed AND last 6 samples quiet"
fresh; counter 100000; meter
counter 107000; COOLDOWN_MIN=0 meter   # DANGER
for i in 1 2 3 4 5 6; do counter $((107000 + i)); COOLDOWN_MIN=0 meter; done
counter 107007; COOLDOWN_MIN=0 meter
check "cooldown lifts after sustained quiet"    "1,OK,sysfs"

echo "# incident 2026-07-12 regressions: sysfs loss and recovery"
fresh; counter 228000
meter                                            # baseline
counter 228000; meter                            # steady
gone
meter; check "sysfs lost = honest fallback"     "0,OK,journalctl"
read -r ST_TOTAL _ < "$D/bake_meter.state"
if [ "$ST_TOTAL" = "228000" ]; then PASS=$((PASS+1)); echo "ok   fallback keeps last real total in state"
else FAIL=$((FAIL+1)); echo "FAIL state poisoned during fallback: [$ST_TOTAL]"; fi
counter 228000
meter; check "recovery, no new errors = OK (was: false DANGER)" "0,OK,sysfs"

fresh; gone
meter; check "first-ever run in fallback"       "0,OK,journalctl"
counter 500000
meter; check "recovery from day-one fallback = baseline" "0,OK,sysfs_first_run"

fresh; counter 100000; meter; gone; meter
counter 106000
meter; check "real burst on recovery still fires" "6000,DANGER,sysfs"

echo "# corrupted state file"
fresh; counter 100000; meter
printf '100' > "$D/bake_meter.state"             # truncated mid-write
counter 100100
meter; check "truncated state = re-baseline, no false alarm" "0,OK,sysfs_first_run"

echo
echo "passed $PASS / $((PASS+FAIL))"
[ "$FAIL" -eq 0 ]
