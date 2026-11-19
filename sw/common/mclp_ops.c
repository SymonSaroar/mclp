#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "seq_init.h"
#include "mclp_ops.h"

const backend_t *hw;
int trace;
int n_ch;

/* ------------------------------------------------------------------ trace */

static const struct { unsigned off; const char *name; } REGS[] = {
	{ REG_ID, "ID" }, { REG_CTRL, "CTRL" }, { REG_STATUS, "STATUS" }, { REG_IRQ_STATUS, "IRQ_STATUS" },
	{ REG_IRQ_ENABLE, "IRQ_ENABLE" }, { REG_RESULT, "RESULT" }, { REG_RESULT_SEQ, "RESULT_SEQ" },
	{ REG_WIM_SUM_LO, "WIM_SUM_LO" }, { REG_WIM_SUM_HI, "WIM_SUM_HI" }, { REG_WIM_COUNT, "WIM_COUNT" },
	{ REG_STAB_BAND, "STAB_BAND" }, { REG_STAB_COUNT, "STAB_COUNT" }, { REG_WIM_ENTER, "WIM_ENTER" },
	{ REG_WIM_EXIT, "WIM_EXIT" }, { REG_WIM_SETTLE, "WIM_SETTLE" }, { REG_RESULT_DECIM, "RESULT_DECIM" },
	{ REG_TRIG_CFG, "TRIG_CFG" }, { REG_TRIG_THRESH, "TRIG_THRESH" }, { REG_LB_CFG, "LOOPBACK_CFG" },
	{ REG_LB_VALUE, "LOOPBACK_VALUE" },
};

static void bits(char *s, uint32_t v, const char *const *names, int n)
{
	for (int i = 0; i < n; i++)
		if (names[i] && (v >> i & 1u)) {
			strcat(s, names[i]);
			strcat(s, " ");
		}
}

static void reg_name(uint32_t addr, char *name, char *what, uint32_t v)
{
	static const char *const CTRL_B[] = { "enable", "loopback", "FIR_RELOAD", "SEQ_START", 0, 0, "raw_enable",
	                                      "SW_TRIGGER", "FAULT_CLEAR" };
	static const char *const ST_B[]   = { "locked", "seq_busy", "reload_busy", "overload", "stable", "capture" };
	static const char *const IRQ_B[]  = { "result", "stable", "wim", "overload", "fault", "seq_done", "capture_done" };
	static const char *const FLT_B[]  = { "ERR", "NOREF", "PARITY", "STALE", "MISMATCH" };
	static const char *const OPS[]    = { "END", "XFER", "SYNC", "WAIT_US", "WAIT_RDY", "STREAM" };
	unsigned off = addr - MCLP_BASE;

	what[0] = 0;
	if (addr >= DMA_BASE && addr < DMA_BASE + 0x10000u) {
		static const char *const CR_B[] = { "RS", 0, "RESET", 0, "CYCLIC" };
		static const char *const SR_B[] = { "halted", "idle", 0, "sg", "int_err", "slv_err", "dec_err", 0,
		                                    "sg_int_err", "sg_slv_err", "sg_dec_err", 0, "ioc", 0, "err" };
		off = addr - DMA_BASE;
		sprintf(name, "%s", off == S2MM_DMACR ? "DMA.S2MM_DMACR" : off == S2MM_DMASR ? "DMA.S2MM_DMASR" :
		        off == S2MM_CURDESC ? "DMA.S2MM_CURDESC" : off == S2MM_TAILDESC ? "DMA.S2MM_TAILDESC" : "DMA.?");
		if (off == S2MM_DMACR) bits(what, v, CR_B, 5);
		if (off == S2MM_DMASR) bits(what, v, SR_B, 15);
		return;
	}
	if (addr < MCLP_BASE || off >= 0x1000u) {
		sprintf(name, "?");
		return;
	}
	for (unsigned i = 0; i < sizeof REGS / sizeof REGS[0]; i++)
		if (REGS[i].off == off) {
			sprintf(name, "%s", REGS[i].name);
			if (off == REG_CTRL) {
				bits(what, v, CTRL_B, 9);
				sprintf(what + strlen(what), "tap=%u", (unsigned)(v >> 4 & 3u));
			} else if (off == REG_STATUS) {
				bits(what, v, ST_B, 6);
			} else if (off == REG_IRQ_STATUS || off == REG_IRQ_ENABLE) {
				bits(what, v, IRQ_B, 7);
			} else if (off == REG_RESULT || off == REG_STAB_BAND || off == REG_WIM_ENTER || off == REG_WIM_EXIT) {
				sprintf(what, "%ld", (long)(int32_t)v);
			} else if (off == REG_LB_CFG) {
				sprintf(what, "%s%s%sch=%u period=%u", v & LB_RAMP ? "ramp " : "", v & LB_INJECT_ERR ? "inject_ERR " : "",
				        v & LB_INJECT_PARITY ? "inject_parity " : "", (unsigned)(v >> 4 & 63u), (unsigned)(v >> 16));
			} else if (off == REG_TRIG_CFG) {
				sprintf(what, "mode=%u frames=%u", (unsigned)(v & 3u), (unsigned)(v >> 16));
			} else if (off == REG_ID) {
				if ((v & ~0xFFu) == FPGA_ID_MAP)
					sprintf(what, "mclp_registers, %u channels", ID_CHANNELS(v));
				else
					sprintf(what, "UNEXPECTED");
			}
			return;
		}
	if (off >= 0x200u && off < 0x300u) {
		sprintf(name, "FIR[%u]", (off - 0x200u) / 4u);
		sprintf(what, "%ld", (long)(int32_t)v);
	} else if (off >= 0x400u && off < 0x800u) {
		unsigned w = (off - 0x400u) / 4u;
		sprintf(name, "SEQ[%u]", w);
		if (w % 2u == 0u)
			sprintf(what, "cmd %s ntx=%u nrx=%u arg=%u", (v >> 28) < 6 ? OPS[v >> 28] : "?",
			        (unsigned)(v >> 22 & 63u), (unsigned)(v >> 16 & 63u), (unsigned)(v & 0xFFFFu));
		else
			sprintf(what, "data");
	} else if (off >= 0x800u && off < 0xD00u) {
		static const char *const ARR[] = { "SEQ_RESP", "GAIN", "OFFSET", "TRIM", "FAULT" };
		unsigned a = (off - 0x800u) >> 8;
		sprintf(name, "%s[%u]", ARR[a], (off & 0xFFu) / 4u);
		if (a == 1 || a == 3)
			sprintf(what, "%.6f", (double)(int32_t)v / 1073741824.0);
		else if (a == 2)
			sprintf(what, "%ld", (long)(int32_t)v);
		else if (a == 4)
			bits(what, v, FLT_B, 5);
	} else {
		sprintf(name, "?");
	}
}

static uint32_t last_addr = 0xFFFFFFFFu, last_val;
static unsigned repeats;

static void flush_repeats(void)
{
	if (repeats)
		printf("%14s read %u more times with the same value\n", "", repeats);
	repeats = 0;
	last_addr = 0xFFFFFFFFu;
}

static void trace_access(int write, uint32_t addr, uint32_t v)
{
	char name[24], what[96], dm[48];
	if (!write && addr == last_addr && v == last_val) {
		repeats++;
		return;
	}
	flush_repeats();
	if (!write) {
		last_addr = addr;
		last_val = v;
	}
	reg_name(addr, name, what, v);
	if (write)
		sprintf(dm, "devmem 0x%08X 32 0x%08X", (unsigned)addr, (unsigned)v);
	else
		sprintf(dm, "devmem 0x%08X", (unsigned)addr);
	printf("[%10.3f ms] %s %-17s %s 0x%08X  %-34s %s\n", (double)hw->now_us() / 1000.0, write ? "WR" : "RD",
	       name, write ? "<-" : "->", (unsigned)v, what, dm);
}

void step(const char *fmt, ...)
{
	va_list ap;
	if (!trace)
		return;
	flush_repeats();
	printf("[%10.3f ms] ---- ", (double)hw->now_us() / 1000.0);
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	printf("\n");
}

/* ------------------------------------------------------------------ access and time */

uint32_t mem_rd(uint32_t addr)
{
	uint32_t v = hw->rd(addr);
	if (trace)
		trace_access(0, addr, v);
	return v;
}

void mem_wr(uint32_t addr, uint32_t v)
{
	if (trace)
		trace_access(1, addr, v);
	hw->wr(addr, v);
}

uint32_t reg_rd(unsigned off)             { return mem_rd(MCLP_BASE + off); }
void     reg_wr(unsigned off, uint32_t v) { mem_wr(MCLP_BASE + off, v); }

void ctrl_set(uint32_t set, uint32_t clear)
{
	reg_wr(REG_CTRL, (reg_rd(REG_CTRL) & ~clear) | set);
}

void ctrl_pulse(uint32_t pulse)
{
	reg_wr(REG_CTRL, reg_rd(REG_CTRL) | pulse);
}

uint32_t ms_now(void)       { return (uint32_t)(hw->now_us() / 1000u); }
void     delay_ms(unsigned ms) { hw->delay_us(ms * 1000u); }

static int pending = -1;

int key_pressed(void)
{
	if (pending < 0)
		pending = hw->getc();
	return pending >= 0;
}

int key_get(void)
{
	int c = pending >= 0 ? pending : hw->getc();
	pending = -1;
	return c;
}

/* ------------------------------------------------------------------ operations */

int id_check(uint32_t *id)
{
	*id = reg_rd(REG_ID);
	if ((*id & ~0xFFu) != FPGA_ID_MAP || ID_CHANNELS(*id) < 1u || ID_CHANNELS(*id) > MAX_CH)
		return -1;
	n_ch = (int)ID_CHANNELS(*id);
	return 0;
}

int seq_run(const uint32_t *prog, int words, unsigned timeout_ms)
{
	step("sequencer: load %d words into the sequencer RAM, then start from word 0", words);
	for (int i = 0; i < words && i < SEQ_WORDS; i++)
		reg_wr(REG_SEQ(i), prog[i]);
	if (words + 2 <= SEQ_WORDS) {
		reg_wr(REG_SEQ(words), SEQ_CMD(SEQ_END, 0, 0, 0));
		reg_wr(REG_SEQ(words + 1), 0);
	}
	reg_wr(REG_IRQ_STATUS, IRQ_SEQ_DONE);
	ctrl_pulse(CTRL_SEQ_START);
	step("sequencer: wait for IRQ_STATUS.seq_done (busy falls at STREAM or END)");
	uint32_t t0 = ms_now();
	while (!(reg_rd(REG_IRQ_STATUS) & IRQ_SEQ_DONE)) {
		if (ms_now() - t0 > timeout_ms)
			return -1;
		hw->delay_us(250);
	}
	return 0;
}

int seq_default(void)
{
	step("ADC init list: reset, read ID, configure, zero-scale calibration, continuous read, stream");
	return seq_run(SEQ_INIT, SEQ_INIT_WORDS, 200);
}

int fir_load(const int32_t taps[FIR_TAPS])
{
	step("FIR: write 64 taps into the coefficient RAM, pulse CTRL.fir_reload");
	for (int i = 0; i < FIR_TAPS; i++)
		reg_wr(REG_FIR(i), (uint32_t)taps[i]);
	ctrl_pulse(CTRL_FIR_RELOAD);
	delay_ms(1);
	uint32_t t0 = ms_now();
	while (reg_rd(REG_STATUS) & ST_RELOAD_BUSY) {
		if (ms_now() - t0 > 100)
			return -1;
		hw->delay_us(250);
	}
	return 0;
}

void fault_clear(void)
{
	step("faults: pulse CTRL.fault_clear, clear IRQ_STATUS.fault");
	ctrl_pulse(CTRL_FAULT_CLEAR);
	reg_wr(REG_IRQ_STATUS, IRQ_FAULT);
}

uint32_t dma_status(void)
{
	return mem_rd(DMA_BASE + S2MM_DMASR);
}

/* Raw capture ring: n descriptors, n buffers of one record each (rounded up to 64 bytes) and a spare
 * descriptor outside the chain, whose address in TAILDESC starts cyclic mode (PG021). A record is 2 +
 * ceil(n_ch / 2) 64-bit words: 48 bytes at 8 channels, 272 at 64. */
static unsigned rec_words(void) { return 2u + ((unsigned)n_ch + 1u) / 2u; }
static unsigned buf_bytes(void) { return (8u * rec_words() + 63u) & ~63u; }

static int ring_n(void)
{
	int n = (int)((hw->ring_bytes - 64u) / (64u + buf_bytes()));
	return n > 8000 ? 8000 : n;
}

static volatile uint32_t *bd(int i)   { return hw->ring + 16 * i; }
static volatile uint32_t *buf(int i)  { return hw->ring + 16 * ring_n() + buf_bytes() / 4u * (unsigned)i; }
static uint32_t phys(volatile uint32_t *p) { return hw->ring_phys + 4u * (uint32_t)(p - hw->ring); }

int capture_max(void) { return ring_n() - 100; }

static void dma_arm(void)
{
	int n = ring_n();
	step("DMA: reset the S2MM channel");
	mem_wr(DMA_BASE + S2MM_DMACR, DMACR_RESET);
	uint32_t t0 = ms_now();
	while ((mem_rd(DMA_BASE + S2MM_DMACR) & DMACR_RESET) && ms_now() - t0 < 10)
		hw->delay_us(100);
	step("DMA: %d descriptors at 0x%08X, buffers at 0x%08X, cyclic", n, (unsigned)phys(bd(0)), (unsigned)phys(buf(0)));
	for (int i = 0; i < n; i++) {
		volatile uint32_t *d = bd(i);
		d[0] = phys(bd((i + 1) % n));
		d[1] = 0;
		d[2] = phys(buf(i));
		d[3] = 0;
		d[6] = buf_bytes();
		d[7] = 0;
	}
	hw->barrier();
	mem_wr(DMA_BASE + S2MM_CURDESC, phys(bd(0)));
	mem_wr(DMA_BASE + S2MM_DMACR, DMACR_RS | DMACR_CYCLIC);
	mem_wr(DMA_BASE + S2MM_TAILDESC, phys(bd(n)));
}

int capture(unsigned tap, int n, unsigned timeout_ms)
{
	int got = 0;
	if (n < 1)
		return 0;
	if (n > capture_max())
		n = capture_max();
	step("capture: stop raw records, arm the DMA ring");
	ctrl_set(0, CTRL_RAW_ENABLE);
	delay_ms(2);
	dma_arm();
	step("capture: one-shot of %d records at tap %u, then CTRL.sw_trigger", n, tap);
	reg_wr(REG_TRIG_CFG, TRIG_FRAMES(n) | TRIG_ONESHOT);
	ctrl_set(((tap & 3u) << CTRL_TAP_SHIFT) | CTRL_RAW_ENABLE, CTRL_TAP_MASK);
	reg_wr(REG_IRQ_STATUS, IRQ_CAPTURE_DONE);
	ctrl_pulse(CTRL_SW_TRIGGER);
	step("capture: poll the descriptors' Cmplt bits");
	uint32_t t0 = ms_now();
	while (got < n && ms_now() - t0 < timeout_ms) {
		while (got < n && (bd(got)[7] & BD_CMPLT))
			got++;
		if (got < n)
			delay_ms(1);
	}
	step("capture: %d of %d records, stop raw records", got, n);
	ctrl_set(0, CTRL_RAW_ENABLE);
	return got;
}

void record_get(int i, record_t *r)
{
	const volatile uint32_t *w = buf(i);          /* {ts, tap, 0}, {s1, s0}, ..., faults; little endian */
	unsigned f = 2u * (rec_words() - 1u);         /* the fault word */
	r->tap    = (w[0] >> 14) & 3u;
	r->ts     = ((uint64_t)w[1] << 16) | (w[0] >> 16);
	r->faults = ((uint64_t)w[f + 1] << 32) | w[f];
	for (int ch = 0; ch < n_ch; ch++)
		r->s[ch] = (int32_t)w[2 + ch];
}

int capture_mean(unsigned tap, int n, double mean[MAX_CH])
{
	int64_t sum[MAX_CH] = {0};
	record_t r;

	if (capture(tap, n, 2000u + 2u * (unsigned)n) < n)
		return -1;
	for (int i = 0; i < n; i++) {
		record_get(i, &r);
		if (r.tap != tap)
			return -2;
		for (int ch = 0; ch < n_ch; ch++)
			sum[ch] += r.s[ch];
	}
	for (int ch = 0; ch < n_ch; ch++)
		mean[ch] = (double)sum[ch] / n;
	return 0;
}

int result_mean(int n, double *mean)
{
	uint32_t seq = reg_rd(REG_RESULT_SEQ), t0 = ms_now();
	uint32_t timeout = 500u + 2u * reg_rd(REG_RESULT_DECIM);   /* one result period is decim / 0.6 ms */
	int64_t sum = 0;

	for (int k = 0; k < n;) {
		uint32_t s = reg_rd(REG_RESULT_SEQ);
		if (s != seq) {
			seq = s;
			sum += (int32_t)reg_rd(REG_RESULT);
			k++;
			t0 = ms_now();
		} else if (ms_now() - t0 > timeout) {
			return -1;
		} else {
			delay_ms(1);
		}
	}
	*mean = (double)sum / n;
	return 0;
}
