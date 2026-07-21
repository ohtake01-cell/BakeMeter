---
name: "📊 実測報告"
about: あなたのマシンの BadDLLP 実測値を教えてください — 1台ぶんが丸ごと貴重なデータです
title: "[report] ホスト / TB世代 / GPU"
labels: measurement
---

<!-- 書ける範囲でOK。部分的なデータも歓迎です。 -->

```
ホスト / TB世代    : (例: Mac Pro 2013, TB2 / ThinkPad X1, TB4)
筐体とGPU          : (例: Razer Core X + RTX 3090)
OS / カーネル      : (例: Ubuntu 26.04, 6.14)
BadDLLP 平常時     : (アイドル時の5分あたりエラー数)
負荷時             : (生成中・モデル載せ替え中の5分あたりエラー数)
凍結を回避できた?  : はい / いいえ / そもそも凍結しない
備考               : 気づいたことなんでも
```

計測方法(任意): `burst_test.sh` の出力、`bake_meter.csv` の抜粋、
`/sys/bus/pci/devices/<dev>/aer_dev_correctable` の生の値など。
