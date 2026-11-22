"""wim_estimator against a Python model, with a 16-sample buffer so that long loads go through eviction: an axle
with ramps and bounce, a one-sample load, an early peak, a late peak, a dip between EXIT and ENTER, then random
loads at several levels.

    python tb/wim_estimator/test_wim_estimator.py
"""
import random
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

ENTER, EXIT, DEPTH = 100_000, 80_000, 16
GAP = DEPTH + 4                                            # clocks between samples, enough for the read-back


def model(xs, level, enter=ENTER, exit_th=EXIT, depth=DEPTH):
    out, buf = [], None
    for x in xs:
        if buf is None:
            if x > enter:
                buf, peak, acc, n = [x], x, 0, 0
        elif x < exit_th:
            for b in buf:
                if b * 65536 >= peak * level:
                    acc, n = acc + b, n + 1
            out.append((acc, n))
            buf = None
        else:
            peak = max(peak, x)
            if len(buf) == depth:
                b = buf.pop(0)
                if b * 65536 >= peak * level:
                    acc, n = acc + b, n + 1
            buf.append(x)
    return out


async def run_stream(dut, xs, level):
    got = []
    dut.level.value = level
    for x in xs:
        dut.s_valid.value, dut.s_data.value = 1, x
        for c in range(GAP):
            await RisingEdge(dut.clk)
            if c == 0:
                dut.s_valid.value = 0
            if int(dut.stb.value):
                got.append((dut.sum.value.to_signed(), int(dut.count.value)))
    return got


@cocotb.test()
async def loads(dut):
    Clock(dut.clk, 20, unit="ns").start()
    rnd = random.Random(5)
    dut.rst.value, dut.s_valid.value, dut.s_data.value = 1, 0, 0
    dut.enter.value, dut.exit_th.value, dut.level.value = ENTER, EXIT, 0
    await ClockCycles(dut.clk, 2)
    dut.rst.value = 0

    axle = ([150_000 * i for i in range(1, 11)] + [1_500_000 + 20_000 * (i % 7 - 3) + rnd.randint(-20_000, 20_000)
            for i in range(40)] + [1_200_000 - 200_000 * i for i in range(6)])
    early = [2_000_000] + [1_000_000] * 30                    # evicted with the early peak, the rest with it too
    late = [500_000] * 20 + [3_000_000] * 3                    # early samples evicted before the peak arrives
    dip = [500_000, 90_000, 85_000, 600_000, 610_000]          # stays above EXIT
    xs = [0] * 3 + axle + [0] * 3 + [400_000, 0] + early + [0] + late + [0] + dip + [0, 0]
    level = 0xEE14                                             # 0.93
    exp = model(xs, level)
    assert await run_stream(dut, xs, level) == exp
    assert len(exp) == 5 and exp[1] == (400_000, 1)
    assert abs(exp[0][0] / exp[0][1] - 1_500_000) < 60_000

    for level in (0, 0x8000, 0xEE14, 0xFFFF):
        xs = []
        for _ in range(75):
            xs += [rnd.randint(-50_000, 50_000) for _ in range(rnd.randint(1, 3))]
            xs += [rnd.choice([rnd.randint(EXIT, 2_000_000), rnd.randint(ENTER + 1, 300_000)])]
            xs += [rnd.randint(EXIT, 2_000_000) for _ in range(rnd.randint(0, 40))]
        xs += [0]
        assert await run_stream(dut, xs, level) == model(xs, level), level


def test_wim_estimator():
    from runner import run
    run("wim_estimator", ["rtl/wim_estimator.sv"], __file__, parameters={"DEPTH": DEPTH})


if __name__ == "__main__":
    test_wim_estimator()
