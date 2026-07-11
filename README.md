# BakeMeter 🌡

**Early-warning system for Thunderbolt eGPU freezes on Linux LLM servers.**

If you run LLMs (Ollama etc.) on an eGPU over Thunderbolt and your machine
randomly hard-freezes — especially during long generations — you likely have
the same disease we measured: a constant stream of correctable PCIe `BadDLLP`
errors on the TB link, with an occasional fatal one that kills the bus.
It is *not* your PSU, *not* heat, and replacing cables/adapters/enclosures/hosts
does not change the rate. See [docs/findings.md](docs/findings.md) for the data.

The good news: **freezes are predictable.** Fatal errors are preceded by hours
of elevated correctable-error activity. BakeMeter counts them and sheds GPU
load before the crash.

## Quick start

```bash
# 1. Watch your error level (run every 5 min from cron)
*/5 * * * * bash /path/to/scripts/bake_meter.sh

# 2. Reproduce & measure your own error rate (safe-ish; see script header)
MODEL=llama3:8b bash scripts/burst_test.sh
```

`bake_meter.sh` (v2) reads the kernel's **sysfs AER counters**
(`aer_dev_correctable` → BadDLLP) as per-interval deltas — `journalctl`
rate-limits AER messages and undercounted by **~34×** in our measurements
(findings §8). It logs to CSV, writes a machine-readable `bake_state.json`
for external gates, warns at 1,000 errors/interval, and at 5,000 unloads all
Ollama models — once, on the transition into DANGER (traffic stops, freeze
avoided; models reload on next use), then verifies the unload actually
happened. After any DANGER it holds a `COOLDOWN` level for 60 min: in our
logs a fatal error struck ~30 min *after* traffic had stopped, and error
storms have continued with no model loaded (findings §9). Thresholds are
provisional and configurable via environment variables — collect a few days
of CSV and recalibrate on your rig.

## Near-zero-freeze operating policy (from measured data)

1. Keep your main model resident (`keep_alive -1`) — model swaps cost
   ~130 errors/GB measured at the sysfs counter (~3–5/GB in the rate-limited
   journal).
2. Cap generation length — token streaming produces errors continuously.
3. Run BakeMeter as the safety net.
4. After any DANGER reading, keep the link quiet for at least an hour —
   the danger state outlives the traffic, and idle is not always safe
   (findings §6, §9).
5. The only true cure is a native PCIe slot. Until then, this keeps you alive.

## To fellow Mac Pro 2013 (trash can) owners

Your machine can still be a real LLM server in 2026 — ours runs a RTX 3090
over TB2 daily. Hard-won tips: the eGPU boots **only on the bottom TB bus**,
it must be **connected before power-on** (hot-plug is never recognized), and
the freezes you hit during long generations are the link-error disease above —
measurable, predictable, and survivable with BakeMeter. Don't throw the can
away. 🗑✨

## Status / contributing

Born 2026-07-10 from a night of controlled experiments on a Mac Pro 2013
(TB2) + Razer Core X + RTX 3090 — probably the least reasonable LLM server in
the world, which is exactly why it needed this. PRs, issues and measurements
from other TB hosts (TB3/TB4/USB4) are very welcome: post your
`burst_test.sh` numbers and machine details.

MIT licensed.
