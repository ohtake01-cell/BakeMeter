/* SHOT0 BEGIN: MacPro2013 TB eGPU — NVIDIA BAR1を最初のBAR測定前に64MiBへ固定 */
/*
 * 王命(2026-07-17 06:22 円卓): 10de:2204(RTX3090/GA102)・10de:2504(RTX3060/GA106)の
 * function 0 のみ、BAR1をResizable BARでsize=6(64MiB)に固定するbuilt-in early quirk。
 * このファイルは drivers/pci/quirks.c の末尾へそのまま追記する(apply_shot0_patch.sh)。
 *
 * 背景(夜戦全実測 2026-07-17 / Code相談3_early_quirk設計v10):
 *  - Mac Pro 2013(TB2)下側枝のprefetchable窓は288MiB。3090+3060同居は
 *    両方BAR1=64MiB(96+96=192≦288)以外に物理解なし。
 *  - 稼働後のlive resizeは番地移動だけで凍結(journal実証10回)。
 *    → BARサイズは「最初の割当ての瞬間」に64MiBで確定し、以後一切動かさない。
 *
 * 掛け所: pci_setup_device()は pci_fixup_early を pci_read_bases() より前に呼ぶ
 * (probe.c の "Early fixups, before probing the BARs"。verify_static.sh が実ソースで
 * この順序を機械確認する)。ここでReBAR制御へsize=6を直書きすれば、kernelの最初の
 * サイズ測定が64MiBを読み、以後の割当ては最初から64MiBで確定する。
 *
 * config write順はkernel自身のBAR測定(__pci_read_base)と同型:
 *   memory decode一時停止 → ReBAR CTRL書込(1レジスタのみ) → 読み戻し検証 → decode復元。
 * MMIOアクセスは一切しない。該当エントリ無し/64MiB非対応/読み戻し不一致の場合は
 * 何も変えずログして退く(fail-closed)。
 */
static void quirk_shot0_nvidia_bar1_64mib(struct pci_dev *pdev)
{
	int pos, nbars, i;
	u32 cap, ctrl;
	u16 orig_cmd;

	/* 対象限定: function 0 のみ(HDA等の他functionは触らない) */
	if (PCI_FUNC(pdev->devfn) != 0)
		return;

	pos = pci_find_ext_capability(pdev, PCI_EXT_CAP_ID_REBAR);
	if (!pos) {
		pci_info(pdev, "shot0: no ReBAR capability, leaving BARs untouched\n");
		return;
	}

	pci_read_config_dword(pdev, pos + PCI_REBAR_CTRL, &ctrl);
	nbars = (ctrl & PCI_REBAR_CTRL_NBAR_MASK) >> PCI_REBAR_CTRL_NBAR_SHIFT;

	for (i = 0; i < nbars; i++, pos += 8) {
		int bar_idx, old_size, new_size;

		pci_read_config_dword(pdev, pos + PCI_REBAR_CTRL, &ctrl);
		bar_idx = ctrl & PCI_REBAR_CTRL_BAR_IDX;
		if (bar_idx != 1)	/* 対象限定: BAR1のエントリのみ */
			continue;

		/*
		 * 64MiB(size code 6)対応をCAPで確認。size code n対応=生bit(n+4)。
		 * 実測: 3090=0xffc0 / 3060=0x7fc0、共にbit10(64MiB)=対応。
		 */
		pci_read_config_dword(pdev, pos + PCI_REBAR_CAP, &cap);
		if (!(cap & (1u << (6 + 4)))) {
			pci_warn(pdev, "shot0: BAR1 64MiB unsupported (cap=%#010x), leaving BARs untouched\n",
				 cap);
			return;
		}

		old_size = (ctrl & PCI_REBAR_CTRL_BAR_SIZE) >> PCI_REBAR_CTRL_BAR_SHIFT;
		if (old_size == 6) {
			pci_info(pdev, "shot0: BAR1 already size=6 (64MiB), no write\n");
			return;
		}

		/* __pci_read_base と同型: 書換え中はmemory decodeを止める */
		pci_read_config_word(pdev, PCI_COMMAND, &orig_cmd);
		if (orig_cmd & PCI_COMMAND_MEMORY)
			pci_write_config_word(pdev, PCI_COMMAND,
					      orig_cmd & ~PCI_COMMAND_MEMORY);

		ctrl &= ~PCI_REBAR_CTRL_BAR_SIZE;
		ctrl |= 6u << PCI_REBAR_CTRL_BAR_SHIFT;
		pci_write_config_dword(pdev, pos + PCI_REBAR_CTRL, ctrl);

		pci_read_config_dword(pdev, pos + PCI_REBAR_CTRL, &ctrl);
		new_size = (ctrl & PCI_REBAR_CTRL_BAR_SIZE) >> PCI_REBAR_CTRL_BAR_SHIFT;

		if (orig_cmd & PCI_COMMAND_MEMORY)
			pci_write_config_word(pdev, PCI_COMMAND, orig_cmd);

		if (new_size == 6)
			pci_info(pdev, "shot0: BAR1 size %d -> 6 (64MiB), fixed before first sizing\n",
				 old_size);
		else
			pci_err(pdev, "shot0: BAR1 resize write did not stick (ctrl=%#010x, size=%d)\n",
				ctrl, new_size);
		return;
	}

	pci_info(pdev, "shot0: no ReBAR entry for BAR1, leaving BARs untouched\n");
}
DECLARE_PCI_FIXUP_EARLY(PCI_VENDOR_ID_NVIDIA, 0x2204, quirk_shot0_nvidia_bar1_64mib); /* RTX 3090 GA102 */
DECLARE_PCI_FIXUP_EARLY(PCI_VENDOR_ID_NVIDIA, 0x2504, quirk_shot0_nvidia_bar1_64mib); /* RTX 3060 GA106 */
/* SHOT0 END */
