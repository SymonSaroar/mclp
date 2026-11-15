#include <string.h>

#include "ff.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "xil_mmu.h"
#include "xparameters.h"
#include "xpseudo_asm.h"
#include "xtime_l.h"
#include "xuartps_hw.h"

#include "seq_init.h"
#include "mclp_hw.h"

#ifndef STDIN_BASEADDRESS
#define STDIN_BASEADDRESS 0xE0001000u           /* PS UART1, the ZC702 USB-UART */
#endif

/* S2MM descriptor (PG021), 64 bytes, 64-byte aligned */
typedef struct {
	uint32_t next, next_msb, buf, buf_msb, rsvd[2], ctrl, status;
	uint32_t app[8];
} bd_t;

/* Raw capture ring in one 1 MB MMU section, mapped non-cacheable: the DMA writes DDR through HP0, which
 * does not snoop the CPU caches. */
static struct {
	bd_t     bd[RING_N];
	uint32_t buf[RING_N][16];                     /* one 40-byte record per 64-byte buffer */
	bd_t     tail;                                /* outside the chain: the TAILDESC write starts cyclic mode */
} ring __attribute__((aligned(0x100000)));

_Static_assert(sizeof ring <= 0x100000, "the capture ring must fit one MMU section");

static FATFS fatfs;
static FIL   file;

uint32_t reg_rd(unsigned off)             { return Xil_In32(MCLP_BASE + off); }
void     reg_wr(unsigned off, uint32_t v) { Xil_Out32(MCLP_BASE + off, v); }
uint32_t mem_rd(uint32_t addr)            { return Xil_In32(addr); }
void     mem_wr(uint32_t addr, uint32_t v){ Xil_Out32(addr, v); }

void ctrl_set(uint32_t set, uint32_t clear)
{
	reg_wr(REG_CTRL, (reg_rd(REG_CTRL) & ~clear) | set);
}

void ctrl_pulse(uint32_t pulse)
{
	reg_wr(REG_CTRL, reg_rd(REG_CTRL) | pulse);
}

uint32_t ms_now(void)
{
	XTime t;
	XTime_GetTime(&t);
	return (uint32_t)(t / (COUNTS_PER_SECOND / 1000u));
}

void delay_ms(unsigned ms)
{
	uint32_t t0 = ms_now();
	while (ms_now() - t0 < ms)
		;
}

int key_pressed(void)
{
	return XUartPs_IsReceiveData(STDIN_BASEADDRESS) ? 1 : 0;
}

int uart_getc(void)
{
	if (!key_pressed())
		return -1;
	return (int)(XUartPs_ReadReg(STDIN_BASEADDRESS, XUARTPS_FIFO_OFFSET) & 0xFFu);
}

int hw_init(void)
{
	Xil_DCacheFlushRange((INTPTR)&ring, sizeof ring);      /* no dirty lines may land on DMA data later */
	Xil_SetTlbAttributes((INTPTR)&ring, NORM_NONCACHE);
	return reg_rd(REG_ID) == FPGA_ID ? 0 : -1;
}

int seq_run(const uint32_t *prog, int words, unsigned timeout_ms)
{
	for (int i = 0; i < words && i < SEQ_WORDS; i++)
		reg_wr(REG_SEQ(i), prog[i]);
	if (words + 2 <= SEQ_WORDS) {                  /* END after the program */
		reg_wr(REG_SEQ(words), SEQ_CMD(SEQ_END, 0, 0, 0));
		reg_wr(REG_SEQ(words + 1), 0);
	}
	reg_wr(REG_IRQ_STATUS, IRQ_SEQ_DONE);
	ctrl_pulse(CTRL_SEQ_START);
	uint32_t t0 = ms_now();
	while (!(reg_rd(REG_IRQ_STATUS) & IRQ_SEQ_DONE))   /* busy falls at STREAM or END */
		if (ms_now() - t0 > timeout_ms)
			return -1;
	return 0;
}

int seq_default(void)
{
	return seq_run(SEQ_INIT, SEQ_INIT_WORDS, 200);
}

int fir_load(const int32_t taps[FIR_TAPS])
{
	for (int i = 0; i < FIR_TAPS; i++)
		reg_wr(REG_FIR(i), (uint32_t)taps[i]);
	ctrl_pulse(CTRL_FIR_RELOAD);
	delay_ms(1);                                   /* reload_busy crosses back to the AXI clock */
	uint32_t t0 = ms_now();
	while (reg_rd(REG_STATUS) & ST_RELOAD_BUSY)
		if (ms_now() - t0 > 100)
			return -1;
	return 0;
}

void fault_clear(void)
{
	ctrl_pulse(CTRL_FAULT_CLEAR);
	reg_wr(REG_IRQ_STATUS, IRQ_FAULT);
}

uint32_t dma_status(void)
{
	return Xil_In32(DMA_BASE + S2MM_DMASR);
}

static void dma_arm(void)
{
	volatile bd_t *bd = ring.bd;

	Xil_Out32(DMA_BASE + S2MM_DMACR, DMACR_RESET);
	uint32_t t0 = ms_now();
	while ((Xil_In32(DMA_BASE + S2MM_DMACR) & DMACR_RESET) && ms_now() - t0 < 10)
		;
	for (int i = 0; i < RING_N; i++) {
		bd[i].next     = (uint32_t)(UINTPTR)&ring.bd[(i + 1) % RING_N];
		bd[i].next_msb = 0;
		bd[i].buf      = (uint32_t)(UINTPTR)ring.buf[i];
		bd[i].buf_msb  = 0;
		bd[i].ctrl     = sizeof ring.buf[0];
		bd[i].status   = 0;
	}
	dsb();                                         /* descriptors visible before the DMA fetches them */
	Xil_Out32(DMA_BASE + S2MM_CURDESC, (uint32_t)(UINTPTR)&ring.bd[0]);
	Xil_Out32(DMA_BASE + S2MM_DMACR, DMACR_RS | DMACR_CYCLIC);
	Xil_Out32(DMA_BASE + S2MM_TAILDESC, (uint32_t)(UINTPTR)&ring.tail);
}

int capture(unsigned tap, int n, unsigned timeout_ms)
{
	volatile bd_t *bd = ring.bd;
	int got = 0;

	if (n < 1)
		return 0;
	if (n > CAPTURE_MAX)
		n = CAPTURE_MAX;
	ctrl_set(0, CTRL_RAW_ENABLE);
	delay_ms(2);                                   /* a record in flight drains into the old ring */
	dma_arm();
	reg_wr(REG_TRIG_CFG, TRIG_FRAMES(n) | TRIG_ONESHOT);
	ctrl_set(((tap & 3u) << CTRL_TAP_SHIFT) | CTRL_RAW_ENABLE, CTRL_TAP_MASK);
	reg_wr(REG_IRQ_STATUS, IRQ_CAPTURE_DONE);
	ctrl_pulse(CTRL_SW_TRIGGER);
	uint32_t t0 = ms_now();
	while (got < n && ms_now() - t0 < timeout_ms)
		while (got < n && (bd[got].status & BD_CMPLT))
			got++;
	ctrl_set(0, CTRL_RAW_ENABLE);
	return got;
}

void record_get(int i, record_t *r)
{
	const volatile uint32_t *w = ring.buf[i];      /* {ts, tap, 0, faults}, {s1, s0}, ... little endian */
	r->faults = w[0] & 0xFFu;
	r->tap    = (w[0] >> 14) & 3u;
	r->ts     = ((uint64_t)w[1] << 16) | (w[0] >> 16);
	for (int ch = 0; ch < N_CH; ch++)
		r->s[ch] = (int32_t)w[2 + ch];
}

int capture_mean(unsigned tap, int n, double mean[N_CH])
{
	int64_t sum[N_CH] = {0};
	record_t r;

	if (capture(tap, n, 2000u + 2u * (unsigned)n) < n)
		return -1;
	for (int i = 0; i < n; i++) {
		record_get(i, &r);
		if (r.tap != tap)
			return -2;
		for (int ch = 0; ch < N_CH; ch++)
			sum[ch] += r.s[ch];
	}
	for (int ch = 0; ch < N_CH; ch++)
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
		}
	}
	*mean = (double)sum / n;
	return 0;
}

int sd_save(const char *path, const void *p, unsigned n)
{
	UINT bw = 0;
	if (f_mount(&fatfs, "0:/", 1) != FR_OK)
		return -1;
	if (f_open(&file, path, FA_CREATE_ALWAYS | FA_WRITE) != FR_OK)
		return -2;
	FRESULT r = f_write(&file, p, n, &bw);
	if (f_close(&file) != FR_OK || r != FR_OK || bw != n)
		return -3;
	return 0;
}

int sd_load(const char *path, void *p, unsigned n)
{
	UINT br = 0;
	if (f_mount(&fatfs, "0:/", 1) != FR_OK)
		return -1;
	if (f_open(&file, path, FA_READ) != FR_OK)
		return -2;
	FRESULT r = f_read(&file, p, n, &br);
	f_close(&file);
	return (r == FR_OK && br == n) ? 0 : -3;
}
