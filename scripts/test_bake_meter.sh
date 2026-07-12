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

meter_auto() { # like meter() but let the script autodetect+pin the device
  BM_LOG="$D/bake.csv" BM_ALERT="$D/ALERT.txt" BM_SHED=0 \
  BM_SYSFS_ROOT="$SYS" BM_COOLDOWN_MIN="${COOLDOWN_MIN:-30}" \
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
# bake_state.json must publish both delta and its compat alias delta_5m
if grep -q '"delta":' "$D/bake_state.json" && grep -q '"delta_5m":' "$D/bake_state.json"; then
  PASS=$((PASS+1)); echo "ok   bake_state.json carries delta + delta_5m alias"
else
  FAIL=$((FAIL+1)); echo "FAIL bake_state.json missing delta/delta_5m: [$(cat "$D/bake_state.json")]"
fi
counter 101000
counter 101000
meter; check "delta 1000 = WARN"                "1000,WARN,sysfs"
counter 107000
meter; check "delta 6000 = DANGER"              "6000,DANGER,sysfs"
counter 107000
meter; check "quiet after danger = COOLDOWN"    "0,COOLDOWN,sysfs"
counter 50
meter; check "reboot: post-boot total is the delta (below WARN)" "50,COOLDOWN,sysfs_reset"

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

echo "# P1 (Codex): pin one device; a sibling device must not cause false DANGER"
fresh
DEV2="0000:00:1c.0"; mkdir -p "$SYS/$DEV2"
printf 'BadDLLP 5000\n' > "$SYS/$DEV2/aer_dev_correctable"   # unrelated quiet device
counter 100000                                    # eGPU is busiest -> gets pinned
meter_auto; check "autodetect pins busiest device, baseline" "0,OK,sysfs_first_run"
read -r _ _ _ PINNED < "$D/bake_meter.state"
if [ "$PINNED" = "$DEV" ]; then PASS=$((PASS+1)); echo "ok   busiest device pinned in state ($PINNED)"
else FAIL=$((FAIL+1)); echo "FAIL wrong/no pinned device: [$PINNED]"; fi
gone                                              # eGPU drops off; sibling remains
meter_auto; check "pinned device gone = fallback, not a phantom reset" "0,OK,journalctl"
counter 100000                                    # eGPU returns, same lifetime counter
meter_auto; check "eGPU returns = OK, no false DANGER from sibling" "0,OK,sysfs"
rm -rf "$SYS/$DEV2"

echo "# P2 (Codex): reboot with a post-boot storm still fires (not discarded)"
fresh; counter 100000; meter                      # baseline
counter 6000                                      # reboot: counter reset, +6000 accrued at boot
meter; check "reboot post-boot storm = DANGER on the total" "6000,DANGER,sysfs_reset"

echo "# P2 (Codex): a failed unload check is not logged as a successful unload"
fresh; counter 100000; meter                      # baseline
counter 107000                                    # +7000 -> DANGER; shed on, Ollama down
BM_LOG="$D/bake.csv" BM_ALERT="$D/ALERT.txt" BM_SHED=1 BM_OLLAMA="http://127.0.0.1:1" \
  BM_SYSFS_ROOT="$SYS" BM_AER_DEV="$DEV" BM_COOLDOWN_MIN=30 bash "$SCRIPT" 2>/dev/null
if grep -q "COULD NOT verify" "$D/ALERT.txt" 2>/dev/null; then
  PASS=$((PASS+1)); echo "ok   unverifiable unload flagged, not reported as success"
else
  FAIL=$((FAIL+1)); echo "FAIL alert did not flag unverifiable unload: [$(cat "$D/ALERT.txt" 2>/dev/null)]"
fi
# P1 (Codex): DANGER must be published even when the shed path runs (Ollama down)
if grep -q '"level":"DANGER"' "$D/bake_state.json" 2>/dev/null; then
  PASS=$((PASS+1)); echo "ok   bake_state.json shows DANGER through a slow/hung shed"
else
  FAIL=$((FAIL+1)); echo "FAIL bake_state.json not DANGER during shed: [$(cat "$D/bake_state.json" 2>/dev/null)]"
fi

echo "# P1 (Codex): autodetect must not pin a zero-count device"
fresh
mkdir -p "$SYS/$DEV2"
printf 'BadDLLP 0\n' > "$SYS/$DEV2/aer_dev_correctable"   # unrelated port, no errors
counter 0                                                 # eGPU also 0 right after boot
meter_auto; check "all-zero boot = no pin, fallback" "0,OK,journalctl"
read -r _ _ _ PINNED < "$D/bake_meter.state"
if [ "$PINNED" = "none" ]; then PASS=$((PASS+1)); echo "ok   nothing pinned while every counter is 0"
else FAIL=$((FAIL+1)); echo "FAIL pinned a zero-count device: [$PINNED]"; fi
counter 3000                                              # errors appear on the eGPU link
meter_auto; check "positive count = pin the busy device, baseline" "0,OK,sysfs_first_run"
read -r _ _ _ PINNED < "$D/bake_meter.state"
if [ "$PINNED" = "$DEV" ]; then PASS=$((PASS+1)); echo "ok   pins the device that actually shows errors ($PINNED)"
else FAIL=$((FAIL+1)); echo "FAIL wrong pinned device: [$PINNED]"; fi
rm -rf "$SYS/$DEV2"

echo "# P2 (Codex): a legacy v2 baseline file is migrated on upgrade"
fresh
printf '500000,OK\n' > "$D/bake_meter_state"              # old v2 state: total,level
counter 505000                                            # +5000 since the legacy baseline
meter; check "legacy baseline migrated = burst not missed" "5000,DANGER,sysfs"

echo "# P2 (Codex): BM_STATE_JSON in a not-yet-existing directory is created"
fresh; counter 100000
BM_LOG="$D/bake.csv" BM_STATE_JSON="$D/container/system/bake_state.json" BM_SHED=0 \
  BM_SYSFS_ROOT="$SYS" BM_AER_DEV="$DEV" BM_COOLDOWN_MIN=30 bash "$SCRIPT" 2>/dev/null
if [ -f "$D/container/system/bake_state.json" ]; then
  PASS=$((PASS+1)); echo "ok   BM_STATE_JSON parent dir created, file written"
else
  FAIL=$((FAIL+1)); echo "FAIL BM_STATE_JSON parent dir not created"
fi

echo
echo "passed $PASS / $((PASS+FAIL))"
[ "$FAIL" -eq 0 ]
