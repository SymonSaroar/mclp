"""stability_detect against a Python model on a settling step with noise and a disturbance.

    python tb/stability_detect/test_stability_detect.py
"""
import random
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

BAND, COUNT = 1000, 20


def model(xs):
    ref, n, stable, out = 0, 0, 0, []
    for x in xs:
        if abs(x - ref) > BAND:
            ref, n, stable = x, 0, 0
        else:
            stable = int(n + 1 >= COUNT)
            n = min(n + 1, COUNT)
        out.append(stable)
    return out


@cocotb.test()
async def settle_and_disturb(dut):
    Clock(dut.clk, 20, unit="ns").start()
    rnd = random.Random(4)
    xs = [int(500_000 * (1 - 0.8**i)) + rnd.randint(-300, 300) for i in range(120)]
    xs[90] += 5000                                         # a knock on the platform
    dut.rst.value, dut.s_valid.value, dut.band.value, dut.count.value = 1, 0, BAND, COUNT
    await ClockCycles(dut.clk, 2)
    dut.rst.value = 0

    got = []
    for x in xs:
        await RisingEdge(dut.clk)
        dut.s_valid.value, dut.s_data.value = 1, x
        await RisingEdge(dut.clk)
        dut.s_valid.value = 0
        await RisingEdge(dut.clk)
        got.append(int(dut.stable.value))
    exp = model(xs)
    assert got == exp
    assert 0 < sum(exp) < len(exp) and exp[91] == 0


def test_stability_detect():
    from runner import run
    run("stability_detect", ["rtl/stability_detect.sv"], __file__)


if __name__ == "__main__":
    test_stability_detect()
