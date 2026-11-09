"""64-tap low-pass for the summed weight: Hamming-windowed sinc, fs = 600 Hz, fc = 12 Hz.

Writes fir64.mem, the $readmemh image of the coefficient RAMs in mclp_registers and mclp_fir: 32-bit
words, coefficient order. Taps sum to 2**SHIFT for unity DC gain; mclp_dsp shifts the FIR output
right by SHIFT.

    python coeff/fir64.py
"""
import math
from pathlib import Path

TAPS, FS, FC, SHIFT = 64, 600.0, 12.0, 20

def taps():
    m = (TAPS - 1) / 2
    h = []
    for n in range(TAPS):
        x = 2 * FC / FS * (n - m)
        sinc = 1.0 if x == 0 else math.sin(math.pi * x) / (math.pi * x)
        h.append(sinc * (0.54 - 0.46 * math.cos(2 * math.pi * n / (TAPS - 1))))
    q = [round(v * 2**SHIFT / sum(h)) for v in h]
    q[TAPS // 2] += 2**SHIFT - sum(q)  # Rounding residue on one tap keeps DC gain exact
    return q

if __name__ == "__main__":
    q = taps()
    assert sum(q) == 2**SHIFT and max(map(abs, q)) < 2**17, "taps must fit 18-bit signed"
    here = Path(__file__).parent
    (here / "fir64.mem").write_text(
        "".join(f"{v & 0xFFFFFFFF:08x}\n" for v in q))
    print(f"{TAPS} taps, sum 2^{SHIFT}, peak {max(q)}")
