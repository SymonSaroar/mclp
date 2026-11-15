/*
 * Bare-metal console for mclp on the ZC702 (UART1, 115200 8N1).
 *
 * At start it checks the PL register block, loads the calibration from the SD card (0:/mclp.cal) or
 * uses defaults, reruns the AD7190 power-up list and reports the chip IDs. Type "help" for commands.
 * The console polls IRQ_STATUS; the IRQ_F2P line is left to the Linux driver.
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "calib.h"
#include "seq_init.h"
#include "mclp_hw.h"

#define VERSION   "1.0"
#define CAL_FILE  "0:/mclp.cal"
#define NOISE_MAX (3.0 * 295.0)        /* nV rms: 3 x the datasheet figure at FS = 1, gain 128 */

static cal_t  cal;
static double tare;                    /* RESULT counts */
static double baseline[N_CH];          /* tap 2 at no load, from cal zero */
static int    have_baseline;
static double pos_r[N_CH][N_CH];       /* tap 2 minus baseline, test weight at position i */
static int    pos_have[N_CH];
static unsigned adc_id[N_CH];

/* ------------------------------------------------------------------ helpers */

static int spanned(void) { return cal.kg_per_count != 0.0; }

static void print_weight(double raw)
{
	double net = raw - cal.zero - tare;
	if (spanned())
		printf("%11.3f kg", net * cal.kg_per_count);
	else
		printf("%11.0f counts", net);
}

static double user_to_counts(double v)  /* kg once spanned, counts before */
{
	return spanned() ? v / cal.kg_per_count : v;
}

static const char *unit(void) { return spanned() ? "kg" : "counts"; }

static int32_t clamp32(double v)
{
	return v >= 2147483647.0 ? 0x7FFFFFFF : v <= -2147483648.0 ? (int32_t)0x80000000 : (int32_t)lround(v);
}

static void wim_apply(void)
{
	int off = cal.wim_enter == 0x7FFFFFFF;
	reg_wr(REG_WIM_ENTER, (uint32_t)(off ? 0x7FFFFFFF : clamp32(cal.zero + cal.wim_enter)));
	reg_wr(REG_WIM_EXIT, (uint32_t)(off ? 0x7FFFFFFF : clamp32(cal.zero + cal.wim_exit)));
	reg_wr(REG_WIM_SETTLE, cal.wim_settle);
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
	for (int ch = 0; ch < N_CH; ch++) {
		reg_wr(REG_OFFSET(ch), (uint32_t)cal.offset[ch]);
		reg_wr(REG_GAIN(ch), cal.gain[ch]);
		reg_wr(REG_TRIM(ch), cal.trim[ch]);
	}
	reg_wr(REG_STAB_BAND, (uint32_t)cal.stab_band);
	reg_wr(REG_STAB_COUNT, cal.stab_count);
	reg_wr(REG_RESULT_DECIM, cal.decim);
	wim_apply();
	fir_apply(cal.fir_fc);
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
	for (int ch = 0; ch < N_CH; ch++)
		n += reg_rd(REG_FAULT(ch)) != 0;
	return n;
}

static int adc_init(void)
{
	int ok = 0;
	if (seq_default()) {
		printf("ADC init list did not reach STREAM within 200 ms (sequencer still busy)\n");
		return -1;
	}
	printf("ADC IDs:");
	for (int ch = 0; ch < N_CH; ch++) {
		adc_id[ch] = reg_rd(REG_SEQ_RESP(ch)) & 0xFFu;
		ok += (adc_id[ch] & 0x0Fu) == 4u;
		printf(" %02X", adc_id[ch]);
	}
	printf("  (%d of 8 answer as AD7190)\n", ok);
	delay_ms(5);
	fault_clear();
	return ok;
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

/* ------------------------------------------------------------------ commands */

static void cmd_help(int argc, char **argv);

static void cmd_status(int argc, char **argv)
{
	(void)argc; (void)argv;
	uint32_t st = reg_rd(REG_STATUS);
	printf("FPGA ID %08X, MMCM %s, sequencer %s, FIR reload %s\n", (unsigned)reg_rd(REG_ID),
	       st & ST_LOCKED ? "locked" : "NOT LOCKED", st & ST_SEQ_BUSY ? "busy" : "streaming",
	       st & ST_RELOAD_BUSY ? "busy" : "idle");
	printf("ADC IDs at the last init:");
	for (int ch = 0; ch < N_CH; ch++)
		printf(" %02X", adc_id[ch]);
	printf("\nweight:");
	print_weight((int32_t)reg_rd(REG_RESULT));
	printf("  %s%s, %d channel(s) with faults\n", st & ST_STABLE ? "stable" : "in motion",
	       st & ST_OVERLOAD ? ", OVERLOAD" : "", faults_any());
	printf("calibration: zero %.0f, tare %.0f, %s", cal.zero, tare, spanned() ? "" : "not spanned\n");
	if (spanned())
		printf("%.6g kg per count\n", cal.kg_per_count);
	printf("filter: FIR %.2f Hz, result %.1f Hz (decim %u), stability %d counts over %u samples\n", cal.fir_fc,
	       CIC_RATE_HZ / cal.decim, (unsigned)cal.decim, (int)cal.stab_band, (unsigned)cal.stab_count);
	printf("raw capture DMA status %08X\n", (unsigned)dma_status());
}

static void cmd_weight(int argc, char **argv)
{
	(void)argc; (void)argv;
	double r;
	if (result_mean(1, &r)) {
		printf("no RESULT update within 0.5 s\n");
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
	reg_wr(REG_IRQ_STATUS, IRQ_WIM | IRQ_FAULT);
	while (!key_pressed()) {
		uint32_t irq = reg_rd(REG_IRQ_STATUS);
		if (irq & IRQ_WIM) {
			reg_wr(REG_IRQ_STATUS, IRQ_WIM);
			printf("\n");
			print_wim();
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
		}
	}
	uart_getc();
	printf("\n");
}

static void cmd_tare(int argc, char **argv)
{
	double r;
	if (argc > 1 && !strcmp(argv[1], "clear")) {
		tare = 0.0;
		printf("tare cleared\n");
		return;
	}
	if (result_mean(25, &r)) {
		printf("no RESULT updates\n");
		return;
	}
	tare = r - cal.zero;
	printf("tare %.0f counts", tare);
	if (spanned())
		printf(" (%.3f kg)", tare * cal.kg_per_count);
	printf("\n");
}

static void cmd_zero(int argc, char **argv)
{
	(void)argc; (void)argv;
	double r;
	if (result_mean(25, &r)) {
		printf("no RESULT updates\n");
		return;
	}
	cal.zero = r;
	tare = 0.0;
	wim_apply();
	printf("zero set at %.0f counts (cal save keeps it)\n", r);
}

static void cal_show(void)
{
	printf("ch    offset    gain     trim   corner responses (tap 2, no-load baseline removed)\n");
	for (int ch = 0; ch < N_CH; ch++) {
		printf("%2d %9d %7.4f %8.5f ", ch, (int)cal.offset[ch], from_q30(cal.gain[ch]), from_q30(cal.trim[ch]));
		for (int i = 0; i < N_CH; i++)
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
	double m[N_CH], r;
	printf("no load on the platform; measuring 1 s of per-channel data...\n");
	int e = capture_mean(1, 600, m);
	if (e) {
		printf("raw capture failed (%d, DMA status %08X)\n", e, (unsigned)dma_status());
		return;
	}
	for (int ch = 0; ch < N_CH; ch++) {
		cal.offset[ch] = clamp32(m[ch]);
		reg_wr(REG_OFFSET(ch), (uint32_t)cal.offset[ch]);
	}
	if (capture_mean(2, 600, baseline) || result_mean(25, &r)) {
		printf("measurement after the offsets failed\n");
		return;
	}
	have_baseline = 1;
	memset(pos_have, 0, sizeof pos_have);
	cal.zero = r;
	tare = 0.0;
	wim_apply();
	cal_show();
}

static void cal_corner(int i)
{
	double m[N_CH], tot = 0.0;
	if (!have_baseline) {
		printf("run \"cal zero\" first\n");
		return;
	}
	if (i < 0 || i >= N_CH) {
		printf("position 0 to %d\n", N_CH - 1);
		return;
	}
	printf("position %d: measuring 1 s...\n", i);
	if (capture_mean(2, 600, m)) {
		printf("raw capture failed\n");
		return;
	}
	for (int ch = 0; ch < N_CH; ch++) {
		pos_r[i][ch] = m[ch] - baseline[ch];
		tot += pos_r[i][ch];
	}
	pos_have[i] = 1;
	printf("share per channel:");
	for (int ch = 0; ch < N_CH; ch++)
		printf(" %5.1f%%", tot != 0.0 ? 100.0 * pos_r[i][ch] / tot : 0.0);
	printf("\n");
}

static void cal_solve(double kg)
{
	double r[N_CH][N_CH], t[N_CH], z = 0.0;
	int m = 0, warn = 0;
	for (int i = 0; i < N_CH; i++)
		if (pos_have[i])
			memcpy(r[m++], pos_r[i], sizeof r[0]);
	if (m == 0 || kg <= 0.0) {
		printf("usage: cal corner <i> for each position, then cal solve <test weight in kg>\n");
		return;
	}
	double s = solve_trims(m, r, t);
	if (s <= 0.0) {
		printf("the recorded positions do not determine the trims; check the test weight placement\n");
		return;
	}
	for (int ch = 0; ch < N_CH; ch++) {
		if (t[ch] <= 0.0 || t[ch] >= 2.0) {
			printf("trim %d = %.4f is outside (0, 2): check the wiring of load cell %d\n", ch, t[ch], ch);
			return;
		}
		warn |= t[ch] < 0.8 || t[ch] > 1.2;
	}
	for (int ch = 0; ch < N_CH; ch++) {
		cal.trim[ch] = q30(t[ch]);
		reg_wr(REG_TRIM(ch), cal.trim[ch]);
		z += t[ch] * baseline[ch];
	}
	cal.kg_per_count = kg / s;
	cal.zero = z;
	tare = 0.0;
	wim_apply();
	printf("trims from %d position(s):", m);
	for (int ch = 0; ch < N_CH; ch++)
		printf(" %.4f", t[ch]);
	printf("\nspan %.6g kg per count%s\n", cal.kg_per_count,
	       warn ? "; a trim is more than 20 % from 1, check the cells" : "");
}

static void cal_span(double kg)
{
	double r;
	if (kg <= 0.0) {
		printf("usage: cal span <known weight in kg>\n");
		return;
	}
	if (result_mean(50, &r)) {
		printf("no RESULT updates\n");
		return;
	}
	double d = r - cal.zero;
	if (fabs(d) < 1000.0) {
		printf("reading moved only %.0f counts from zero: is the weight on the platform?\n", d);
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
		cal_defaults(&cal);
		tare = 0.0;
		have_baseline = 0;
		memset(pos_have, 0, sizeof pos_have);
		cal_apply();
		printf("calibration reset: offsets 0, gains %.3f, trims 1, no span\n", GAIN_DEFAULT);
	} else if (!strcmp(sub, "save")) {
		cal.sum = cal_checksum(&cal);
		int e = sd_save(CAL_FILE, &cal, sizeof cal);
		printf(e ? "save failed (%d): is a FAT SD card inserted?\n" : "saved to " CAL_FILE "\n", e);
	} else if (!strcmp(sub, "load")) {
		int e = sd_load(CAL_FILE, &tmp, sizeof tmp);
		if (e || !cal_valid(&tmp)) {
			printf("no valid calibration in " CAL_FILE " (%d)\n", e);
			return;
		}
		cal = tmp;
		tare = 0.0;
		cal_apply();
		printf("loaded " CAL_FILE "\n");
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
		cal.wim_settle = (uint32_t)atoi(argv[3]);
		wim_apply();
	}
	if (cal.wim_enter == 0x7FFFFFFF)
		printf("weigh-in-motion off (wim <enter> <exit> <settle samples>, in %s above zero)\n", unit());
	else
		printf("weigh-in-motion: enter above %.4g %s, exit below %.4g %s, settle %u samples\n",
		       spanned() ? cal.wim_enter * cal.kg_per_count : cal.wim_enter, unit(),
		       spanned() ? cal.wim_exit * cal.kg_per_count : cal.wim_exit, unit(), (unsigned)cal.wim_settle);
	print_wim();
}

static void cmd_decim(int argc, char **argv)
{
	if (argc > 1) {
		int n = atoi(argv[1]);
		if (n < 1 || n > 65535) {
			printf("decim 1 to 65535\n");
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
		if (fir_apply(fc))
			return;
		cal.fir_fc = fc;
	}
	printf("FIR: 64-tap Hamming low-pass, cutoff %.2f Hz at %.0f Hz (fir <hz> to change, 0.5 to 37)\n",
	       cal.fir_fc, CIC_RATE_HZ);
}

static void cmd_raw(int argc, char **argv)
{
	record_t r;
	int tap = argc > 1 ? atoi(argv[1]) : -1, n = argc > 2 ? atoi(argv[2]) : 10;
	if (tap < 0 || tap > 3 || n < 1 || n > CAPTURE_MAX) {
		printf("raw <tap 0 AFE | 1 CIC | 2 gain | 3 trim> <records, up to %d>\n", CAPTURE_MAX);
		return;
	}
	int got = capture((unsigned)tap, n, 2000u + 2u * (unsigned)n);
	printf("record,ts,faults,s0,s1,s2,s3,s4,s5,s6,s7\n");
	for (int i = 0; i < got; i++) {
		record_get(i, &r);
		printf("%d,%llu,%02X", i, (unsigned long long)r.ts, r.faults);
		for (int ch = 0; ch < N_CH; ch++)
			printf(",%ld", (long)r.s[ch]);
		printf("\n");
	}
	if (got < n)
		printf("only %d of %d records (DMA status %08X)\n", got, n, (unsigned)dma_status());
}

static void cmd_faults(int argc, char **argv)
{
	char s[48];
	if (argc > 1 && !strcmp(argv[1], "clear")) {
		fault_clear();
		delay_ms(2);
	}
	for (int ch = 0; ch < N_CH; ch++)
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
	uint32_t prog[10], flt[N_CH];
	double sum[N_CH] = {0}, sq[N_CH] = {0};
	int32_t lo[N_CH], hi[N_CH];
	record_t r;
	const int n = 480;                  /* 0.1 s at 4800 SPS */

	printf("AD7190 self-test: burnout currents (open wire), reference detect, internal short noise\n");
	selftest_prog(prog, AD7190_CONFIG | AD_CFG_BURN);
	if (seq_run(prog, 10, 200)) {
		printf("sequencer stuck (no RDY on lane 0?)\n");
		goto restore;
	}
	delay_ms(20);
	fault_clear();
	delay_ms(20);
	for (int ch = 0; ch < N_CH; ch++)
		flt[ch] = reg_rd(REG_FAULT(ch));

	selftest_prog(prog, (AD7190_CONFIG & ~0xFF00u) | AD_CFG_SHORT);
	if (seq_run(prog, 10, 200)) {
		printf("sequencer stuck\n");
		goto restore;
	}
	delay_ms(10);
	if (capture(0, n, 1000) < n) {
		printf("raw capture failed (DMA status %08X)\n", (unsigned)dma_status());
		goto restore;
	}
	for (int ch = 0; ch < N_CH; ch++) {
		lo[ch] = 0x7FFFFFFF;
		hi[ch] = (int32_t)0x80000000;
	}
	for (int i = 0; i < n; i++) {
		record_get(i, &r);
		for (int ch = 0; ch < N_CH; ch++) {
			sum[ch] += r.s[ch];
			sq[ch]  += (double)r.s[ch] * r.s[ch];
			if (r.s[ch] < lo[ch]) lo[ch] = r.s[ch];
			if (r.s[ch] > hi[ch]) hi[ch] = r.s[ch];
		}
	}
	printf("ch  open wire  reference  short offset  noise rms     p-p     result\n");
	for (int ch = 0; ch < N_CH; ch++) {
		double mean = sum[ch] / n, rms = sqrt(fmax(sq[ch] / n - mean * mean, 0.0)) * AD_LSB_NV;
		int ok = !(flt[ch] & (FLT_ERR | FLT_NOREF)) && rms < NOISE_MAX;
		printf("%2d  %-9s  %-9s  %8.0f LSB  %6.0f nV  %6.0f nV  %s\n", ch, flt[ch] & FLT_ERR ? "OPEN" : "ok",
		       flt[ch] & FLT_NOREF ? "MISSING" : "ok", mean, rms, (hi[ch] - lo[ch]) * AD_LSB_NV,
		       ok ? "PASS" : "FAIL");
	}
restore:
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

	printf("loopback BIST: AD7190 emulator in the PL replaces the 8 DOUT pins\n");
	reg_wr(REG_LB_CFG, cfg);
	reg_wr(REG_LB_VALUE, value);
	ctrl_set(CTRL_LOOPBACK, 0);
	if (seq_run(stream, 2, 100)) {
		printf("sequencer stuck\n");
		bad++;
		goto restore;
	}
	delay_ms(5);
	fault_clear();
	delay_ms(5);
	for (int ch = 0; ch < N_CH; ch++)
		if (reg_rd(REG_FAULT(ch))) {
			printf("ch%d: fault %02X with clean emulator data\n", ch, (unsigned)reg_rd(REG_FAULT(ch)));
			bad++;
		}

	if (capture(0, 48, 500) < 48) {
		printf("raw capture failed (DMA status %08X)\n", (unsigned)dma_status());
		bad++;
	} else {
		for (int i = 0; i < 48; i++) {
			record_get(i, &r);
			for (int ch = 0; ch < N_CH; ch++) {
				int32_t want = (int32_t)(((value + ((uint32_t)ch << 16)) & 0xFFFFFFu) << 8) >> 8;
				if (r.s[ch] != want && bad < 10) {
					printf("record %d ch%d: %ld, expected %ld\n", i, ch, (long)r.s[ch], (long)want);
					bad++;
				}
			}
		}
	}

	for (int ch = 0; ch < N_CH; ch++) {             /* every channel's ERR path, then one parity error */
		fault_clear();
		reg_wr(REG_LB_CFG, cfg | LB_INJECT_ERR | LB_CH(ch));
		delay_ms(3);
		for (int k = 0; k < N_CH; k++) {
			uint32_t f = reg_rd(REG_FAULT(k)), want = k == ch ? FLT_ERR : 0u;
			if ((f & FLT_ERR) != want) {
				printf("ERR injected on ch%d: ch%d fault %02X\n", ch, k, (unsigned)f);
				bad++;
			}
		}
		reg_wr(REG_LB_CFG, cfg);
		delay_ms(2);
	}
	fault_clear();
	reg_wr(REG_LB_CFG, cfg | LB_INJECT_PARITY | LB_CH(5));
	delay_ms(3);
	if (!(reg_rd(REG_FAULT(5)) & FLT_PARITY)) {
		printf("parity error injected on ch5 not flagged\n");
		bad++;
	}
	reg_wr(REG_LB_CFG, cfg);
restore:
	ctrl_set(0, CTRL_LOOPBACK);
	delay_ms(2);
	printf("BIST %s\n", bad ? "FAILED" : "PASSED: data path bit-exact, fault flags on all 8 channels");
	adc_init();
}

static void cmd_adc(int argc, char **argv)
{
	(void)argc; (void)argv;
	adc_init();
}

static void cmd_rd(int argc, char **argv)
{
	if (argc < 2) {
		printf("rd <offset from 0x%08X, or absolute address>\n", MCLP_BASE);
		return;
	}
	uint32_t a = (uint32_t)strtoul(argv[1], NULL, 0);
	uint32_t v = a < 0x1000u ? reg_rd(a) : mem_rd(a);
	printf("%08X: %08X (%ld)\n", (unsigned)(a < 0x1000u ? MCLP_BASE + a : a), (unsigned)v, (long)(int32_t)v);
}

static void cmd_wr(int argc, char **argv)
{
	if (argc < 3) {
		printf("wr <offset or address> <value>\n");
		return;
	}
	uint32_t a = (uint32_t)strtoul(argv[1], NULL, 0), v = (uint32_t)strtoul(argv[2], NULL, 0);
	if (a < 0x1000u)
		reg_wr(a, v);
	else
		mem_wr(a, v);
}

static const struct {
	const char *name, *args, *help;
	void (*fn)(int, char **);
} cmds[] = {
	{ "help",     "",                       "this list", cmd_help },
	{ "status",   "",                       "clocks, sequencer, weight, faults, calibration, filters", cmd_status },
	{ "w",        "",                       "one weight reading", cmd_weight },
	{ "live",     "",                       "live weight with motion and WIM events; any key stops", cmd_live },
	{ "tare",     "[clear]",                "tare at the current reading, or clear it", cmd_tare },
	{ "zero",     "",                       "set the zero point at the current reading (no load)", cmd_zero },
	{ "cal",      "[sub]",                  "zero | corner <i> | solve <kg> | span <kg> | reset | save | load", cmd_cal },
	{ "stab",     "[band samples]",         "stability window (band in kg once spanned)", cmd_stab },
	{ "wim",      "[enter exit settle|off]", "weigh-in-motion thresholds and last result", cmd_wim },
	{ "decim",    "[n]",                    "RESULT rate = 600 Hz / n", cmd_decim },
	{ "fir",      "[hz]",                   "FIR low-pass cutoff, 0.5 to 37 Hz", cmd_fir },
	{ "raw",      "<tap> <n>",              "capture n records through the DMA and print them", cmd_raw },
	{ "faults",   "[clear]",                "sticky fault flags per channel", cmd_faults },
	{ "adc",      "",                       "rerun the AD7190 init list (reset, ID, calibrate, stream)", cmd_adc },
	{ "selftest", "",                       "AD7190 self-test: open wire, reference, noise", cmd_selftest },
	{ "bist",     "",                       "PL loopback test of the capture path", cmd_bist },
	{ "rd",       "<addr>",                 "read a register (offset or absolute address)", cmd_rd },
	{ "wr",       "<addr> <value>",         "write a register", cmd_wr },
};

static void cmd_help(int argc, char **argv)
{
	(void)argc; (void)argv;
	for (unsigned i = 0; i < sizeof cmds / sizeof cmds[0]; i++)
		printf("  %-9s %-24s %s\n", cmds[i].name, cmds[i].args, cmds[i].help);
	printf("calibration: cal zero (no load), cal corner 0..7 (test weight over each cell), cal solve <kg>,\n"
	       "             cal save. cal span <kg> re-spans without the corner test.\n");
}

/* ------------------------------------------------------------------ console */

static char line[128], last[128];
static int  len, esc;

static void prompt(void)
{
	printf("mclp> ");
}

static int read_line(void)      /* 1 when Enter completes a line; up arrow recalls the last command */
{
	int c = uart_getc();
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
	return 0;
}

static void dispatch(char *s)
{
	char *argv[8];
	int argc = 0;
	for (char *tok = strtok(s, " \t"); tok && argc < 8; tok = strtok(NULL, " \t"))
		argv[argc++] = tok;
	if (!argc)
		return;
	for (unsigned i = 0; i < sizeof cmds / sizeof cmds[0]; i++)
		if (!strcmp(argv[0], cmds[i].name)) {
			cmds[i].fn(argc, argv);
			return;
		}
	printf("unknown command \"%s\"; type help\n", argv[0]);
}

int main(void)
{
	cal_t tmp;

	setvbuf(stdout, NULL, _IONBF, 0);
	printf("\r\n\nmclp bare-metal console %s\n", VERSION);
	printf("reading the PL register block at %08X (stops here if no bitstream is loaded)\n", MCLP_BASE);
	if (hw_init()) {
		printf("ID register reads %08X, expected %08X: wrong bitstream\n", (unsigned)reg_rd(REG_ID), FPGA_ID);
		for (;;)
			;
	}
	uint32_t t0 = ms_now();
	while (!(reg_rd(REG_STATUS) & ST_LOCKED))
		if (ms_now() - t0 > 100) {
			printf("MMCM not locked after 100 ms\n");
			break;
		}

	int e = sd_load(CAL_FILE, &tmp, sizeof tmp);
	if (!e && cal_valid(&tmp)) {
		cal = tmp;
		printf("calibration loaded from " CAL_FILE "\n");
	} else {
		cal_defaults(&cal);
		printf("no calibration on the SD card (%d); defaults in use. Calibrate with cal zero, cal corner,\n"
		       "cal solve, then cal save.\n", e);
	}
	cal_apply();
	adc_init();
	printf("type help for commands\n");
	prompt();

	uint32_t t_event = ms_now();
	for (;;) {
		if (read_line()) {
			if (line[0]) {
				strcpy(last, line);
				dispatch(line);
			}
			prompt();
		}
		if (ms_now() - t_event > 500) {     /* report new faults and overloads between commands */
			uint32_t irq = reg_rd(REG_IRQ_STATUS) & (IRQ_FAULT | IRQ_OVERLOAD);
			t_event = ms_now();
			if (irq) {
				reg_wr(REG_IRQ_STATUS, irq);
				printf("\n[%s%s]\n", irq & IRQ_FAULT ? "new fault flag, see faults " : "",
				       irq & IRQ_OVERLOAD ? "overload" : "");
				prompt();
				line[len] = 0;
				printf("%s", line);
			}
		}
	}
}
