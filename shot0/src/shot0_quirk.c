/* SHOT0 BEGIN: MacPro2013 TB eGPU — NVIDIA BAR1を最初のBAR測定前に64MiBへ固定 */
/*
 * 王命(2026-07-17 06:22 円卓): 10de:2204(RTX3090/GA102)・10de:2504(RTX3060/GA106)の
 * function 0 のみ、BAR1をResizable BARでsize=6(64MiB)に固定するbuilt-in early quirk。
 * このファイルは drivers/pci/quirks.c の末尾へそのまま追記する(apply_shot0_patch.sh)。
 * quirks.c は <linux/dmi.h> をinclude済み(verify_static.shが機械確認)。
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
 * MMIOアクセスは一切しない。
 *
 * fail-closed契約(Codex監査P1対応 2026-07-17・第2ラウンド込み):
 *  - DMIがMacPro6,1でなければ発火しない(DMI未初期化・不明も発火しない)。
 *  - 全config読取りは戻り値と~0応答(デバイス消失)を検査。異常=不介入で退く。
 *  - decode停止は書込み成功だけでなく読み戻しでMEMORYビット消灯を確認してから
 *    ReBARへ進む(「成功を返すが変更を無視する」経路もfail-closed)。
 *  - ReBAR読み戻し不一致/失敗時は旧値の復元を試み、復元の成否はCTRL全体一致で検証・報告。
 *  - COMMAND復元はレジスタ全体一致で検証し、失敗は未検知にせずpci_errで報告する。
 */
static bool shot0_restore_command(struct pci_dev *pdev, u16 orig_cmd)
{
	u16 cmd_now;

	/* 検証はレジスタ全体の一致(P1第2ラウンド: MEMORYビットだけでは他ビット破損を見逃す) */
	if (pci_write_config_word(pdev, PCI_COMMAND, orig_cmd) == PCIBIOS_SUCCESSFUL &&
	    pci_read_config_word(pdev, PCI_COMMAND, &cmd_now) == PCIBIOS_SUCCESSFUL &&
	    cmd_now == orig_cmd)
		return true;

	pci_err(pdev, "shot0: COMMAND restore NOT verified (wanted %#06x)\n", orig_cmd);
	return false;
}

static void quirk_shot0_nvidia_bar1_64mib(struct pci_dev *pdev)
{
	int pos, nbars, i;
	u32 cap, ctrl, old_ctrl, verify;
	u16 orig_cmd;

	/* 対象限定: function 0 のみ(HDA等の他functionは触らない) */
	if (PCI_FUNC(pdev->devfn) != 0)
		return;

	/* 対象限定: この機体(MacPro6,1)以外では発火しない(fail-closed) */
	if (!dmi_match(DMI_PRODUCT_NAME, "MacPro6,1")) {
		pci_info(pdev, "shot0: not MacPro6,1, leaving BARs untouched\n");
		return;
	}

	pos = pci_find_ext_capability(pdev, PCI_EXT_CAP_ID_REBAR);
	if (!pos) {
		pci_info(pdev, "shot0: no ReBAR capability, leaving BARs untouched\n");
		return;
	}

	if (pci_read_config_dword(pdev, pos + PCI_REBAR_CTRL, &ctrl) != PCIBIOS_SUCCESSFUL ||
	    PCI_POSSIBLE_ERROR(ctrl)) {
		pci_warn(pdev, "shot0: ReBAR CTRL read failed, leaving BARs untouched\n");
		return;
	}
	nbars = (ctrl & PCI_REBAR_CTRL_NBAR_MASK) >> PCI_REBAR_CTRL_NBAR_SHIFT;

	for (i = 0; i < nbars; i++, pos += 8) {
		int bar_idx, old_size, new_size;

		if (pci_read_config_dword(pdev, pos + PCI_REBAR_CTRL, &ctrl) != PCIBIOS_SUCCESSFUL ||
		    PCI_POSSIBLE_ERROR(ctrl)) {
			pci_warn(pdev, "shot0: ReBAR entry %d read failed, leaving BARs untouched\n", i);
			return;
		}
		bar_idx = ctrl & PCI_REBAR_CTRL_BAR_IDX;
		if (bar_idx != 1)	/* 対象限定: BAR1のエントリのみ */
			continue;

		/*
		 * 64MiB(size code 6)対応をCAPで確認。size code n対応=生bit(n+4)。
		 * 実測: 3090=0xffc0 / 3060=0x7fc0、共にbit10(64MiB)=対応。
		 * 読取り失敗・~0応答はbit10が偽陽性になるため必ず先に弾く。
		 */
		if (pci_read_config_dword(pdev, pos + PCI_REBAR_CAP, &cap) != PCIBIOS_SUCCESSFUL ||
		    PCI_POSSIBLE_ERROR(cap)) {
			pci_warn(pdev, "shot0: ReBAR CAP read failed, leaving BARs untouched\n");
			return;
		}
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
		if (pci_read_config_word(pdev, PCI_COMMAND, &orig_cmd) != PCIBIOS_SUCCESSFUL ||
		    PCI_POSSIBLE_ERROR(orig_cmd)) {
			pci_warn(pdev, "shot0: COMMAND read failed, leaving BARs untouched\n");
			return;
		}
		if (orig_cmd & PCI_COMMAND_MEMORY) {
			u16 cmd_chk;

			/*
			 * P1第2ラウンド: 書込み成功の戻り値だけでは「成功を返すが
			 * 変更を黙って無視する」経路を検知できない。読み戻しで
			 * MEMORYビットが実際に落ちたことを確認してからReBARへ進む。
			 */
			if (pci_write_config_word(pdev, PCI_COMMAND,
						  orig_cmd & ~PCI_COMMAND_MEMORY) != PCIBIOS_SUCCESSFUL ||
			    pci_read_config_word(pdev, PCI_COMMAND, &cmd_chk) != PCIBIOS_SUCCESSFUL ||
			    PCI_POSSIBLE_ERROR(cmd_chk) ||
			    (cmd_chk & PCI_COMMAND_MEMORY)) {
				pci_err(pdev, "shot0: memory decode stop not verified, leaving ReBAR untouched\n");
				shot0_restore_command(pdev, orig_cmd);
				return;
			}
		}

		old_ctrl = ctrl;
		ctrl &= ~PCI_REBAR_CTRL_BAR_SIZE;
		ctrl |= 6u << PCI_REBAR_CTRL_BAR_SHIFT;
		if (pci_write_config_dword(pdev, pos + PCI_REBAR_CTRL, ctrl) != PCIBIOS_SUCCESSFUL) {
			pci_err(pdev, "shot0: ReBAR CTRL write failed (accessor error)\n");
			goto restore_ctrl;
		}

		if (pci_read_config_dword(pdev, pos + PCI_REBAR_CTRL, &verify) != PCIBIOS_SUCCESSFUL ||
		    PCI_POSSIBLE_ERROR(verify)) {
			pci_err(pdev, "shot0: ReBAR readback failed, restoring old value\n");
			goto restore_ctrl;
		}
		new_size = (verify & PCI_REBAR_CTRL_BAR_SIZE) >> PCI_REBAR_CTRL_BAR_SHIFT;
		if (new_size == 6) {
			pci_info(pdev, "shot0: BAR1 size %d -> 6 (64MiB), fixed before first sizing\n",
				 old_size);
			goto restore_cmd;
		}
		pci_err(pdev, "shot0: BAR1 resize did not stick (ctrl=%#010x, size=%d), restoring old value\n",
			verify, new_size);

restore_ctrl:
		/*
		 * 旧値の復元を試み、成否も読み戻しで検証する(未検知にしない)。
		 * 検証はCTRLレジスタ全体の一致(P1第2ラウンド: sizeフィールドだけでは
		 * 他ビットの破損を「restored」と誤判定する)。
		 */
		if (pci_write_config_dword(pdev, pos + PCI_REBAR_CTRL, old_ctrl) == PCIBIOS_SUCCESSFUL &&
		    pci_read_config_dword(pdev, pos + PCI_REBAR_CTRL, &verify) == PCIBIOS_SUCCESSFUL &&
		    verify == old_ctrl)
			pci_warn(pdev, "shot0: old BAR1 ctrl restored (size %d)\n", old_size);
		else
			pci_err(pdev, "shot0: old value restore NOT verified, device state uncertain\n");

restore_cmd:
		if (orig_cmd & PCI_COMMAND_MEMORY)
			shot0_restore_command(pdev, orig_cmd);
		return;
	}

	pci_info(pdev, "shot0: no ReBAR entry for BAR1, leaving BARs untouched\n");
}
DECLARE_PCI_FIXUP_EARLY(PCI_VENDOR_ID_NVIDIA, 0x2204, quirk_shot0_nvidia_bar1_64mib); /* RTX 3090 GA102 */
DECLARE_PCI_FIXUP_EARLY(PCI_VENDOR_ID_NVIDIA, 0x2504, quirk_shot0_nvidia_bar1_64mib); /* RTX 3060 GA106 */
/* SHOT0 END */
