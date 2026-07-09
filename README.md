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

`bake_meter.sh` logs errors/hour to CSV, warns at 50/h, and at 200/h unloads
all Ollama models (traffic stops, freeze avoided; models reload on next use).
Thresholds and behavior are configurable via environment variables.

## Near-zero-freeze operating policy (from measured data)

1. Keep your main model resident (`keep_alive -1`) — model swaps cost ~3–5 errors/GB.
2. Cap generation length — token streaming costs ~1–3 errors/second.
3. Run BakeMeter as the safety net.
4. The only true cure is a native PCIe slot. Until then, this keeps you alive.

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
