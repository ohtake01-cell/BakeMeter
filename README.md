# BakeMeter 🌡

**Early-warning system for Thunderbolt eGPU freezes on Linux LLM servers.**

🇯🇵 日本語版はこちら → [README.ja.md](README.ja.md)

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

`bake_meter.sh` (v2.1) reads the **real sysfs AER counters** and logs the
5-minute delta to CSV: it warns at **1,000 errors/5 min** and at **5,000/5 min**
unloads all Ollama models once on the transition to DANGER, then verifies the
unload actually happened (traffic stops, freeze avoided; models reload on next
use). After DANGER it holds a **COOLDOWN** level for 30 min — and beyond that
until the recent samples are quiet — because the danger state outlives the
traffic: we measured a fatal error striking ~30 min *after* the link went idle
(findings #6). If sysfs AER is unavailable it falls back to `journalctl`
counting (50/h warn, 200/h danger) — but note journalctl undercounts by ~34x
due to rate-limit suppression (findings #8). The fallback never overwrites the
sysfs baseline, so a device that disappears and comes back (exactly what a
GPU drop-off looks like) cannot fake a burst. All thresholds and paths are
configurable via `BM_*` environment variables — see the script header.
An atomically-written `bake_state.json` is published every run for gating
downstream apps; `test_bake_meter.sh` is a 13-case regression suite that runs
the real script against a fake sysfs tree (no root, no GPU needed).

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

## Reporting your results 📬

Did it work? Did it not? Either way we want to hear — every machine adds a
data point. Open an [Issue](../../issues) with roughly this:

```
Host / TB version : (e.g. Mac Pro 2013, TB2 / ThinkPad X1, TB4)
Enclosure & GPU   : (e.g. Razer Core X + RTX 3090)
OS / kernel       : (e.g. Ubuntu 26.04, 6.14)
BadDLLP baseline  : (idle errors per 5 min)
Under load        : (errors per 5 min during generation / model swap)
Freeze avoided?   : yes / no / never froze
Notes             : anything odd
```

Fresh data point from our machine (2026-07-12): **8 model load/unload cycles
(17–18 GB each) produced +228k BadDLLP in 25 minutes** — model swapping is by
far the biggest single trigger we have measured. Keep your model resident.

## Status / contributing

Born 2026-07-10 from a night of controlled experiments on a Mac Pro 2013
(TB2) + Razer Core X + RTX 3090 — probably the least reasonable LLM server in
the world, which is exactly why it needed this. PRs, issues and measurements
from other TB hosts (TB3/TB4/USB4) are very welcome: post your
`burst_test.sh` numbers and machine details.

MIT licensed.
