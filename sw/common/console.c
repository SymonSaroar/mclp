/*
 * The MCLP console, shared by the bare-metal application and mclp on Linux: weighing,
 * calibration, filters, raw capture, faults, AD7190 self-test and the PL loopback BIST.
 *
 * console_run(argc <= 1): interactive console. It checks the register block, loads the calibration,
 * reruns the AD7190 power-up list, then takes commands.
 * console_run(argc > 1): runs argv[1..] as one command and returns. It loads the stored calibration
 * first and stores it again if the command changed it. "init" does the interactive start-up sequence.
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "calib.h"
#include "seq_init.h"
#include "mclp_ops.h"

#define VERSION   "1.1"
#define NOISE_MAX (3.0 * 295.0)        /* nV rms: 3 x the datasheet figure at FS = 1, gain 128 */

static cal_t  cal;
static double baseline[MAX_CH];        /* tap 2 at no load, from cal zero */
static int    have_baseline;
static double pos_r[MAX_CH][MAX_CH];   /* tap 2 minus baseline, test weight at position i */
static int    pos_have[MAX_CH];
static unsigned adc_id[MAX_CH];
static int    failed;                  /* a command reported a failure (exit status in one-shot mode) */
static int    loaded;                  /* cal holds the stored record or the defaults */
static int    oneshot;                 /* one command, then exit: store what it changed */

/* ------------------------------------------------------------------ helpers */

static int spanned(void) { return cal.kg_per_count != 0.0; }

static double net_value(double raw)    /* RESULT to the user's unit: kg once spanned, counts before */
{
	double net = raw - cal.zero - cal.tare;
	return spanned() ? net * cal.kg_per_count : net;
}

static void print_weight(double raw)
{
	printf(spanned() ? "%11.3f kg" : "%11.0f counts", net_value(raw));
}

static double user_to_counts(double v)  /* kg once spanned, counts before */
{
	return spanned() ? v / cal.kg_per_count : v;
}

static const char *unit(void) { return spanned() ? "kg" : "counts"; }

static int nn_present(void) { return reg_rd(REG_NN_STATUS) != READ_BAD; }

static int32_t clamp32(double v)
{
	return v >= 2147483647.0 ? 0x7FFFFFFF : v <= -2147483648.0 ? (int32_t)0x80000000 : (int32_t)lround(v);
}

static void wim_apply(void)
{
	int off = cal.wim_enter == 0x7FFFFFFF;
	reg_wr(REG_WIM_ENTER, (uint32_t)(off ? 0x7FFFFFFF : clamp32(cal.zero + cal.wim_enter)));
	reg_wr(REG_WIM_EXIT, (uint32_t)(off ? 0x7FFFFFFF : clamp32(cal.zero + cal.wim_exit)));
	reg_wr(REG_WIM_LEVEL, cal.wim_level);
}

static int fir_apply(double fc)
{
	int32_t taps[FIR_TAPS];
	if (fir_lowpass(fc, CIC_RATE_HZ, taps)) {
		printf("cutoff %.2f Hz is out of range: 0.5 to 37 Hz (18-bit taps, DC gain 2^20)\n", fc);
		return -1;
	}
	if (fir_load(taps)) {
		printf("FIR reload did not finish\n");
		return -1;
	}
	return 0;
}

static void cal_apply(void)
{
	step("calibration: offsets, gains and trims into the coefficient RAMs; stability, WIM, decimation, FIR");
	for (int ch = 0; ch < n_ch; ch++) {
		reg_wr(REG_OFFSET(ch), (uint32_t)cal.offset[ch]);
		reg_wr(REG_GAIN(ch), cal.gain[ch]);
		reg_wr(REG_TRIM(ch), cal.trim[ch]);
	}
	reg_wr(REG_STAB_BAND, (uint32_t)cal.stab_band);
	reg_wr(REG_STAB_COUNT, cal.stab_count);
	reg_wr(REG_RESULT_DECIM, cal.decim);
	wim_apply();
	fir_apply(cal.fir_fc);
	if (nn_present())
		reg_wr(REG_NN_CTRL, cal.nn_enable);
}

static void cal_load_or_defaults(int verbose)
{
	cal_t tmp;
	int e = hw->fetch(&tmp, sizeof tmp);
	loaded = 1;
	if (!e && cal_valid(&tmp) && tmp.n_ch == (uint32_t)n_ch) {
		cal = tmp;
		if (verbose)
			printf("calibration loaded from %s\n", hw->store_name);
	} else {
		cal_defaults(&cal, n_ch);
		if (verbose && !e && cal_valid(&tmp))
			printf("calibration in %s is for %u channels, the bitstream has %d; defaults in use\n",
			       hw->store_name, (unsigned)tmp.n_ch, n_ch);
		else if (verbose)
			printf("no calibration in %s (%d); defaults in use. Calibrate with cal zero, cal corner,\n"
			       "cal solve, then cal save.\n", hw->store_name, e);
	}
}

static const char *flag_names(uint32_t f, char *s)
{
	s[0] = 0;
	if (f & FLT_ERR)      strcat(s, "ERR ");
	if (f & FLT_NOREF)    strcat(s, "NOREF ");
	if (f & FLT_PARITY)   strcat(s, "PARITY ");
	if (f & FLT_STALE)    strcat(s, "STALE ");
	if (f & FLT_MISMATCH) strcat(s, "MISMATCH ");
	if (!s[0])            strcat(s, "-");
	return s;
}

static int faults_any(void)
{
	int n = 0;
	for (int ch = 0; ch < n_ch; ch++)
		n += reg_rd(REG_FAULT(ch)) != 0;
	return n;
}

static int adc_init(void)
{
	int ok = 0;
	if (seq_default()) {
		printf("ADC init list did not reach STREAM within 200 ms (sequencer still busy)\n");
		failed = 1;
		return -1;
	}
	step("ADC init: read the ID answers from SEQ_RESP");
	printf("ADC IDs:");
	for (int ch = 0; ch < n_ch; ch++) {
		adc_id[ch] = reg_rd(REG_SEQ_RESP(ch)) & 0xFFu;
		ok += (adc_id[ch] & 0x0Fu) == 4u;
		printf(" %02X", adc_id[ch]);
	}
	printf("  (%d of %d answer as AD7190)\n", ok, n_ch);
	delay_ms(5);
	fault_clear();
	return ok;
}

static int platform_check(void)
{
	step("start-up: ID register and MMCM lock");
	uint32_t id;
	if (id_check(&id)) {
		printf("ID register reads %08X, expected %08Xnn (nn = 01 to 40 channels): wrong bitstream or no\n"
		       "register block\n", (unsigned)id, FPGA_ID_MAP >> 8);
		failed = 1;
		return -1;
	}
	uint32_t t0 = ms_now();
	while (!(reg_rd(REG_STATUS) & ST_LOCKED)) {
		if (ms_now() - t0 > 100) {
			printf("MMCM not locked after 100 ms\n");
			break;
		}
		delay_ms(1);
	}
	step("start-up: clear interrupt events left over from power-up");
	reg_wr(REG_IRQ_STATUS, 0xFFu);
	return 0;
}

static void print_wim(void)
{
	uint64_t sum = ((uint64_t)reg_rd(REG_WIM_SUM_HI) << 32) | reg_rd(REG_WIM_SUM_LO);
	uint32_t n = reg_rd(REG_WIM_COUNT);
	if (!n) {
		printf("no weigh-in-motion result yet\n");
		return;
	}
	printf("weigh-in-motion:");
	print_weight((double)(int64_t)sum / n);
	printf(" from %u samples (%.2f s of plateau)\n", (unsigned)n, n / CIC_RATE_HZ);
}

/* ------------------------------------------------------------------ inference engine */

static const struct { const char *name; unsigned base, words, off; } NN_MEM[] = {   /* off: into nn_all */
	{ "layers", REG_NN_LAYER(0), 64, 0 }, { "bias", REG_NN_BIAS(0), 256, 64 },
	{ "weights", REG_NN_WEIGHT(0), 4096, 320 },
};
static char     nn_text[45000];        /* one .mem file: up to 4096 lines of 8 hex digits */
static uint32_t nn_all[64 + 256 + 4096];

static uint32_t crc32_word(uint32_t crc, uint32_t w)
{
	for (int i = 0; i < 4; i++) {
		crc ^= (w >> (8 * i)) & 0xFFu;
		for (int b = 0; b < 8; b++)
			crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
	}
	return crc;
}

/* CRC-32 of the three model memories as read back, and the number of layers up to the one marked last
 * (0 if none is) */
static uint32_t nn_crc(int *layers)
{
	uint32_t crc = 0xFFFFFFFFu;
	int t = trace, done = 0;
	step("nn: read back the layer list, biases and weights");
	trace = 0;
	*layers = 0;
	for (unsigned m = 0; m < 3; m++)
		for (unsigned i = 0; i < NN_MEM[m].words; i++) {
			uint32_t w = reg_rd(NN_MEM[m].base + 4u * i);
			crc = crc32_word(crc, w);
			if (m == 0 && i % 4u == 0u && !done) {
				++*layers;
				done = (w >> 31) != 0;
			}
		}
	trace = t;
	if (!done)
		*layers = 0;
	return ~crc;
}

/* <prefix>_<name>.mem: hex words, one per line as $readmemh reads them. Word count, or -1. */
static int nn_read_mem(const char *prefix, unsigned m, uint32_t *out)
{
	char path[200], *s = nn_text, *e;
	snprintf(path, sizeof path, "%s_%s.mem", prefix, NN_MEM[m].name);
	int n = hw->read_file(path, nn_text, sizeof nn_text - 1);
	if (n < 0) {
		printf("cannot read %s\n", path);
		return -1;
	}
	nn_text[n] = 0;
	unsigned k = 0;
	for (;;) {
		while (*s == ' ' || *s == '\t' || *s == '\r' || *s == '\n')
			s++;
		if (!*s)
			return (int)k;
		unsigned long v = strtoul(s, &e, 16);
		if (e == s || v > 0xFFFFFFFFul) {
			printf("%s: word %u is not a 32-bit hex number\n", path, k);
			return -1;
		}
		if (k == NN_MEM[m].words) {
			printf("%s: more than %u words\n", path, NN_MEM[m].words);
			return -1;
		}
		out[k++] = (uint32_t)v;
		s = e;
	}
}

/* Reads all three files, then writes them with the engine stopped and reads them back. 0, or -1. */
static int nn_load(const char *prefix)
{
	int bad = 0;
	if (!hw->read_file) {
		printf("this backend cannot read files\n");
		return -1;
	}
	for (unsigned m = 0; m < 3; m++) {
		int n = nn_read_mem(prefix, m, nn_all + NN_MEM[m].off);
		if (n < 0)
			return -1;
		memset(nn_all + NN_MEM[m].off + n, 0, (NN_MEM[m].words - (unsigned)n) * sizeof nn_all[0]);
	}
	uint32_t en = reg_rd(REG_NN_CTRL) & 1u;
	step("nn load: stop the engine, write the layer list, biases and weights, read them back");
	reg_wr(REG_NN_CTRL, 0);
	uint32_t t0 = ms_now();
	while ((reg_rd(REG_NN_STATUS) & 1u) && ms_now() - t0 < 10)
		delay_ms(1);
	int t = trace;
	trace = 0;
	for (unsigned m = 0; m < 3; m++)
		for (unsigned i = 0; i < NN_MEM[m].words; i++)
			reg_wr(NN_MEM[m].base + 4u * i, nn_all[NN_MEM[m].off + i]);
	for (unsigned m = 0; m < 3; m++)
		for (unsigned i = 0; i < NN_MEM[m].words; i++)
			bad += reg_rd(NN_MEM[m].base + 4u * i) != nn_all[NN_MEM[m].off + i];
	trace = t;
	reg_wr(REG_NN_CTRL, en);
	if (bad) {
		printf("%d model words read back wrong\n", bad);
		return -1;
	}
	return 0;
}

static void print_nn(void)
{
	uint32_t seq = reg_rd(REG_NN_SEQ);
	if (!seq || seq == READ_BAD) {
		printf("no inference result yet\n");
		return;
	}
	int32_t  est = (int32_t)reg_rd(REG_NN_EST), corr = (int32_t)reg_rd(REG_NN_CORR);
	uint32_t cycles = reg_rd(REG_NN_CYCLES);         /* all reads first: trace lines stay off the result line */
	printf("inference %u:", (unsigned)seq);
	print_weight(est);
	printf(", correction %+.2f%% of the weigh-in-motion result, %.0f us\n", corr / 1048576.0 * 100.0,
	       cycles / DSP_CLK_MHZ);
}

/* ------------------------------------------------------------------ commands */

static void cmd_help(int argc, char **argv);

static void cmd_status(int argc, char **argv)
{
	(void)argc; (void)argv;
	uint32_t st = reg_rd(REG_STATUS);
	printf("FPGA ID %08X, MMCM %s, sequencer %s, FIR reload %s\n", (unsigned)reg_rd(REG_ID),
	       st & ST_LOCKED ? "locked" : "NOT LOCKED", st & ST_SEQ_BUSY ? "busy" : "streaming",
	       st & ST_RELOAD_BUSY ? "busy" : "idle");
	printf("weight:");
	print_weight((int32_t)reg_rd(REG_RESULT));
	printf("  %s%s, %d channel(s) with faults\n", st & ST_STABLE ? "stable" : "in motion",
	       st & ST_OVERLOAD ? ", OVERLOAD" : "", faults_any());
	printf("calibration: zero %.0f, tare %.0f, %s", cal.zero, cal.tare, spanned() ? "" : "not spanned\n");
	if (spanned())
		printf("%.6g kg per count\n", cal.kg_per_count);
	printf("filter: FIR %.2f Hz, result %.1f Hz (decim %u), stability %d counts over %u samples\n", cal.fir_fc,
	       CIC_RATE_HZ / cal.decim, (unsigned)cal.decim, (int)cal.stab_band, (unsigned)cal.stab_count);
	printf("raw capture DMA status %08X\n", (unsigned)dma_status());
}

static void cmd_info(int argc, char **argv)
{
	(void)argc; (void)argv;
	printf("mclp console %s, backend %s\n", VERSION, hw->name);
	printf("registers 0x%08X, DMA 0x%08X, capture ring 0x%08X (%u KB, %d records max)\n", MCLP_BASE, DMA_BASE,
	       (unsigned)hw->ring_phys, (unsigned)(hw->ring_bytes / 1024u), capture_max());
	printf("calibration store: %s\n", hw->store_name);
}

static void cmd_weight(int argc, char **argv)
{
	(void)argc; (void)argv;
	double r;
	if (result_mean(1, &r)) {
		printf("no RESULT update within 0.5 s\n");
		failed = 1;
		return;
	}
	uint32_t st = reg_rd(REG_STATUS);
	print_weight(r);
	printf("  %s%s\n", st & ST_STABLE ? "stable" : "in motion", st & ST_OVERLOAD ? "  OVERLOAD" : "");
}

static void cmd_live(int argc, char **argv)
{
	(void)argc; (void)argv;
	uint32_t seq = reg_rd(REG_RESULT_SEQ), t_print = 0;
	printf("live weight at 10 Hz; any key stops\n");
	reg_wr(REG_IRQ_STATUS, IRQ_WIM | IRQ_FAULT | IRQ_NN_DONE);
	while (!key_pressed()) {
		uint32_t irq = reg_rd(REG_IRQ_STATUS);
		if (irq & IRQ_WIM) {
			reg_wr(REG_IRQ_STATUS, IRQ_WIM);
			printf("\n");
			print_wim();
		}
		if (irq & IRQ_NN_DONE) {
			reg_wr(REG_IRQ_STATUS, IRQ_NN_DONE);
			print_nn();
		}
		if (irq & IRQ_FAULT) {
			reg_wr(REG_IRQ_STATUS, IRQ_FAULT);
			printf("\nnew fault flag; see \"faults\"\n");
		}
		if (ms_now() - t_print >= 100 && reg_rd(REG_RESULT_SEQ) != seq) {
			uint32_t st = reg_rd(REG_STATUS);
			seq = reg_rd(REG_RESULT_SEQ);
			t_print = ms_now();
			printf("\r");
			print_weight((int32_t)reg_rd(REG_RESULT));
			printf("  %-9s %-8s", st & ST_STABLE ? "stable" : "motion", st & ST_OVERLOAD ? "OVERLOAD" : "");
			fflush(stdout);
		}
		delay_ms(20);
	}
	key_get();
	printf("\n");
}

static void cmd_tare(int argc, char **argv)
{
	double r;
	if (argc > 1 && !strcmp(argv[1], "clear")) {
		cal.tare = 0.0;
		printf("tare cleared\n");
		return;
	}
	if (result_mean(25, &r)) {
		printf("no RESULT updates\n");
		failed = 1;
		return;
	}
	cal.tare = r - cal.zero;
	printf("tare %.0f counts", cal.tare);
	if (spanned())
		printf(" (%.3f kg)", cal.tare * cal.kg_per_count);
	printf("\n");
}

static void cmd_zero(int argc, char **argv)
{
	(void)argc; (void)argv;
	double r;
	if (result_mean(25, &r)) {
		printf("no RESULT updates\n");
		failed = 1;
		return;
	}
	cal.zero = r;
	cal.tare = 0.0;
	wim_apply();
	printf("zero set at %.0f counts\n", r);
}

static void cal_show(void)
{
	printf("ch    offset    gain     trim   corner responses (tap 2, no-load baseline removed)\n");
	for (int ch = 0; ch < n_ch; ch++) {
		printf("%2d %9d %7.4f %8.5f ", ch, (int)cal.offset[ch], from_q30(cal.gain[ch]), from_q30(cal.trim[ch]));
		for (int i = 0; i < n_ch; i++)
			if (pos_have[i])
				printf(" %9.0f", pos_r[i][ch]);
		printf("\n");
	}
	printf("zero %.0f counts, span %s", cal.zero, spanned() ? "" : "not set\n");
	if (spanned())
		printf("%.6g kg per count\n", cal.kg_per_count);
}

static void cal_zero(void)
{
	double m[MAX_CH], r;
	step("cal zero: 1 s of per-channel data after the CIC (tap 1)");
	printf("no load on the platform; measuring 1 s of per-channel data...\n");
	int e = capture_mean(1, 600, m);
	if (e) {
		printf("raw capture failed (%d, DMA status %08X)\n", e, (unsigned)dma_status());
		failed = 1;
		return;
	}
	step("cal zero: channel means become the offsets");
	for (int ch = 0; ch < n_ch; ch++) {
		cal.offset[ch] = clamp32(m[ch]);
		reg_wr(REG_OFFSET(ch), (uint32_t)cal.offset[ch]);
	}
	step("cal zero: no-load baseline after gain/offset (tap 2) and the RESULT zero point");
	if (capture_mean(2, 600, baseline) || result_mean(25, &r)) {
		printf("measurement after the offsets failed\n");
		failed = 1;
		return;
	}
	have_baseline = 1;
	memset(pos_have, 0, sizeof pos_have);
	cal.zero = r;
	cal.tare = 0.0;
	wim_apply();
	cal_show();
}

static void cal_corner(int i)
{
	double m[MAX_CH], tot = 0.0;
	if (!have_baseline) {
		printf("run \"cal zero\" first (in the same interactive session)\n");
		failed = 1;
		return;
	}
	if (i < 0 || i >= n_ch) {
		printf("position 0 to %d\n", n_ch - 1);
		failed = 1;
		return;
	}
	step("cal corner %d: 1 s of per-channel data after gain/offset (tap 2)", i);
	printf("position %d: measuring 1 s...\n", i);
	if (capture_mean(2, 600, m)) {
		printf("raw capture failed\n");
		failed = 1;
		return;
	}
	for (int ch = 0; ch < n_ch; ch++) {
		pos_r[i][ch] = m[ch] - baseline[ch];
		tot += pos_r[i][ch];
	}
	pos_have[i] = 1;
	printf("share per channel:");
	for (int ch = 0; ch < n_ch; ch++)
		printf(" %5.1f%%", tot != 0.0 ? 100.0 * pos_r[i][ch] / tot : 0.0);
	printf("\n");
}

static void cal_solve(double kg)
{
	static double r[MAX_CH][MAX_CH];           /* 32 KB: off the stack */
	double t[MAX_CH], z = 0.0;
	int m = 0, warn = 0;
	for (int i = 0; i < n_ch; i++)
		if (pos_have[i])
			memcpy(r[m++], pos_r[i], sizeof r[0]);
	if (m == 0 || kg <= 0.0) {
		printf("usage: cal corner <i> for each position, then cal solve <test weight in kg>\n");
		failed = 1;
		return;
	}
	double s = solve_trims(m, n_ch, r, t);
	if (s <= 0.0) {
		printf("the recorded positions do not determine the trims; check the test weight placement\n");
		failed = 1;
		return;
	}
	for (int ch = 0; ch < n_ch; ch++) {
		if (t[ch] <= 0.0 || t[ch] >= 2.0) {
			printf("trim %d = %.4f is outside (0, 2): check the wiring of load cell %d\n", ch, t[ch], ch);
			failed = 1;
			return;
		}
		warn |= t[ch] < 0.8 || t[ch] > 1.2;
	}
	step("cal solve: corner trims into the trim RAM");
	for (int ch = 0; ch < n_ch; ch++) {
		cal.trim[ch] = q30(t[ch]);
		reg_wr(REG_TRIM(ch), cal.trim[ch]);
		z += t[ch] * baseline[ch];
	}
	cal.kg_per_count = kg / s;
	cal.zero = z;
	cal.tare = 0.0;
	wim_apply();
	printf("trims from %d position(s):", m);
	for (int ch = 0; ch < n_ch; ch++)
		printf(" %.4f", t[ch]);
	printf("\nspan %.6g kg per count%s\n", cal.kg_per_count,
	       warn ? "; a trim is more than 20 % from 1, check the cells" : "");
}

static void cal_span(double kg)
{
	double r;
	if (kg <= 0.0) {
		printf("usage: cal span <known weight in kg>\n");
		failed = 1;
		return;
	}
	if (result_mean(50, &r)) {
		printf("no RESULT updates\n");
		failed = 1;
		return;
	}
	double d = r - cal.zero;
	if (fabs(d) < 1000.0) {
		printf("reading moved only %.0f counts from zero: is the weight on the platform?\n", d);
		failed = 1;
		return;
	}
	cal.kg_per_count = kg / d;
	printf("span %.6g kg per count\n", cal.kg_per_count);
}

static void cmd_cal(int argc, char **argv)
{
	const char *sub = argc > 1 ? argv[1] : "show";
	double arg = argc > 2 ? atof(argv[2]) : 0.0;
	cal_t tmp;

	if (!strcmp(sub, "show")) {
		cal_show();
	} else if (!strcmp(sub, "zero")) {
		cal_zero();
	} else if (!strcmp(sub, "corner") && argc > 2) {
		cal_corner(atoi(argv[2]));
	} else if (!strcmp(sub, "solve")) {
		cal_solve(arg);
	} else if (!strcmp(sub, "span")) {
		cal_span(arg);
	} else if (!strcmp(sub, "reset")) {
		cal_defaults(&cal, n_ch);
		cal.tare = 0.0;
		have_baseline = 0;
		memset(pos_have, 0, sizeof pos_have);
		cal_apply();
		printf("calibration reset: offsets 0, gains 1, trims 1, no span\n");
	} else if (!strcmp(sub, "save")) {
		cal.sum = cal_checksum(&cal);
		int e = hw->store(&cal, sizeof cal);
		if (e)
			failed = 1;
		printf(e ? "save to %s failed (%d)\n" : "saved to %s\n", hw->store_name, e);
	} else if (!strcmp(sub, "load")) {
		int e = hw->fetch(&tmp, sizeof tmp);
		if (e || !cal_valid(&tmp)) {
			printf("no valid calibration in %s (%d)\n", hw->store_name, e);
			failed = 1;
			return;
		}
		cal = tmp;
		cal_apply();
		printf("loaded %s\n", hw->store_name);
	} else {
		printf("cal [show | zero | corner <i> | solve <kg> | span <kg> | reset | save | load]\n");
	}
}

static void cmd_stab(int argc, char **argv)
{
	if (argc > 2) {
		cal.stab_band  = clamp32(user_to_counts(atof(argv[1])));
		cal.stab_count = (uint32_t)atoi(argv[2]);
		reg_wr(REG_STAB_BAND, (uint32_t)cal.stab_band);
		reg_wr(REG_STAB_COUNT, cal.stab_count);
	}
	printf("stable when within %d counts", (int)cal.stab_band);
	if (spanned())
		printf(" (%.4g kg)", cal.stab_band * cal.kg_per_count);
	printf(" of the reference for %u samples (%.2f s)\n", (unsigned)cal.stab_count, cal.stab_count / CIC_RATE_HZ);
}

static void cmd_wim(int argc, char **argv)
{
	if (argc > 1 && !strcmp(argv[1], "off")) {
		cal.wim_enter = cal.wim_exit = 0x7FFFFFFF;
		wim_apply();
	} else if (argc > 3) {
		cal.wim_enter  = clamp32(user_to_counts(atof(argv[1])));
		cal.wim_exit   = clamp32(user_to_counts(atof(argv[2])));
		double lv      = atof(argv[3]);
		cal.wim_level  = lv <= 0.0 ? 0u : lv >= 1.0 ? 0xFFFFu : (uint32_t)lround(lv * 65536.0);
		wim_apply();
	}
	if (cal.wim_enter == 0x7FFFFFFF)
		printf("weigh-in-motion off (wim <enter> <exit> <level>, in %s above zero, level 0 to 1)\n", unit());
	else
		printf("weigh-in-motion: enter above %.4g %s, exit below %.4g %s, level %.3f of the peak\n",
		       spanned() ? cal.wim_enter * cal.kg_per_count : cal.wim_enter, unit(),
		       spanned() ? cal.wim_exit * cal.kg_per_count : cal.wim_exit, unit(), cal.wim_level / 65536.0);
	print_wim();
	if (nn_present())
		print_nn();
}

static void cmd_nn(int argc, char **argv)
{
	if (!nn_present()) {
		printf("no inference engine in this bitstream (USE_NN = 0)\n");
		failed = 1;
		return;
	}
	if (argc == 2 && (!strcmp(argv[1], "on") || !strcmp(argv[1], "off"))) {
		cal.nn_enable = !strcmp(argv[1], "on");
		reg_wr(REG_NN_CTRL, cal.nn_enable);
	} else if (argc >= 2 && argc <= 3 && !strcmp(argv[1], "load")) {
		const char *p = argc == 3 ? argv[2] : hw->nn_model;
		if (!p || nn_load(p)) {
			failed = 1;
			return;
		}
		printf("model loaded from %s_layers.mem, _bias.mem, _weights.mem\n", p);
	} else if (argc > 1) {
		printf("usage: nn [on | off | load [prefix]]\n");
		failed = 1;
		return;
	}
	int layers;
	uint32_t crc = nn_crc(&layers);
	printf("inference engine %s%s; model: %d layer%s, CRC-32 %08X\n", reg_rd(REG_NN_CTRL) & 1u ? "on" : "off",
	       reg_rd(REG_NN_STATUS) & 1u ? ", busy" : "", layers, layers == 1 ? "" : "s", (unsigned)crc);
	print_nn();
}

static void cmd_decim(int argc, char **argv)
{
	if (argc > 1) {
		int n = atoi(argv[1]);
		if (n < 1 || n > 65535) {
			printf("decim 1 to 65535\n");
			failed = 1;
			return;
		}
		cal.decim = (uint32_t)n;
		reg_wr(REG_RESULT_DECIM, cal.decim);
	}
	printf("RESULT every %u FIR outputs: %.2f Hz\n", (unsigned)cal.decim, CIC_RATE_HZ / cal.decim);
}

static void cmd_fir(int argc, char **argv)
{
	if (argc > 1) {
		double fc = atof(argv[1]);
		if (fir_apply(fc)) {
			failed = 1;
			return;
		}
		cal.fir_fc = fc;
	}
	printf("FIR: 64-tap Hamming low-pass, cutoff %.2f Hz at %.0f Hz (fir <hz> to change, 0.5 to 37)\n",
	       cal.fir_fc, CIC_RATE_HZ);
}

static void cmd_raw(int argc, char **argv)
{
	record_t r;
	int tap = argc > 1 ? atoi(argv[1]) : -1, n = argc > 2 ? atoi(argv[2]) : 10;
	if (tap < 0 || tap > 3 || n < 1 || n > capture_max()) {
		printf("raw <tap 0 AFE | 1 CIC | 2 gain | 3 trim> <records, up to %d>\n", capture_max());
		failed = 1;
		return;
	}
	int got = capture((unsigned)tap, n, 2000u + 2u * (unsigned)n);
	printf("record,ts,faults");
	for (int ch = 0; ch < n_ch; ch++)
		printf(",s%d", ch);
	printf("\n");
	for (int i = 0; i < got; i++) {
		record_get(i, &r);
		printf("%d,%llu,%llX", i, (unsigned long long)r.ts, (unsigned long long)r.faults);
		for (int ch = 0; ch < n_ch; ch++)
			printf(",%ld", (long)r.s[ch]);
		printf("\n");
	}
	if (got < n) {
		printf("only %d of %d records (DMA status %08X)\n", got, n, (unsigned)dma_status());
		failed = 1;
	}
}

static void cmd_faults(int argc, char **argv)
{
	char s[48];
	if (argc > 1 && !strcmp(argv[1], "clear")) {
		fault_clear();
		delay_ms(2);
	}
	for (int ch = 0; ch < n_ch; ch++)
		printf("ch%d: %s\n", ch, flag_names(reg_rd(REG_FAULT(ch)), s));
}

static void selftest_prog(uint32_t p[10], uint32_t config)
{
	p[0] = SEQ_CMD(SEQ_WAIT_RDY, 0, 0, 0);  p[1] = 0;
	p[2] = SEQ_CMD(SEQ_XFER, 8, 32, 0);     p[3] = AD_EXIT_CREAD;
	p[4] = SEQ_CMD(SEQ_XFER, 32, 0, 0);     p[5] = AD_WR_CONFIG | config;
	p[6] = SEQ_CMD(SEQ_XFER, 8, 0, 0);      p[7] = AD_ENTER_CREAD;
	p[8] = SEQ_CMD(SEQ_STREAM, 0, 0, 0);    p[9] = 0;
}

static void cmd_selftest(int argc, char **argv)
{
	(void)argc; (void)argv;
	uint32_t prog[10], flt[MAX_CH];
	double sum[MAX_CH] = {0}, sq[MAX_CH] = {0};
	int32_t lo[MAX_CH], hi[MAX_CH];
	record_t r;
	const int n = 480;                  /* 0.1 s at 4800 SPS */
	int bad = 0;

	printf("AD7190 self-test: burnout currents (open wire), reference detect, internal short noise\n");
	step("self-test 1/2: exit continuous read, configuration with BURN (burnout currents), stream");
	selftest_prog(prog, AD7190_CONFIG | AD_CFG_BURN);
	if (seq_run(prog, 10, 200)) {
		printf("sequencer stuck (no RDY on lane 0?)\n");
		bad = 1;
		goto restore;
	}
	delay_ms(20);
	fault_clear();
	delay_ms(20);
	step("self-test 1/2: read the fault flags (ERR = open input, NOREF = missing reference)");
	for (int ch = 0; ch < n_ch; ch++)
		flt[ch] = reg_rd(REG_FAULT(ch));

	step("self-test 2/2: configuration with channel AIN2-AIN2 (internal short), stream");
	selftest_prog(prog, (AD7190_CONFIG & ~0xFF00u) | AD_CFG_SHORT);
	if (seq_run(prog, 10, 200)) {
		printf("sequencer stuck\n");
		bad = 1;
		goto restore;
	}
	delay_ms(10);
	if (capture(0, n, 1000) < n) {
		printf("raw capture failed (DMA status %08X)\n", (unsigned)dma_status());
		bad = 1;
		goto restore;
	}
	for (int ch = 0; ch < n_ch; ch++) {
		lo[ch] = 0x7FFFFFFF;
		hi[ch] = (int32_t)0x80000000;
	}
	for (int i = 0; i < n; i++) {
		record_get(i, &r);
		for (int ch = 0; ch < n_ch; ch++) {
			sum[ch] += r.s[ch];
			sq[ch]  += (double)r.s[ch] * r.s[ch];
			if (r.s[ch] < lo[ch]) lo[ch] = r.s[ch];
			if (r.s[ch] > hi[ch]) hi[ch] = r.s[ch];
		}
	}
	printf("ch  open wire  reference  short offset  noise rms     p-p     result\n");
	for (int ch = 0; ch < n_ch; ch++) {
		double mean = sum[ch] / n, rms = sqrt(fmax(sq[ch] / n - mean * mean, 0.0)) * AD_LSB_NV;
		int ok = !(flt[ch] & (FLT_ERR | FLT_NOREF)) && rms < NOISE_MAX;
		bad |= !ok;
		printf("%2d  %-9s  %-9s  %8.0f LSB  %6.0f nV  %6.0f nV  %s\n", ch, flt[ch] & FLT_ERR ? "OPEN" : "ok",
		       flt[ch] & FLT_NOREF ? "MISSING" : "ok", mean, rms, (hi[ch] - lo[ch]) * AD_LSB_NV,
		       ok ? "PASS" : "FAIL");
	}
restore:
	failed |= bad;
	printf("restoring the ADC configuration\n");
	adc_init();
}

static void cmd_bist(int argc, char **argv)
{
	(void)argc; (void)argv;
	const uint32_t stream[2] = { SEQ_CMD(SEQ_STREAM, 0, 0, 0), 0 };
	const uint32_t cfg = LB_PERIOD(LB_PERIOD_4800), value = 0x123456u;
	record_t r;
	int bad = 0;

	printf("loopback BIST: AD7190 emulator in the PL replaces the %d DOUT pins\n", n_ch);
	step("BIST: emulator pattern (constant 0x123456 + lane << 16, 4800 frames/s), CTRL.loopback on");
	reg_wr(REG_LB_CFG, cfg);
	reg_wr(REG_LB_VALUE, value);
	ctrl_set(CTRL_LOOPBACK, 0);
	step("BIST: STREAM-only program, so the sequencer reads the emulator's frames");
	if (seq_run(stream, 2, 100)) {
		printf("sequencer stuck\n");
		bad++;
		goto restore;
	}
	delay_ms(5);
	fault_clear();
	delay_ms(5);
	step("BIST check 1: no fault flags with clean emulator data");
	for (int ch = 0; ch < n_ch; ch++)
		if (reg_rd(REG_FAULT(ch))) {
			printf("ch%d: fault %02X with clean emulator data\n", ch, (unsigned)reg_rd(REG_FAULT(ch)));
			bad++;
		}

	step("BIST check 2: 48 raw records at tap 0 must carry the emulator's words bit for bit");
	if (capture(0, 48, 500) < 48) {
		printf("raw capture failed (DMA status %08X)\n", (unsigned)dma_status());
		bad++;
	} else {
		for (int i = 0; i < 48; i++) {
			record_get(i, &r);
			for (int ch = 0; ch < n_ch; ch++) {
				int32_t want = (int32_t)(((value + ((uint32_t)ch << 16)) & 0xFFFFFFu) << 8) >> 8;
				if (r.s[ch] != want && bad < 10) {
					printf("record %d ch%d: %ld, expected %ld\n", i, ch, (long)r.s[ch], (long)want);
					bad++;
				}
			}
		}
	}

	for (int ch = 0; ch < n_ch; ch++) {             /* every channel's ERR path, then one parity error */
		step("BIST check 3: inject ERR on channel %d, only FAULT[%d].ERR may set", ch, ch);
		fault_clear();
		reg_wr(REG_LB_CFG, cfg | LB_INJECT_ERR | LB_CH(ch));
		delay_ms(3);
		for (int k = 0; k < n_ch; k++) {
			uint32_t f = reg_rd(REG_FAULT(k)), want = k == ch ? FLT_ERR : 0u;
			if ((f & FLT_ERR) != want) {
				printf("ERR injected on ch%d: ch%d fault %02X\n", ch, k, (unsigned)f);
				bad++;
			}
		}
		reg_wr(REG_LB_CFG, cfg);
		delay_ms(2);
	}
	int pc = n_ch > 5 ? 5 : n_ch - 1;
	step("BIST check 4: inject a parity error on channel %d", pc);
	fault_clear();
	reg_wr(REG_LB_CFG, cfg | LB_INJECT_PARITY | LB_CH(pc));
	delay_ms(3);
	if (!(reg_rd(REG_FAULT(pc)) & FLT_PARITY)) {
		printf("parity error injected on ch%d not flagged\n", pc);
		bad++;
	}
	reg_wr(REG_LB_CFG, cfg);
restore:
	step("BIST: CTRL.loopback off, rerun the ADC init list");
	ctrl_set(0, CTRL_LOOPBACK);
	delay_ms(2);
	failed |= bad != 0;
	if (bad)
		printf("BIST FAILED\n");
	else
		printf("BIST PASSED: data path bit-exact, fault flags on all %d channels\n", n_ch);
	adc_init();
}

static void cmd_adc(int argc, char **argv)
{
	(void)argc; (void)argv;
	adc_init();
}

static void cmd_init(int argc, char **argv)
{
	(void)argc; (void)argv;
	if (platform_check())
		return;
	cal_load_or_defaults(1);
	if (nn_present() && hw->read_file && hw->nn_model) {
		char path[200];
		snprintf(path, sizeof path, "%s_layers.mem", hw->nn_model);
		if (hw->read_file(path, nn_text, sizeof nn_text - 1) >= 0 && !nn_load(hw->nn_model))
			printf("inference model loaded from %s_*.mem\n", hw->nn_model);
	}
	cal_apply();
	adc_init();
}

static void cmd_trace(int argc, char **argv)
{
	if (argc > 1)
		trace = !strcmp(argv[1], "on");
	printf("trace %s\n", trace ? "on" : "off");
}

static void cmd_rd(int argc, char **argv)
{
	if (argc < 2) {
		printf("rd <offset from 0x%08X, or absolute address>\n", MCLP_BASE);
		return;
	}
	uint32_t a = (uint32_t)strtoul(argv[1], NULL, 0);
	uint32_t v = a < 0x10000u ? reg_rd(a) : mem_rd(a);
	printf("%08X: %08X (%ld)\n", (unsigned)(a < 0x10000u ? MCLP_BASE + a : a), (unsigned)v, (long)(int32_t)v);
}

static void cmd_wr(int argc, char **argv)
{
	if (argc < 3) {
		printf("wr <offset or address> <value>\n");
		return;
	}
	uint32_t a = (uint32_t)strtoul(argv[1], NULL, 0), v = (uint32_t)strtoul(argv[2], NULL, 0);
	if (a < 0x10000u)
		reg_wr(a, v);
	else
		mem_wr(a, v);
}

static const struct {
	const char *name, *args, *help;
	void (*fn)(int, char **);
} cmds[] = {
	{ "help",     "",                        "this list", cmd_help },
	{ "status",   "",                        "clocks, sequencer, weight, faults, calibration, filters", cmd_status },
	{ "info",     "",                        "backend, addresses, capture ring, calibration store", cmd_info },
	{ "w",        "",                        "one weight reading", cmd_weight },
	{ "live",     "",                        "live weight with motion and WIM events; any key stops", cmd_live },
	{ "tare",     "[clear]",                 "tare at the current reading, or clear it", cmd_tare },
	{ "zero",     "",                        "set the zero point at the current reading (no load)", cmd_zero },
	{ "cal",      "[sub]",                   "zero | corner <i> | solve <kg> | span <kg> | reset | save | load", cmd_cal },
	{ "stab",     "[band samples]",          "stability window (band in kg once spanned)", cmd_stab },
	{ "wim",      "[enter exit level|off]", "weigh-in-motion thresholds and last result", cmd_wim },
	{ "nn",       "[on|off|load [prefix]]",  "inference engine: state, model, last result", cmd_nn },
	{ "decim",    "[n]",                     "RESULT rate = 600 Hz / n", cmd_decim },
	{ "fir",      "[hz]",                    "FIR low-pass cutoff, 0.5 to 37 Hz", cmd_fir },
	{ "raw",      "<tap> <n>",               "capture n records through the DMA and print them", cmd_raw },
	{ "faults",   "[clear]",                 "sticky fault flags per channel", cmd_faults },
	{ "adc",      "",                        "rerun the AD7190 init list (reset, ID, calibrate, stream)", cmd_adc },
	{ "init",     "",                        "start-up: check the PL, load and apply the calibration, ADC init", cmd_init },
	{ "selftest", "",                        "AD7190 self-test: open wire, reference, noise", cmd_selftest },
	{ "bist",     "",                        "PL loopback test of the capture path", cmd_bist },
	{ "trace",    "[on|off]",                "print every register access, decoded, with its devmem form", cmd_trace },
	{ "rd",       "<addr>",                  "read a register (offset or absolute address)", cmd_rd },
	{ "wr",       "<addr> <value>",          "write a register", cmd_wr },
};

static void cmd_help(int argc, char **argv)
{
	(void)argc; (void)argv;
	for (unsigned i = 0; i < sizeof cmds / sizeof cmds[0]; i++)
		printf("  %-9s %-24s %s\n", cmds[i].name, cmds[i].args, cmds[i].help);
	printf("calibration: cal zero (no load), cal corner 0..7 (test weight over each cell), cal solve <kg>,\n"
	       "             cal save. cal span <kg> re-spans without the corner test.\n");
}

static int dispatch(int argc, char **argv)
{
	if (!argc)
		return 0;
	for (unsigned i = 0; i < sizeof cmds / sizeof cmds[0]; i++)
		if (!strcmp(argv[0], cmds[i].name)) {
			cmds[i].fn(argc, argv);
			return 0;
		}
	printf("unknown command \"%s\"; type help\n", argv[0]);
	return -1;
}

/* Shared hardware (hw->lock set, Linux): the console and mclpd each run a command under the lock, starting
 * from the stored settings and storing what the command changed, so neither works from stale settings. */
static void hw_lock(void)
{
	if (hw->lock)
		hw->lock();
	if (!n_ch) {                       /* one-shot commands: the channel count before the calibration */
		uint32_t id;
		id_check(&id);                 /* a wrong bitstream leaves n_ch 0; status and init report it */
	}
	if (!loaded) {
		cal_load_or_defaults(0);
	} else if (hw->lock) {
		cal_t tmp;
		if (!hw->fetch(&tmp, sizeof tmp) && cal_valid(&tmp) && tmp.n_ch == (uint32_t)n_ch)
			cal = tmp;
	}
}

static void hw_unlock(void)
{
	if (hw->unlock)
		hw->unlock();
}

static int run_cmd(int argc, char **argv)
{
	hw_lock();
	uint32_t before = cal_checksum(&cal);
	int rc = dispatch(argc, argv);
	if ((hw->lock || oneshot) && cal_checksum(&cal) != before) {
		cal.sum = cal_checksum(&cal);
		if (hw->store(&cal, sizeof cal) == 0)
			printf("(settings saved to %s)\n", hw->store_name);
	}
	hw_unlock();
	return rc;
}

int console_exec(int argc, char **argv)
{
	failed = 0;
	return run_cmd(argc, argv) ? 2 : failed;
}

void console_reading(reading_t *r)
{
	int t = trace;                     /* periodic reads stay out of the register trace */
	trace = 0;
	hw_lock();
	uint32_t st = reg_rd(REG_STATUS);
	r->seq      = reg_rd(REG_RESULT_SEQ);
	r->spanned  = spanned();
	r->value    = net_value((int32_t)reg_rd(REG_RESULT));
	r->stable   = (st & ST_STABLE) != 0;
	r->overload = (st & ST_OVERLOAD) != 0;
	memset(r->faults, 0, sizeof r->faults);   /* mclpd compares the whole array */
	for (int ch = 0; ch < n_ch; ch++)
		r->faults[ch] = reg_rd(REG_FAULT(ch));
	r->wim_sum   = ((uint64_t)reg_rd(REG_WIM_SUM_HI) << 32) | reg_rd(REG_WIM_SUM_LO);
	r->wim_n     = reg_rd(REG_WIM_COUNT);
	r->wim_value = r->wim_n ? net_value((double)(int64_t)r->wim_sum / r->wim_n) : 0.0;
	r->nn_seq    = reg_rd(REG_NN_SEQ);
	if (r->nn_seq == READ_BAD)
		r->nn_seq = 0;
	r->nn_value  = r->nn_seq ? net_value((int32_t)reg_rd(REG_NN_EST)) : 0.0;
	r->nn_corr   = r->nn_seq ? (int32_t)reg_rd(REG_NN_CORR) / 1048576.0 : 0.0;
	hw_unlock();
	trace = t;
}

/* ------------------------------------------------------------------ console */

static char line[128], last[128];
static int  len, esc;

static void prompt(void)
{
	printf("mclp> ");
	fflush(stdout);
}

static int read_line(void)      /* 1 when Enter completes a line; up arrow recalls the last command */
{
	int c = key_get();
	if (c < 0)
		return 0;
	if (esc) {
		if (esc == 1) {
			esc = c == '[' ? 2 : 0;
			return 0;
		}
		esc = 0;
		if (c == 'A' && last[0]) {
			while (len) {
				printf("\b \b");
				len--;
			}
			strcpy(line, last);
			len = (int)strlen(line);
			printf("%s", line);
		}
		fflush(stdout);
		return 0;
	}
	if (c == 27) {
		esc = 1;
	} else if (c == '\r' || c == '\n') {
		line[len] = 0;
		len = 0;
		printf("\n");
		return 1;
	} else if ((c == 8 || c == 127) && len > 0) {
		len--;
		printf("\b \b");
	} else if (c >= 32 && c < 127 && len < (int)sizeof line - 1) {
		line[len++] = (char)c;
		putchar(c);
	}
	fflush(stdout);
	return 0;
}

static void run_line(char *s)
{
	char *argv[8];
	int argc = 0;
	for (char *tok = strtok(s, " \t"); tok && argc < 8; tok = strtok(NULL, " \t"))
		argv[argc++] = tok;
	run_cmd(argc, argv);
}

int console_run(int argc, char **argv)
{
	if (argc > 1) {                     /* one command, then return */
		oneshot = 1;
		return console_exec(argc - 1, argv + 1);
	}

	printf("\r\n\nmclp console %s (%s)\n", VERSION, hw->name);
	hw_lock();
	int e = platform_check();
	if (!e) {
		cal_load_or_defaults(1);
		cal_apply();
		adc_init();
	}
	hw_unlock();
	if (e)
		return 1;
	printf("type help for commands\n");
	prompt();

	uint32_t t_event = ms_now();
	for (;;) {
		if (read_line()) {
			if (!strcmp(line, "quit") || !strcmp(line, "exit"))
				return 0;
			if (line[0]) {
				strcpy(last, line);
				run_line(line);
			}
			prompt();
		}
		if (ms_now() - t_event > 500) {     /* report new faults and overloads between commands */
			hw_lock();
			uint32_t irq = reg_rd(REG_IRQ_STATUS) & (IRQ_FAULT | IRQ_OVERLOAD);
			if (irq)
				reg_wr(REG_IRQ_STATUS, irq);
			hw_unlock();
			t_event = ms_now();
			if (irq) {
				printf("\n[%s%s]\n", irq & IRQ_FAULT ? "new fault flag, see faults " : "",
				       irq & IRQ_OVERLOAD ? "overload" : "");
				prompt();
				line[len] = 0;
				printf("%s", line);
				fflush(stdout);
			}
		}
	}
}
