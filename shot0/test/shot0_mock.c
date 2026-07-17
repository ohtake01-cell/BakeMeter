/*
 * shot0 模擬試験(非GPU・サンドボックス実行可)
 * kernel APIをスタブし、src/shot0_quirk.c 本体をそのままコンパイルして
 * config空間の状態機械で動作を検証する。実機・実kernelには一切触れない。
 *
 * 検証項目:
 *  T1: 3060想定(実測cap=0x7fc0)でBAR1 size 8→6、decode復元、書込みは1回
 *  T2: function!=0 は完全不介入
 *  T3: ReBAR capability無しは完全不介入
 *  T4: 64MiB非対応capは完全不介入
 *  T5: 2エントリ(entry0=BAR0, entry1=BAR1)でBAR1のみ書換え、BAR0不介入
 *  T6: 書込み不成立(RO模擬)でerrログ経路+decode復元+実サイズ不変
 *  T7: 既にsize=6なら書込みゼロ
 *  T8: 全ケースでReBAR CTRL書込み時にmemory decodeが落ちていること(write順)
 *
 * ビルド/実行: bash test/run_mock.sh
 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <stdlib.h>

typedef uint32_t u32;
typedef uint16_t u16;
typedef uint8_t u8;

struct pci_dev {
	unsigned int devfn;
	u8 cfg[4096];
	int ext_cap_pos;     /* 0 = capability無し */
	int ro_ctrl_off;     /* このオフセットへのdword書込みを無視(RO模擬)。0=無効 */
};

#define PCI_FUNC(devfn)			((devfn) & 0x07)
#define PCI_COMMAND			0x04
#define PCI_COMMAND_MEMORY		0x2
#define PCI_EXT_CAP_ID_REBAR		0x15
#define PCI_REBAR_CAP			4
#define PCI_REBAR_CTRL			8
#define PCI_REBAR_CTRL_BAR_IDX		0x00000007
#define PCI_REBAR_CTRL_NBAR_MASK	0x000000e0
#define PCI_REBAR_CTRL_NBAR_SHIFT	5
#define PCI_REBAR_CTRL_BAR_SIZE		0x00001f00
#define PCI_REBAR_CTRL_BAR_SHIFT	8
#define PCI_VENDOR_ID_NVIDIA		0x10de

static int g_rebar_writes;          /* ReBAR CTRLへの実書込み回数 */
static int g_decode_ok = 1;         /* 書込み時にdecodeが落ちていたか(T8) */

static int pci_read_config_dword(struct pci_dev *d, int off, u32 *v)
{ memcpy(v, d->cfg + off, 4); return 0; }
static int pci_read_config_word(struct pci_dev *d, int off, u16 *v)
{ memcpy(v, d->cfg + off, 2); return 0; }
static int pci_write_config_word(struct pci_dev *d, int off, u16 v)
{ memcpy(d->cfg + off, &v, 2); return 0; }

static int is_rebar_ctrl_off(struct pci_dev *d, int off)
{
	if (!d->ext_cap_pos)
		return 0;
	return off >= d->ext_cap_pos + PCI_REBAR_CTRL &&
	       (off - d->ext_cap_pos - PCI_REBAR_CTRL) % 8 == 0;
}

static int pci_write_config_dword(struct pci_dev *d, int off, u32 v)
{
	if (is_rebar_ctrl_off(d, off)) {
		u16 cmd;
		memcpy(&cmd, d->cfg + PCI_COMMAND, 2);
		if (cmd & PCI_COMMAND_MEMORY)
			g_decode_ok = 0;
		g_rebar_writes++;
		if (off == d->ro_ctrl_off)
			return 0; /* RO模擬: 書込みを黙って無視 */
	}
	memcpy(d->cfg + off, &v, 4);
	return 0;
}

static int pci_find_ext_capability(struct pci_dev *d, int cap)
{ (void)cap; return d->ext_cap_pos; }

#define pci_info(d, ...) ((void)(d), printf("  info: " __VA_ARGS__))
#define pci_warn(d, ...) ((void)(d), printf("  warn: " __VA_ARGS__))
#define pci_err(d, ...)  ((void)(d), printf("  err:  " __VA_ARGS__))
#define DECLARE_PCI_FIXUP_EARLY(vend, dev, fn) void *shot0_fixup_##dev = (void *)(fn)

#include "../src/shot0_quirk.c"

/* ---- テスト土台 ---- */
#define CAPPOS 0xbb0 /* 実測: 両GPUともReBAR cap@0xbb0 */
static int g_fail;

static void chk(int cond, const char *what)
{
	printf("  %s: %s\n", cond ? "PASS" : "FAIL", what);
	if (!cond)
		g_fail = 1;
}

static void put32(struct pci_dev *d, int off, u32 v) { memcpy(d->cfg + off, &v, 4); }
static u32  get32(struct pci_dev *d, int off) { u32 v; memcpy(&v, d->cfg + off, 4); return v; }
static u16  get16(struct pci_dev *d, int off) { u16 v; memcpy(&v, d->cfg + off, 2); return v; }

/* 単一エントリ(entry0=BAR1)のデバイスを作る。実測3060: cap=0x7fc0 */
static struct pci_dev mkdev(u32 cap, int bar_idx, int size, int nbars, u16 cmd)
{
	struct pci_dev d;
	memset(&d, 0, sizeof(d));
	d.ext_cap_pos = CAPPOS;
	memcpy(d.cfg + PCI_COMMAND, &cmd, 2);
	put32(&d, CAPPOS + PCI_REBAR_CAP, cap);
	put32(&d, CAPPOS + PCI_REBAR_CTRL,
	      (u32)(nbars << PCI_REBAR_CTRL_NBAR_SHIFT) | (u32)bar_idx |
	      (u32)(size << PCI_REBAR_CTRL_BAR_SHIFT));
	return d;
}

static int cur_size(struct pci_dev *d, int entry)
{
	u32 ctrl = get32(d, CAPPOS + PCI_REBAR_CTRL + entry * 8);
	return (ctrl & PCI_REBAR_CTRL_BAR_SIZE) >> PCI_REBAR_CTRL_BAR_SHIFT;
}

static void reset_counters(void) { g_rebar_writes = 0; g_decode_ok = 1; }

int main(void)
{
	struct pci_dev d;

	printf("T1: 3060想定(cap=0x7fc0, BAR1 size8=256MiB, decode ON)\n");
	reset_counters();
	d = mkdev(0x7fc0, 1, 8, 1, 0x0006);
	quirk_shot0_nvidia_bar1_64mib(&d);
	chk(cur_size(&d, 0) == 6, "BAR1 size -> 6 (64MiB)");
	chk(get16(&d, PCI_COMMAND) == 0x0006, "COMMAND復元(decode戻し)");
	chk(g_rebar_writes == 1, "ReBAR書込みは1回のみ");
	chk(g_decode_ok, "T8: 書込み時decode OFF");

	printf("T1b: 3090想定(cap=0xffc0)\n");
	reset_counters();
	d = mkdev(0xffc0, 1, 8, 1, 0x0006);
	quirk_shot0_nvidia_bar1_64mib(&d);
	chk(cur_size(&d, 0) == 6, "BAR1 size -> 6 (64MiB)");
	chk(g_decode_ok, "T8: 書込み時decode OFF");

	printf("T2: function1(HDA想定)は不介入\n");
	reset_counters();
	d = mkdev(0x7fc0, 1, 8, 1, 0x0006);
	d.devfn = 1;
	quirk_shot0_nvidia_bar1_64mib(&d);
	chk(cur_size(&d, 0) == 8 && g_rebar_writes == 0, "無変更・書込みゼロ");

	printf("T3: ReBAR capability無しは不介入\n");
	reset_counters();
	d = mkdev(0x7fc0, 1, 8, 1, 0x0006);
	d.ext_cap_pos = 0;
	quirk_shot0_nvidia_bar1_64mib(&d);
	chk(g_rebar_writes == 0, "書込みゼロ");

	printf("T4: 64MiB非対応cap(bit10=0)は不介入\n");
	reset_counters();
	d = mkdev(0x0003f800 & ~(1u << 10), 1, 8, 1, 0x0006);
	quirk_shot0_nvidia_bar1_64mib(&d);
	chk(cur_size(&d, 0) == 8 && g_rebar_writes == 0, "無変更・書込みゼロ");

	printf("T5: 2エントリ(entry0=BAR0, entry1=BAR1) — BAR1のみ\n");
	reset_counters();
	d = mkdev(0xffff0, 0, 4, 2, 0x0006);            /* entry0 = BAR0 */
	put32(&d, CAPPOS + 8 + PCI_REBAR_CAP, 0x7fc0);   /* entry1 cap */
	put32(&d, CAPPOS + 8 + PCI_REBAR_CTRL,           /* entry1 = BAR1 size8 */
	      (2u << PCI_REBAR_CTRL_NBAR_SHIFT) | 1u | (8u << PCI_REBAR_CTRL_BAR_SHIFT));
	quirk_shot0_nvidia_bar1_64mib(&d);
	chk(cur_size(&d, 0) == 4, "entry0(BAR0)は不介入");
	chk(cur_size(&d, 1) == 6, "entry1(BAR1) size -> 6");
	chk(g_rebar_writes == 1, "書込みは1回のみ");
	chk(g_decode_ok, "T8: 書込み時decode OFF");

	printf("T6: 書込み不成立(RO模擬) — errログ経路とdecode復元\n");
	reset_counters();
	d = mkdev(0x7fc0, 1, 8, 1, 0x0006);
	d.ro_ctrl_off = CAPPOS + PCI_REBAR_CTRL;
	quirk_shot0_nvidia_bar1_64mib(&d);
	chk(cur_size(&d, 0) == 8, "実サイズ不変(RO)");
	chk(get16(&d, PCI_COMMAND) == 0x0006, "COMMAND復元(err経路でも)");

	printf("T7: 既にsize=6なら書込みゼロ\n");
	reset_counters();
	d = mkdev(0x7fc0, 1, 6, 1, 0x0006);
	quirk_shot0_nvidia_bar1_64mib(&d);
	chk(g_rebar_writes == 0, "書込みゼロ");

	printf("\n%s\n", g_fail ? "== 模擬試験 FAILあり ==" : "== 模擬試験 全PASS ==");
	return g_fail;
}
