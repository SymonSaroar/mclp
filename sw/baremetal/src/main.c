/*
 * Bare-metal console for mclp on the ZC702 (UART1, 115200 8N1): the standalone backend
 * for sw/common (registers, timer, UART, SD card, capture ring), then the shared console.
 * The console polls IRQ_STATUS; the IRQ_F2P line is left to the Linux driver.
 */
#include <stdio.h>

#include "ff.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "xil_mmu.h"
#include "xparameters.h"
#include "xpseudo_asm.h"
#include "xiltimer.h"
#include "xuartps_hw.h"

#include "mclp_ops.h"

#ifndef STDIN_BASEADDRESS
#define STDIN_BASEADDRESS 0xE0001000u           /* PS UART1, the ZC702 USB-UART */
#endif
#define CAL_FILE "0:/mclp.cal"

/* Raw capture ring in one 1 MB MMU section, mapped non-cacheable: the DMA writes DDR through HP0, which
 * does not snoop the CPU caches. */
static uint32_t ring[0x100000 / 4] __attribute__((aligned(0x100000)));
static FATFS fatfs;
static FIL   file;

static uint32_t bm_rd(uint32_t addr)             { return Xil_In32(addr); }
static void     bm_wr(uint32_t addr, uint32_t v) { Xil_Out32(addr, v); }
static void     bm_barrier(void)                 { dsb(); }

static uint64_t bm_now_us(void)
{
	XTime t;
	XTime_GetTime(&t);
	return t / (COUNTS_PER_SECOND / 1000000u);
}

static void bm_delay_us(uint32_t us)
{
	uint64_t t0 = bm_now_us();
	while (bm_now_us() - t0 < us)
		;
}

static int bm_getc(void)
{
	if (!XUartPs_IsReceiveData(STDIN_BASEADDRESS))
		return -1;
	return (int)(XUartPs_ReadReg(STDIN_BASEADDRESS, XUARTPS_FIFO_OFFSET) & 0xFFu);
}

static int bm_store(const void *p, unsigned n)
{
	UINT bw = 0;
	if (f_mount(&fatfs, "0:/", 1) != FR_OK)
		return -1;
	if (f_open(&file, CAL_FILE, FA_CREATE_ALWAYS | FA_WRITE) != FR_OK)
		return -2;
	FRESULT r = f_write(&file, p, n, &bw);
	if (f_close(&file) != FR_OK || r != FR_OK || bw != n)
		return -3;
	return 0;
}

static int bm_fetch(void *p, unsigned n)
{
	UINT br = 0;
	if (f_mount(&fatfs, "0:/", 1) != FR_OK)
		return -1;
	if (f_open(&file, CAL_FILE, FA_READ) != FR_OK)
		return -2;
	FRESULT r = f_read(&file, p, n, &br);
	f_close(&file);
	return (r == FR_OK && br == n) ? 0 : -3;
}

static int bm_read_file(const char *path, char *buf, unsigned max)
{
	UINT br = 0;
	if (f_mount(&fatfs, "0:/", 1) != FR_OK)
		return -1;
	if (f_open(&file, path, FA_READ) != FR_OK)
		return -2;
	FRESULT r = f_read(&file, buf, max, &br);
	f_close(&file);
	return r == FR_OK ? (int)br : -3;
}

static backend_t baremetal = {
	.name = "standalone", .rd = bm_rd, .wr = bm_wr, .now_us = bm_now_us, .delay_us = bm_delay_us,
	.getc = bm_getc, .store = bm_store, .fetch = bm_fetch, .store_name = "the SD card (" CAL_FILE ")",
	.ring = ring, .ring_phys = 0, .ring_bytes = sizeof ring, .barrier = bm_barrier,
	.read_file = bm_read_file, .nn_model = "0:/nn",
};

int main(void)
{
	setvbuf(stdout, NULL, _IONBF, 0);
	Xil_DCacheFlushRange((INTPTR)ring, sizeof ring);       /* no dirty lines may land on DMA data later */
	Xil_SetTlbAttributes((INTPTR)ring, NORM_NONCACHE);
	baremetal.ring_phys = (uint32_t)(UINTPTR)ring;
	hw = &baremetal;
	printf("\r\nreading the PL register block at %08X (stops here if no bitstream is loaded)\n", MCLP_BASE);
	console_run(0, NULL);
	for (;;)
		;
}
