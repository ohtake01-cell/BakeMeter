# Findings: why Thunderbolt eGPU hosts freeze during LLM inference

Measured on a Mac Pro 2013 (TB2) → Apple TB2/TB3 adapter → Razer Core X → RTX 3090,
Ubuntu, Ollama. Method: GPU power sampled at 200 ms + kernel PCIe/AER log written
to disk (evidence survives a freeze), then controlled load patterns. 2026-07-10.

## 1. The freeze is a link-integrity problem, not power or heat

- Correctable `BadDLLP` (Data Link Layer) errors flow whenever data crosses the
  TB link — starting at **13 W** GPU draw, long before any power spike.
- Sustained image-generation load (hot, steady, little PCIe traffic after the
  initial upload) produces almost no errors. Long LLM generations (cool, but
  continuous PCIe traffic) produce them constantly.
- Occasionally one error is **Uncorrectable (Fatal)** → the GPU falls off the
  bus and the kernel hangs. That is the "random" freeze.

## 2. Error rates are stable and measurable

| Operation | Rate |
|---|---|
| Model load (VRAM upload) | ~3–5 errors/GB |
| Token generation | ~1–3 errors/second |
| Idle | 0 |

A 17 GB model swap ≈ 50–80 errors. One minute of generation ≈ 60–180 errors.
Hundreds of correctable errors per day are survivable; the fatal one is a rare
draw whose probability scales with total traffic.

> **2026-07-11 correction:** these rates were measured via `journalctl`, which
> undercounts by ~34× due to kernel rate limiting (see §8). The *relative*
> comparisons hold; the absolute numbers are ~34× higher (e.g. ~133 errors/GB
> measured via sysfs on a 19.3 GB load).

## 3. Swapping parts does not help

Same error rate (~100 per test run) after replacing, one at a time:
cable (new), TB2→TB3 adapter (new), port (3 tried), **enclosure (second unit)**,
**entire host (second identical machine)**. Conclusion: the TB2→adapter→TB3
chain itself runs at this error rate. Community reports show the same signature
on modern TB4 hosts too (unresolved), so this is a Linux+TB+eGPU pathology, not
one broken part.

## 4. Freezes are predictable

In our logs, the fatal error was preceded by **hours** of elevated correctable-
error activity. That makes prevention possible: count errors per hour, and shed
GPU load (unload models) when the rate climbs. That is what `bake_meter.sh` does.

## 5. Practical near-zero-freeze policy

1. Keep the workhorse model resident (`keep_alive -1`); avoid large model swaps.
2. Cap generation length/time (long "thinking" = long exposure).
3. Run `bake_meter.sh` from cron: warn at 50 errors/hour, shed load at 200/hour.
4. True zero requires removing Thunderbolt from the path (native PCIe host).

## 6. The danger state outlives the traffic (2026-07-10, second night)

After an error storm (237 errors/hour), a **fatal error struck ~30 minutes
later while the link was nearly idle** (no model loaded, no generation —
verified in Ollama logs). Treat an elevated error count as a lingering danger
state, not just a live-traffic signal: after a DANGER reading, keep the link
quiet well beyond the storm itself. BakeMeter had been reporting DANGER for
25 minutes before this freeze — the early warning works.

## 7. Panic-type freezes can self-heal via kdump

With `crashkernel=...` configured (Ubuntu kdump-tools), one freeze turned out
to be a kernel panic: the crash kernel took over and **the machine rebooted
itself, services and all — zero human touch**. Hard hangs still need a power
cycle, but you can widen the self-healing net:

```
echo "kernel.hung_task_panic=1
kernel.panic=30" | sudo tee /etc/sysctl.d/99-bakemeter-selfheal.conf && sudo sysctl --system
```

This converts silent-hang freezes into panics, which kdump then turns into a
clean automatic reboot.

**Drill result (deliberate `sysrq-trigger` crash, 2026-07-10):** SSH back in
**92 s**, all services (Ollama, web UI, cron) back in **114 s**, zero human
intervention. Test yours the same way before you trust it:
`echo c | sudo tee /proc/sysrq-trigger` (crashes the machine on purpose).

## 8. journalctl undercounts ~34× — read the sysfs AER counters (2026-07-10/11)

The kernel **rate-limits AER console output** (`... callbacks suppressed` in
dmesg), so counting journal lines misses most errors. Measured on the same
machine at the same moment:

| Source | Count |
|---|---|
| `journalctl -k` last 1 h | 297 |
| sysfs `aer_dev_correctable` BadDLLP (24 min after reboot) | 9,979 |

≈ **34× undercount**. Next day the sysfs total read 170,848 while the
journal's 1-hour count was 0. The Linux AER docs confirm: console output is
rate-limited, statistics are exposed in sysfs. Two practical notes:

- Read `/sys/bus/pci/devices/<bdf>/aer_dev_correctable` (BadDLLP line) as a
  **delta** between samples. The counter increments on the device that
  *observed* the error — the link partner (a TB/PCIe bridge above the GPU),
  not the GPU itself.
- Per-GB recalibration: a 19.3 GB model load produced 2,565 sysfs errors ≈
  **133 errors/GB** — consistent with the journal-based 3–5/GB × 34, though
  treat 34× as a rough factor, not a calibration constant.

Consequences for BakeMeter (v2, this repo):
- Primary meter = sysfs BadDLLP delta per 5-min interval; journalctl kept
  only as a reference column and fallback.
- Provisional thresholds: WARN 1,000 / DANGER 5,000 per 5-min delta
  (replacing the journal-based 50/200 per hour). Recalibrate on your rig.
- First run records a baseline only (the boot-time backlog is cumulative,
  not fresh traffic); a counter that goes backwards means a reboot.
- Shedding fires **once, on the transition into DANGER** — the old
  every-interval shedding turned out to be repeated no-ops triggered by an
  hour-window echo of an already-finished storm.
- After shedding, re-check `api/ps` and report leftovers honestly.

## 9. "Idle = 0" is not universal — cooldown is mandatory (2026-07-11)

§2's "Idle = 0" was true during the controlled tests of 2026-07-10, but it is
not a universal law:

- After unloading **all** models, 5-minute deltas of **13,856 and then
  20,253 errors** were recorded with zero GPU load (09:50–10:00).
- At 11:20 the eGPU **fell off the bus at GPU 0%**, no model loaded, with
  normal error levels in the minutes before.

Together with §6 (fatal error ~30 min after traffic stopped), this means a
DANGER reading marks a **lingering danger state**: reducing traffic reduces
exposure, but does not instantly make the link safe. BakeMeter v2 therefore
holds a `COOLDOWN` level after any DANGER — proposed policy: no heavy GPU
work until **≥60 min since the last DANGER and all samples in the last
30 min below WARN**. (60 min = 2× the observed 30-min lag as an engineering
safety margin, not a measured optimum.)

## Mac Pro 2013 specific notes

- The eGPU boots only on the bottom TB bus; hot-plug after boot is not
  recognized (device must be present at boot).
- `pcie_aspm=off` was already applied and does not stop the errors here.
