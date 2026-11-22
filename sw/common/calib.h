/*
 * Calibration math and the stored calibration record. No hardware access: sw/common/test/test_calib.c
 * builds and runs this file on a PC.
 */
#ifndef CALIB_H
#define CALIB_H

#include <stdint.h>

#include "mclp_regs.h"

#define CAL_CH       MAX_CH      /* record arrays; n_ch of them in use */
#define CAL_TAPS     64
#define CAL_MAGIC    0x4C414357u   /* "WCAL" */
#define CAL_VERSION  5u            /* layout of cal_t; a record of another version is not loaded */

typedef struct {
	uint32_t magic, version;
	uint32_t n_ch;                 /* channels the record was made for */
	int32_t  offset[CAL_CH];       /* CIC units, subtracted before the gain */
	uint32_t gain[CAL_CH];         /* Q2.30 */
	uint32_t trim[CAL_CH];         /* Q2.30, corner compensation */
	double   zero;                 /* RESULT at no load */
	double   kg_per_count;         /* 0 until spanned */
	int32_t  stab_band;            /* RESULT counts */
	uint32_t stab_count;           /* results at 600 Hz */
	int32_t  wim_enter, wim_exit;  /* RESULT counts above zero; INT32_MAX disables */
	uint32_t wim_level;            /* Q0.16: a sample counts at or above this share of the load's peak */
	uint32_t decim;                /* RESULT rate = 600 Hz / decim */
	double   fir_fc;               /* FIR low-pass cutoff, Hz */
	double   tare;                 /* RESULT counts above zero, subtracted from the reading */
	uint32_t sum;                 /* checksum of everything above */
} cal_t;

uint32_t q30(double k);                       /* saturates to [-2, 2) */
double   from_q30(uint32_t v);
void     cal_defaults(cal_t *c, int n_ch);
uint32_t cal_checksum(const cal_t *c);
int      cal_valid(const cal_t *c);

/* Hamming-windowed sinc, taps rounded to integers summing to 2^20 (coeff/fir64.py). 0, or -1 if a tap
 * leaves the 18-bit coefficient range. */
int fir_lowpass(double fc, double fs, int32_t taps[CAL_TAPS]);

/* Corner trims from m test positions: r[i][ch] is channel ch's response (gain and offset applied, no-load
 * baseline removed) with the test weight at position i. Finds t so that sum_ch r[i][ch] t[ch] is the same
 * for every position, keeping the mean sum, over n channels. With fewer positions than channels the trims
 * are pulled toward 1. Returns the common sum, or 0 when the positions do not determine the trims. */
double solve_trims(int m, int n, const double r[][CAL_CH], double t[CAL_CH]);

#endif
