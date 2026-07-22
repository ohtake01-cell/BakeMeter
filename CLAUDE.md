# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

BakeMeter ("化けメーター") is an early-warning system for Thunderbolt eGPU freezes on Linux LLM servers. Measured finding: correctable PCIe `BadDLLP` errors flow constantly on the TB link during LLM inference, and a rare fatal error kills the bus (the "random" freeze). Fatal errors are preceded by hours of elevated correctable-error activity, so the freeze is predictable — BakeMeter counts errors and sheds GPU load (unloads Ollama models) before the crash.

It is pure Bash + Markdown. There is no build system, no test suite, no linter config, and no CI. The scripts can only be truly exercised on a live Linux host with a Thunderbolt eGPU and Ollama; in any other environment, verification is limited to `bash -n scripts/*.sh` (syntax check) and `shellcheck` if available.

## Layout

- `scripts/bake_meter.sh` — the monitor (currently **v2**). Run every 5 minutes from cron. Reads the sysfs AER hardware counter (`aer_dev_correctable`, `BadDLLP` row), computes the per-interval delta, classifies a level, appends to CSV, writes a container-visible JSON state file, and on the transition into danger unloads all Ollama models once and verifies the unload via `api/ps`.
- `scripts/burst_test.sh` — reproduces LLM-style bursty PCIe traffic against Ollama to measure a machine's own error rate. Configured via env vars: `MODEL`, `BURSTS`, `TOKENS`, `BM_OLLAMA`, `BM_TESTLOG`.
- `docs/findings.md` — the measured evidence base. Findings are **numbered (#1–#8)** and referenced by number from the README, script comments, and commit messages.
- `README.md` / `README.ja.md` — English and Japanese versions of the same document.

## Key conventions

**The README is bilingual and must stay in sync.** Any content change to `README.md` must be mirrored in `README.ja.md` (and vice versa). Commit history shows both are updated together.

**Findings are append-only.** `docs/findings.md` entries are cited by number (e.g. "findings #8" in the v2 commit and script header). Never renumber existing findings; add new ones at the end. New behavior changes in the scripts should trace back to a finding.

**`bake_meter.sh` is deliberately shaped by findings #8 — don't "simplify" these away:**
- Error counting uses **sysfs counter deltas per interval**, not `journalctl` log lines: kernel rate-limiting makes journalctl undercount by ~34x. The journalctl count is still logged as a reference column, and used only as a fallback when sysfs is unreadable (with its own thresholds: 50/h warn, 200/h danger; source recorded honestly as `journalctl_fallback`).
- The sysfs counter resets on reboot; a backwards jump is treated as "count since boot", and the very first run records a baseline only (delta 0, source `sysfs_first_run`).
- Model unload fires **only on the transition into danger** (previous level ≠ 危険), never repeatedly while danger persists — trailing-window log queries caused re-unloads for up to an hour after a burst had stopped.
- After unloading, the script **re-checks `api/ps`** and records whether the unload actually worked.
- `bake_state.json` is written **atomically** (write to `.tmp`, then `mv`) so container-side readers never see a partial file.

**Japanese is part of the code, not decoration.** Script comments, log levels (`平常`=normal, `注意`=warn, `危険`=danger), and alert messages in `bake_meter.sh` are Japanese, and the levels are stored as-is in the CSV, state file, and `bake_state.json`. Changing these strings breaks downstream consumers and log continuity — keep them.

**Versioning is in-file.** The monitor's version (v2) and its changelog live in the header comment of `bake_meter.sh`, citing the audit findings that drove each change. Bump/extend that header when changing behavior.

## Data formats (do not break)

- `bake_meter.csv` row: `timestamp,delta_5m,level,cumulative_counter,journal_1h_reference,source`
- State file (`bake_meter_state`): single line `cumulative_counter,level`
- `bake_state.json`: `{"level","delta_5m","baddllp_total","journal_1h","source","ts","epoch"}` — read by downstream apps in containers as a danger gate.

## Machine-specific values

`bake_meter.sh` hardcodes paths from the reference machine (Mac Pro 2013): the AER sysfs device `0000:18:01.0`, `~/freeze_test/`, `~/local-ai-stack/data/open-webui/system/`. Thresholds `WARN_5M=1000` / `DANGER_5M=5000` are marked provisional (★暫定) pending calibration data. The README states thresholds are configurable via environment variables, but v2 currently defines them as plain assignments — if touching this area, making them `${WARN_5M:-1000}`-style env overrides would reconcile the two.

## Contribution focus

The project actively solicits measurement reports from other TB hosts (TB3/TB4/USB4) via GitHub Issues, using the report template in the README. Changes that add data points, calibration, or portability (auto-detecting the AER device, env-var config) fit the project's direction; the stated end goal is honest measurement — scripts record their data source and verify their own actions rather than assuming success.
