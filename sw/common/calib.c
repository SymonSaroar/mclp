#include <math.h>
#include <stddef.h>
#include <string.h>

#include "calib.h"

uint32_t q30(double k)
{
	double v = k * 1073741824.0;
	if (v >= 2147483647.0)
		return 0x7FFFFFFFu;
	if (v <= -2147483648.0)
		return 0x80000000u;
	return (uint32_t)(int32_t)lround(v);
}

double from_q30(uint32_t v)
{
	return (double)(int32_t)v / 1073741824.0;
}

void cal_defaults(cal_t *c)
{
	memset(c, 0, sizeof *c);
	c->magic   = CAL_MAGIC;
	c->version = CAL_VERSION;
	for (int ch = 0; ch < CAL_CH; ch++) {
		c->gain[ch] = q30(GAIN_DEFAULT);
		c->trim[ch] = q30(1.0);
	}
	c->stab_band  = 4096;
	c->stab_count = 60;
	c->wim_enter  = 0x7FFFFFFF;
	c->wim_exit   = 0x7FFFFFFF;
	c->wim_settle = 60;
	c->decim      = 12;
	c->fir_fc     = 12.0;
	c->sum        = cal_checksum(c);
}

uint32_t cal_checksum(const cal_t *c)
{
	const uint8_t *p = (const uint8_t *)c;
	uint32_t h = 2166136261u;                  /* FNV-1a */
	for (size_t i = 0; i < offsetof(cal_t, sum); i++)
		h = (h ^ p[i]) * 16777619u;
	return h;
}

int cal_valid(const cal_t *c)
{
	return c->magic == CAL_MAGIC && c->version == CAL_VERSION && c->sum == cal_checksum(c);
}

int fir_lowpass(double fc, double fs, int32_t q[CAL_TAPS])
{
	const double pi = 3.14159265358979323846;
	double h[CAL_TAPS], sum = 0.0, m = (CAL_TAPS - 1) / 2.0;
	int64_t qsum = 0;

	for (int n = 0; n < CAL_TAPS; n++) {
		double x = 2.0 * fc / fs * (n - m);
		double sinc = x == 0.0 ? 1.0 : sin(pi * x) / (pi * x);
		h[n] = sinc * (0.54 - 0.46 * cos(2.0 * pi * n / (CAL_TAPS - 1)));
		sum += h[n];
	}
	for (int n = 0; n < CAL_TAPS; n++) {
		q[n] = (int32_t)nearbyint(h[n] * 1048576.0 / sum);   /* ties to even, as Python round() */
		qsum += q[n];
	}
	q[CAL_TAPS / 2] += (int32_t)(1048576 - qsum);            /* rounding residue keeps the DC gain exact */
	for (int n = 0; n < CAL_TAPS; n++)
		if (q[n] >= (1 << 17) || q[n] < -(1 << 17))
			return -1;
	return 0;
}

double solve_trims(int m, const double r[][CAL_CH], double t[CAL_CH])
{
	enum { N = CAL_CH };
	double a[N][N + 1], s = 0.0, tr = 0.0;

	if (m < 1)
		return 0.0;
	for (int i = 0; i < m; i++)
		for (int ch = 0; ch < N; ch++)
			s += r[i][ch];
	s /= m;

	/* normal equations (R'R + lambda I) t = R' s 1 + lambda 1 */
	memset(a, 0, sizeof a);
	for (int i = 0; i < m; i++)
		for (int j = 0; j < N; j++) {
			for (int k = 0; k < N; k++)
				a[j][k] += r[i][j] * r[i][k];
			a[j][N] += r[i][j] * s;
		}
	for (int j = 0; j < N; j++)
		tr += a[j][j];
	if (!(tr > 0.0))
		return 0.0;
	double lambda = (m < N ? 1e-3 : 1e-9) * tr / N;
	for (int j = 0; j < N; j++) {
		a[j][j] += lambda;
		a[j][N] += lambda;
	}

	/* Gaussian elimination with partial pivoting */
	for (int c = 0; c < N; c++) {
		int p = c;
		for (int i = c + 1; i < N; i++)
			if (fabs(a[i][c]) > fabs(a[p][c]))
				p = i;
		if (fabs(a[p][c]) < 1e-12 * tr)
			return 0.0;
		if (p != c)
			for (int k = 0; k <= N; k++) {
				double tmp = a[c][k];
				a[c][k] = a[p][k];
				a[p][k] = tmp;
			}
		for (int i = c + 1; i < N; i++) {
			double f = a[i][c] / a[c][c];
			for (int k = c; k <= N; k++)
				a[i][k] -= f * a[c][k];
		}
	}
	for (int c = N - 1; c >= 0; c--) {
		double v = a[c][N];
		for (int k = c + 1; k < N; k++)
			v -= a[c][k] * t[k];
		t[c] = v / a[c][c];
	}
	return s;
}
