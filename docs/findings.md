# Findings: why Thunderbolt eGPU hosts freeze during LLM inference

Measured on a Mac Pro 2013 (TB2) → Apple TB2/TB3 adapter → Razer Core X → RTX 3090,
Ubuntu, Ollama. Method: GPU power sampled at 200 ms + kernel PCIe/AER log written
to disk (evidence survives a freeze), then controlled load patterns. 2026-07-10.

## 1. The freeze is a link-integrity problem, not power or heat

- Correctable `BadDLLP` (Data Link Layer) errors flow whenever data crosses the
  TB link — starting at **13 W** GPU draw, long before any power spike.
- Sustained image-generation load (hot, steady, little PCIe traffic after the
  initial upload) produces almost no errors. Long LLM generations (cool, but
  continuous PCIe traffic) produce them constantly. (But an image *pipeline*
  that reloads its model per image is a different story — see §9.)
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

## 8. journalctl undercounts the errors ~34x under load (2026-07-10)

The kernel rate-limits AER log lines ("callbacks suppressed"), so grepping
`journalctl` — our original method — misses most events during bursts. On the
same interval we measured **297 events in the journal vs 9,979 on the sysfs
counter** (`aer_dev_correctable`, `BadDLLP` row) — a ~34x undercount. The
journal's 1-hour window also keeps an alarm ringing long after a burst has
stopped. `bake_meter.sh` v2 therefore reads the sysfs counters and alarms on
the **delta per 5-minute run** (provisional thresholds: warn 1000, danger
5000 — recalibrate from your own CSV), keeping journalctl only as a fallback.

## 9. Image generation: the reload loop is the storm, not the compute (2026-07-11)

Re-measured with the sysfs counters, §1's "image generation produces almost
no errors" needs a caveat: it holds only while the model stays resident. A
FLUX (ComfyUI) pipeline that unloaded models after every image and re-staged
them for the next (~16 GB: CLIP 4.8 GB + FLUX 11.3 GB, per image) cost
**~38,800 BadDLLP across a 6-image hour** (concurrent LLM traffic included).
The compute is still cheap — the *transfers* are the exposure. Total errors ≈
(errors/GB) × (GB moved), and the per-GB rate is a property of the TB link
that software cannot change (§3), so the only software lever is GB moved:

1. Keep the image model resident for the whole image session instead of the
   per-image unload/reload round trip (staged bytes for images 2..N drop ~80%).
2. Route "redo/again" requests by simple rules instead of waking the big chat
   model for triage.
3. Cache reference-image descriptions so the vision model isn't reloaded per
   retry.

Two more cautions from the same day's logs:

- **"Idle = 0" (§2) is not universal.** We recorded a no-load burst
  (13,856 → 20,253 errors per 5 min with no model resident) and one eGPU bus
  drop near idle. Transfer reduction shrinks exposure; it does not buy
  immunity.
- **One quiet sample after DANGER is not recovery.** A gate that reopened
  after a single quiet 5-minute reading let three images through, and the
  link re-entered DANGER twice within 40 minutes. Hence v2.1's COOLDOWN
  level (60 min after the last DANGER *and* a quiet last ~30 min), and
  hence gates should fail closed for heavy loads when the meter is stale.

## Mac Pro 2013 specific notes

- The eGPU boots only on the bottom TB bus; hot-plug after boot is not
  recognized (device must be present at boot).
- `pcie_aspm=off` was already applied and does not stop the errors here.
