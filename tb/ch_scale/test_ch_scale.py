"""ch_scale against y = sat32(((x - offset) * k) >> 30), including clipping and the sat flag.

    python tb/ch_scale/test_ch_scale.py
"""
import random
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

MAX, MIN = 2**31 - 1, -(2**31)


def model(x, off, k):
    y = ((x - off) * k) >> 30
    return min(max(y, MIN), MAX), not MIN <= y <= MAX


@cocotb.test()
async def random_beats(dut):
    Clock(dut.clk, 20, unit="ns").start()
    rnd = random.Random(1)
    K = [rnd.randint(-2**31, 2**31 - 1) for _ in range(8)]
    K[0], K[1] = 0x4000_0000, 0x7FFF_FFFF            # unity, almost 2.0 (clips large inputs)
    OFF = [rnd.randint(-2**30, 2**30) for _ in range(8)]
    dut.rst.value, dut.s_valid.value = 1, 0
    await ClockCycles(dut.clk, 2)
    dut.rst.value = 0

    sent, got = [], []
    dut.s_ch.value = 0
    for i in range(600):
        await RisingEdge(dut.clk)
        ch_rd = int(dut.coef_ch.value)                     # coefficient RAM: data one cycle after the address
        dut.k.value, dut.offset.value = K[ch_rd], OFF[ch_rd]
        if int(dut.m_valid.value):
            got.append((int(dut.m_ch.value), int(dut.m_last.value), dut.m_data.value.to_signed(), int(dut.m_sat.value)))
        if i < 560 and rnd.random() < 0.7:
            ch, x, sat_in = len(sent) % 8, rnd.randint(-2**31, 2**31 - 1), rnd.random() < 0.05
            y, clipped = model(x, OFF[ch], K[ch])
            sent.append((ch, ch == 7, y, int(sat_in or clipped)))
            dut.s_valid.value, dut.s_ch.value, dut.s_last.value, dut.s_sat.value = 1, ch, ch == 7, sat_in
            dut.s_data.value = x
        else:
            dut.s_valid.value = 0
    assert got == sent
    assert any(s[3] for s in sent) and any(not s[3] for s in sent)


def test_ch_scale():
    from runner import run
    run("ch_scale", ["rtl/ch_scale.sv"], __file__)


if __name__ == "__main__":
    test_ch_scale()
