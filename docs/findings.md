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

## 8. journalctl undercounts AER by ~34x — read sysfs counters instead

Kernel rate-limiting ("N callbacks suppressed") silently drops most AER log
lines under load. Measured on the same window: `journalctl -k` grep counted
**297** errors while the hardware counter
(`/sys/bus/pci/devices/<dev>/aer_dev_correctable`, `BadDLLP` row) had
accumulated **9,979** — a ~34x gap. Any log-based meter dramatically
underestimates the storm exactly when it matters.

Two design consequences, both applied in `scripts/bake_meter.sh` v2:

- **Count deltas of the sysfs counter per sample interval**, not log lines.
  The counter resets on reboot; treat a backwards jump as "count since boot".
- **Avoid trailing-window log queries for state.** A 1-hour `--since` window
  kept reporting DANGER (and re-unloading models every 5 minutes) for up to an
  hour *after* a burst had already stopped — a stale echo. Interval deltas go
  quiet immediately. Unload models only on the transition into DANGER, then
  re-check `api/ps` and record honestly whether the unload actually worked.

## 9. Unloading a model is a bigger burst than generating with it (2026-07-12)

We already knew loading a model costs errors (§2). Measured on the sysfs
counters, **unloading is worse** — and it is the single largest error source
we have logged.

In one controlled image run: generating an image (model load + 457 s of work)
cost **+3,084** BadDLLP. The cleanup `/free` that unloaded the 19 GB model
immediately after cost **+44,017** in the next 5-minute window — **~14x the
generation itself**, and enough to re-enter DANGER on its own.

Every DANGER episode we logged that day traced back to a model
unload/eviction burst, not to generation: an 8x load/unload A/B sweep, a
19 GB `/free`, back-to-back model evictions. Generation alone stayed in the
hundreds-per-image (WARN at most).

Consequences:

- **Don't unload to "be safe" — the unload is the risk.** Keep the workhorse
  (and, per session, the image) model resident; let it idle rather than
  evicting it. A resident model is a quiet link; a model swap is a storm.
- BakeMeter's own DANGER shed (unloading all models) is a deliberate exception:
  it accepts one unload burst to *stop all future traffic* when a fatal error
  looks imminent. Paying one storm to prevent the rest is the right trade —
  but only on the transition into DANGER, never routinely.
- If a pipeline evicts and re-stages a model per request, that eviction loop —
  not the compute — is what's cooking the link.

## Mac Pro 2013 specific notes

- The eGPU boots only on the bottom TB bus; hot-plug after boot is not
  recognized (device must be present at boot).
- `pcie_aspm=off` was already applied and does not stop the errors here.
