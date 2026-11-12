"""sat_sum: exact sum of 8 channels per frame, overload when any channel was clipped.

    python tb/sat_sum/test_sat_sum.py
"""
import random
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


@cocotb.test()
async def frames(dut):
    Clock(dut.clk, 20, unit="ns").start()
    rnd = random.Random(2)
    dut.rst.value, dut.s_valid.value = 1, 0
    await ClockCycles(dut.clk, 2)
    dut.rst.value = 0

    expect, got = [], []
    beats = []
    for f in range(40):
        xs = [rnd.choice([2**31 - 1, -(2**31), rnd.randint(-2**31, 2**31 - 1)]) for _ in range(8)]
        sats = [rnd.random() < 0.03 for _ in range(8)]
        expect.append((sum(xs), int(any(sats))))
        beats += [(x, s, k == 7) for k, (x, s) in enumerate(zip(xs, sats))]
    i = 0
    while len(got) < len(expect):
        await RisingEdge(dut.clk)
        if int(dut.m_valid.value):
            got.append((dut.m_data.value.to_signed(), int(dut.m_overload.value)))
        if i < len(beats) and rnd.random() < 0.6:
            x, s, last = beats[i]
            dut.s_valid.value, dut.s_data.value, dut.s_sat.value, dut.s_last.value = 1, x, s, last
            i += 1
        else:
            dut.s_valid.value = 0
    assert got == expect
    assert max(abs(e[0]) for e in expect) > 2**33       # exercised beyond 32 bits


def test_sat_sum():
    from runner import run
    run("sat_sum", ["rtl/sat_sum.sv"], __file__)


if __name__ == "__main__":
    test_sat_sum()
