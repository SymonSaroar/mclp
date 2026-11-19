/*
 * Host check of sw/common/calib.c: FIR design against coeff/fir64.mem, Q2.30 conversion, the corner
 * trim solver on a simulated platform, and the calibration checksum. Run from the repository root:
 *
 *     gcc -O2 -Isw/common -o build/test_calib sw/common/test/test_calib.c sw/common/calib.c -lm
 *     build/test_calib
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#include "calib.h"

static int fails;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static void test_fir(void)
{
	int32_t q[CAL_TAPS];
	unsigned w;
	FILE *f = fopen("coeff/fir64.mem", "r");
	CHECK(f != NULL, "coeff/fir64.mem not found (run from the repository root)");
	if (!f)
		return;
	CHECK(fir_lowpass(12.0, 600.0, q) == 0, "default design out of range");
	long sum = 0;
	for (int n = 0; n < CAL_TAPS && fscanf(f, "%x", &w) == 1; n++) {
		CHECK(q[n] == (int32_t)w, "tap %d: %d, fir64.mem %d", n, q[n], (int32_t)w);
		sum += q[n];
	}
	fclose(f);
	CHECK(sum == 1 << 20, "taps sum to %ld", sum);
	CHECK(fir_lowpass(0.5, 600.0, q) == 0 && fir_lowpass(35.0, 600.0, q) == 0, "0.5 Hz or 35 Hz design");
	/* peak tap ~ 2^20 * 2 fc / fs must stay under 2^17: about 37 Hz at 600 Hz */
	CHECK(fir_lowpass(40.0, 600.0, q) == -1, "40 Hz must overflow the 18-bit taps");
}

static void test_q30(void)
{
	CHECK(q30(1.0) == 0x40000000u && q30(0.125) == 0x08000000u && q30(-0.5) == 0xE0000000u, "q30 values");
	CHECK(q30(2.5) == 0x7FFFFFFFu && q30(-3.0) == 0x80000000u, "q30 saturation");
	CHECK(fabs(from_q30(q30(0.9876543)) - 0.9876543) < 1e-9, "q30 round trip");
}

/* Platform of n cells: test weight W at position i puts share[i][ch] of it on cell ch; cell ch reads sens[ch]
 * per kg. */
static void test_trims(int n)
{
	static double r[CAL_CH][CAL_CH], z[2][CAL_CH];
	double sens[CAL_CH], t[CAL_CH], W = 50.0;
	srand(7);
	for (int ch = 0; ch < n; ch++)
		sens[ch] = 1000.0 * (0.9 + 0.2 * rand() / RAND_MAX);
	for (int i = 0; i < n; i++) {
		double share[CAL_CH], tot = 0.0;
		for (int ch = 0; ch < n; ch++) {
			int d = abs(ch - i) < n - abs(ch - i) ? abs(ch - i) : n - abs(ch - i);   /* ring distance */
			share[ch] = d == 0 ? 6.0 : d == 1 ? 1.5 : 0.25;
			tot += share[ch];
		}
		for (int ch = 0; ch < n; ch++)
			r[i][ch] = W * share[ch] / tot * sens[ch];
	}

	double s = solve_trims(n, n, r, t);
	CHECK(s > 0.0, "%d positions: no solution", n);
	for (int i = 0; i < n; i++) {
		double y = 0.0;
		for (int ch = 0; ch < n; ch++)
			y += r[i][ch] * t[ch];
		CHECK(fabs(y / s - 1.0) < 1e-6, "%d channels: position %d reads %.9f of the common sum", n, i, y / s);
	}
	for (int ch = 1; ch < n; ch++)                             /* trims undo the sensitivity spread */
		CHECK(fabs(t[ch] * sens[ch] / (t[0] * sens[0]) - 1.0) < 1e-6, "%d channels: trim %d", n, ch);

	double s4 = solve_trims(4, n, r, t);                        /* fewer positions: finite, near 1 */
	CHECK(s4 > 0.0, "%d channels, 4 positions: no solution", n);
	for (int ch = 0; ch < n; ch++)
		CHECK(t[ch] > 0.5 && t[ch] < 1.5, "%d channels, 4 positions: trim %d = %f", n, ch, t[ch]);

	CHECK(solve_trims(2, n, z, t) == 0.0, "all-zero responses must be rejected");
}

static void test_cal(void)
{
	cal_t c;
	cal_defaults(&c, 8);
	CHECK(cal_valid(&c) && c.n_ch == 8, "defaults invalid");
	c.trim[3] = q30(1.01);
	CHECK(!cal_valid(&c), "checksum missed a change");
	c.sum = cal_checksum(&c);
	CHECK(cal_valid(&c), "checksum after update");
}

int main(void)
{
	test_fir();
	test_q30();
	test_trims(8);
	test_trims(MAX_CH);
	test_cal();
	printf(fails ? "test_calib: %d FAILED\n" : "test_calib: all passed\n", fails);
	return fails != 0;
}
