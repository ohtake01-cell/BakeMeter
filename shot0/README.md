# Shot0: NVIDIA BAR1をenumeration前に64MiBへ固定するbuilt-in early quirk

王命(2026-07-17 06:22 円卓・Codex共有)に基づくCode担当分の実装。
Mac Pro 2013(TB2)下側枝のprefetchable窓288MiBに3090+3060を同居させるため、
**最初のBAR測定より前に**ReBAR制御へsize=6(64MiB)を直書きし、割当て後は番地を一切動かさない。

- 設計正本: `Code相談3_early_quirk設計v10_20260717.md`(Claude) / 王命でHEADER相→**EARLY相**に確定
- 廃止済み: initramfs `resource1_resize` Shot(割当て後に番地が動くため)
- 初実射: **Codex監査合格後**の「3060単体・right-bottom口・cold boot 1回」のみ。引き金は常に王。

## 仕組み(掛け所)

`pci_setup_device()`は `pci_fixup_device(pci_fixup_early, dev)` を `pci_read_bases()` **より前**に呼ぶ
(probe.c内コメント "Early fixups, before probing the BARs"。`verify_static.sh` V1が実ソースで機械確認)。
この時点で `dev->cfg_size` は設定済みのため extended capability 探索も可能(V2で確認)。
ここでReBAR CTRLへsize=6を書けば、kernelの最初のサイズ測定が64MiBを読み、
最初の割当てから64MiBで確定する。

config write順はkernel自身のBAR測定(`__pci_read_base`)と同型:
**memory decode一時停止 → ReBAR CTRL書込(1レジスタ) → 読み戻し検証 → decode復元**。
MMIOには触れない。cap無し・64MiB非対応・BAR1エントリ無し・書込み不成立は全て何も変えず退く(fail-closed)。

対象限定: `10de:2204`(RTX3090/GA102)・`10de:2504`(RTX3060/GA106)、**function 0のみ**、**BAR1エントリのみ**。

## ファイル

| ファイル | 役割 | 実機変更 |
|---|---|---|
| `src/shot0_quirk.c` | quirk本体(quirks.c末尾へ追記する断片) | — |
| `scripts/apply_shot0_patch.sh` | ソースツリーへ追記+監査用diff生成 | なし(ツリー内のみ) |
| `scripts/verify_static.sh` | 静的検証V1〜V5(掛け所順序・定数・相・CONFIG) | なし(読むだけ) |
| `scripts/build_kernel_shot0.sh` | apt-get source→適用→検証→`bindeb-pkg`(+shot0) | なし(deb生成まで) |
| `scripts/arm_oneshot_grub.sh` | deb install+custom.cfg+`grub-reboot`(一回限り) | **あり(王報告ゲート付き)** |
| `scripts/rollback_shot0.sh` | 装填解除+`--purge`でshot0 kernel完全撤去 | あり(復旧方向のみ) |
| `scripts/collect_logs_shot0.sh` | 実射後の証拠採取(全てread-only) | なし |
| `test/shot0_mock.c` `test/run_mock.sh` | kernel APIスタブでの模擬試験(T1〜T8) | なし(どこでも実行可) |

## 実行順序(実コマンド)

```bash
# 0. 模擬試験(どこでも・実機不要)
bash shot0/test/run_mock.sh

# 1. build(userland・王国を止めない。nice -n19、数時間)
bash shot0/scripts/build_kernel_shot0.sh
#    → 内部で apply_shot0_patch.sh と verify_static.sh を実行。FAILなら進まない
#    → 生成物: ~/shot0_build/linux-image-*+shot0*.deb / linux-headers-*+shot0*.deb + SHA256

# 2. Codex監査へ: shot0_evidence/shot0_quirks.diff・verify_static.sh結果・deb SHA256を円卓提出

# 2.5 release gate(差分buildでも新quirkの実行コードがdebに入っている事を機械証明・全PASS必須)
bash shot0/scripts/verify_deb_shot0.sh \
  ~/shot0_build/linux-image-*+shot0*.deb ~/shot0_build/linux-headers-*+shot0*.deb \
  ~/shot0_build.log ~/shot0_build/linux-7.0.0
#    → G1 buildログ順序 / G2 vmlinuz+System.map各1個同一release / G3 quirkシンボル /
#      G4 新文字列=1・旧文字列=0 / G5 package対+接頭辞。FAILならfull build検討+円卓報告

# ---- ここから先は監査合格後・王へ直前報告してから(引き金は王) ----

# 3. 装填(dpkg -i + DKMS nvidia確認 + custom.cfg + grub-reboot。rebootはしない)
sudo bash shot0/scripts/arm_oneshot_grub.sh ~/shot0_build/linux-image-*+shot0*.deb ~/shot0_build/linux-headers-*+shot0*.deb

# 4. 再起動は王の手で(3060単体・右下口・cold boot)

# 5. 起動後すぐ証拠採取(read-only)
bash shot0/scripts/collect_logs_shot0.sh

# 6. 撤収(いつでも)
sudo bash shot0/scripts/rollback_shot0.sh          # 装填解除のみ
sudo bash shot0/scripts/rollback_shot0.sh --purge  # +shot0 kernel完全撤去
```

## 安全設計(禁止事項の遵守)

- **live resize / remove / rescan / assign-busses / 2枚同時cold boot はどのスクリプトも行わない**
- デフォルト起動kernelは一切変更しない。`grub-reboot`のnext_entryは1回で自動消滅
  → 凍結しても電源長押しで現行kernelに自動復帰(実戦済みの型)
- `arm_oneshot_grub.sh` は王報告チェックリスト表示+`SHOT0-ARM`手入力が無いと何もしない
- DKMSでnvidiaモジュールが新kernelに無い場合は装填前に中止(nvidia-smi検証が成立しないため)
- 成功/中止条件の**正本はClaude設計書**。`collect_logs_shot0.sh`は事実の採取のみで判定しない

## 検証状況(反捏造規約)

**済:**
- 模擬試験T1〜T8全PASS(quirk本体をそのままコンパイル。サイズ書換え・対象限定・fail-closed・
  decode OFF中書込み・err経路のdecode復元を確認)
- 全スクリプト `bash -n` 構文確認

**未(実機でしか出来ない・順番に実施):**
- kernel `7.0.0-27-generic` 実ソースでの `verify_static.sh`(V1掛け所順序は6.x系ソース知識に基づく。
  実ツリーで機械確認するまで仮説扱い)
- 実build(bindeb-pkg)と生成deb — 未実施
- Ubuntu 26.04のdeb-src有効化状態 — 未確認
- **64MiBでGA106が生きるか — 未証明**(v8「No devices」の原因未特定。これはShot0実射そのものが検証)
- EARLY相でのReBAR書込みがEFI初期化済みGPUで有効か — 未実証(実射で判明)
