"""wim_estimator: two axles crossing, the second too short to pass the settle time.

    python tb/wim_estimator/test_wim_estimator.py
"""
import random
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

ENTER, EXIT, SETTLE = 100_000, 80_000, 10


def model(xs):
    st, n, acc, out = "idle", 0, 0, []
    for x in xs:
        if st == "idle":
            if x > ENTER:
                st, n = "settle", 0
        elif st == "settle":
            if x < EXIT:
                st = "idle"
            elif n + 1 >= SETTLE:
                st, n, acc = "acc", 0, 0
            else:
                n += 1
        else:
            if x < EXIT:
                out.append((acc, n))
                st = "idle"
            else:
                acc, n = acc + x, n + 1
    return out


@cocotb.test()
async def axles(dut):
    Clock(dut.clk, 20, unit="ns").start()
    rnd = random.Random(5)
    axle1 = [20_000 * i for i in range(8)] + [1_500_000 + rnd.randint(-20_000, 20_000) for _ in range(60)] + [60_000 - 20_000 * i for i in range(4)]
    axle2 = [400_000] * 6                                  # leaves during the settle time
    xs = [0] * 10 + axle1 + [0] * 10 + axle2 + [0] * 10
    dut.rst.value, dut.s_valid.value = 1, 0
    dut.enter.value, dut.exit_th.value, dut.settle.value = ENTER, EXIT, SETTLE
    await ClockCycles(dut.clk, 2)
    dut.rst.value = 0

    got = []
    for x in xs:
        await RisingEdge(dut.clk)
        if int(dut.stb.value):
            got.append((dut.sum.value.to_signed(), int(dut.count.value)))
        dut.s_valid.value, dut.s_data.value = 1, x
    await ClockCycles(dut.clk, 3)
    exp = model(xs)
    assert got == exp and len(exp) == 1
    assert abs(exp[0][0] / exp[0][1] - 1_500_000) < 10_000


def test_wim_estimator():
    from runner import run
    run("wim_estimator", ["rtl/wim_estimator.sv"], __file__)


if __name__ == "__main__":
    test_wim_estimator()
