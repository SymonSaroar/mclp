/*
 * Hardware access for the bare-metal console: registers, sequencer, FIR reload, raw capture through the
 * AXI DMA, SD card storage, UART and time.
 */
#ifndef MCLP_HW_H
#define MCLP_HW_H

#include <stdint.h>

#include "mclp_regs.h"

#define RING_N      8000            /* raw capture ring, one record per descriptor */
#define CAPTURE_MAX (RING_N - 100)

typedef struct {
	uint64_t ts;                    /* clk_spi ticks at the frame's RDY edge */
	unsigned tap;
	unsigned faults;                /* bit ch: any flag on channel ch in this frame */
	int32_t  s[N_CH];
} record_t;

uint32_t reg_rd(unsigned off);
void     reg_wr(unsigned off, uint32_t v);
uint32_t mem_rd(uint32_t addr);
void     mem_wr(uint32_t addr, uint32_t v);
void     ctrl_set(uint32_t set, uint32_t clear);     /* read-modify-write of the CTRL level bits */
void     ctrl_pulse(uint32_t pulse);

uint32_t ms_now(void);
void     delay_ms(unsigned ms);
int      uart_getc(void);                           /* -1 when no character is waiting */
int      key_pressed(void);

int  hw_init(void);                                 /* 0, or -1 when the ID register is wrong */
int  seq_run(const uint32_t *prog, int words, unsigned timeout_ms);   /* 0, or -1 if it never reached STREAM/END */
int  seq_default(void);                             /* the power-up list from seq_init.h */
int  fir_load(const int32_t taps[FIR_TAPS]);        /* 0, or -1 if the reload did not finish */
void fault_clear(void);

int  capture(unsigned tap, int n, unsigned timeout_ms);           /* one-shot capture; records received */
void record_get(int i, record_t *r);
int  capture_mean(unsigned tap, int n, double mean[N_CH]);        /* 0, or -1 short capture, -2 wrong tap */
int  result_mean(int n, double *mean);              /* mean of the next n RESULT updates; 0 or -1 */
uint32_t dma_status(void);

int  sd_save(const char *path, const void *p, unsigned n);        /* 0, or <0 on error */
int  sd_load(const char *path, void *p, unsigned n);

#endif
