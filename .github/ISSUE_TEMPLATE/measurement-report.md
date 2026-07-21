---
name: "📊 Measurement report"
about: Share your BadDLLP numbers — every machine adds a data point
title: "[report] Host / TB version / GPU"
labels: measurement
---

<!-- Fill in what you can; partial data is welcome too. -->

```
Host / TB version : (e.g. Mac Pro 2013, TB2 / ThinkPad X1, TB4)
Enclosure & GPU   : (e.g. Razer Core X + RTX 3090)
OS / kernel       : (e.g. Ubuntu 26.04, 6.14)
BadDLLP baseline  : (idle errors per 5 min)
Under load        : (errors per 5 min during generation / model swap)
Freeze avoided?   : yes / no / never froze
Notes             : anything odd
```

How measured (optional): `burst_test.sh` output, `bake_meter.csv` excerpts,
or raw `/sys/bus/pci/devices/<dev>/aer_dev_correctable` readings.
