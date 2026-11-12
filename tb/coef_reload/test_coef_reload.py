"""coef_reload: 64 RAM words to the reload channel under random back-pressure, then one CONFIG transfer.

    python tb/coef_reload/test_coef_reload.py
"""
import random
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


@cocotb.test()
async def reload_sequence(dut):
    Clock(dut.clk, 20, unit="ns").start()
    rnd = random.Random(3)
    mem = [rnd.randint(-2**17, 2**17 - 1) & 0xFFFF_FFFF for _ in range(64)]
    dut.rst.value, dut.start.value, dut.reload_ready.value, dut.config_ready.value = 1, 0, 0, 0
    await ClockCycles(dut.clk, 2)
    dut.rst.value = 0

    async def ram():                                       # registered read, one cycle latency
        while True:
            await RisingEdge(dut.clk)
            dut.q.value = mem[int(dut.addr.value)]

    cocotb.start_soon(ram())
    await RisingEdge(dut.clk)
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0

    words, lasts, configs = [], [], 0
    for _ in range(2000):
        await RisingEdge(dut.clk)
        if int(dut.reload_valid.value) and int(dut.reload_ready.value):
            words.append(int(dut.reload_data.value))
            lasts.append(int(dut.reload_last.value))
        if int(dut.config_valid.value) and int(dut.config_ready.value):
            assert len(words) == 64, "CONFIG only after the full packet"
            configs += 1
        if configs and not int(dut.busy.value):
            break
        dut.reload_ready.value = rnd.random() < 0.5
        dut.config_ready.value = rnd.random() < 0.5
    assert words == [m & 0xFF_FFFF for m in mem]
    assert lasts == [0] * 63 + [1]
    assert configs == 1 and not int(dut.busy.value)


def test_coef_reload():
    from runner import run
    run("coef_reload", ["rtl/coef_reload.sv"], __file__)


if __name__ == "__main__":
    test_coef_reload()
