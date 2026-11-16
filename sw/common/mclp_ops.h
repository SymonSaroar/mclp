/*
 * Register-level operations shared by the bare-metal console and the Linux console, on top of a small
 * platform backend. Every register access goes through reg_rd/reg_wr/mem_rd/
 * mem_wr, which print a decoded trace line (with the equivalent devmem command) when trace is on.
 */
#ifndef MCLP_OPS_H
#define MCLP_OPS_H

#include <stdint.h>

#include "mclp_regs.h"

/* What differs between platforms */
typedef struct {
	const char *name;
	uint32_t (*rd)(uint32_t addr);                /* absolute bus address */
	void     (*wr)(uint32_t addr, uint32_t v);
	uint64_t (*now_us)(void);                     /* monotonic microseconds */
	void     (*delay_us)(uint32_t us);
	int      (*getc)(void);                       /* -1 when no key is waiting */
	int      (*store)(const void *p, unsigned n); /* calibration record: 0, or <0 on error */
	int      (*fetch)(void *p, unsigned n);
	const char *store_name;
	volatile uint32_t *ring;                      /* raw capture ring as the CPU sees it, 64-byte aligned */
	uint32_t ring_phys;                           /* the same memory as the DMA sees it */
	uint32_t ring_bytes;
	void     (*barrier)(void);                    /* descriptors visible to the DMA */
} backend_t;

typedef struct {
	uint64_t ts;                                  /* clk_spi ticks at the frame's RDY edge */
	unsigned tap;
	unsigned faults;                              /* bit ch: any flag on channel ch in this frame */
	int32_t  s[N_CH];
} record_t;

extern const backend_t *hw;
extern int trace;                                 /* 1: print every register access */

/* Register access and time */
uint32_t reg_rd(unsigned off);
void     reg_wr(unsigned off, uint32_t v);
uint32_t mem_rd(uint32_t addr);
void     mem_wr(uint32_t addr, uint32_t v);
void     ctrl_set(uint32_t set, uint32_t clear);  /* read-modify-write of the CTRL level bits */
void     ctrl_pulse(uint32_t pulse);
uint32_t ms_now(void);
void     delay_ms(unsigned ms);
int      key_pressed(void);
int      key_get(void);                           /* -1 when no key is waiting */
void     step(const char *fmt, ...);              /* trace heading for a group of accesses */

/* Operations */
int  seq_run(const uint32_t *prog, int words, unsigned timeout_ms);  /* 0, or -1 if it never reached STREAM/END */
int  seq_default(void);
int  fir_load(const int32_t taps[FIR_TAPS]);       /* 0, or -1 if the reload did not finish */
void fault_clear(void);
int  capture_max(void);
int  capture(unsigned tap, int n, unsigned timeout_ms);              /* one-shot capture; records received */
void record_get(int i, record_t *r);
int  capture_mean(unsigned tap, int n, double mean[N_CH]);           /* 0, or -1 short capture, -2 wrong tap */
int  result_mean(int n, double *mean);            /* mean of the next n RESULT updates; 0 or -1 */
uint32_t dma_status(void);

/* The console (sw/common/console.c): argc <= 1 runs the interactive console, otherwise one command */
int console_run(int argc, char **argv);

#endif
