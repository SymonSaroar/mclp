"""raw_capture: record format, continuous mode with FIFO-full skips, one-shot, threshold trigger.

    python tb/raw_capture/test_raw_capture.py
"""
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

M32 = 0xFFFF_FFFF


async def setup(dut, mode, frames=0, threshold=0):
    Clock(dut.clk, 20, unit="ns").start()
    for s in ("rst", "enable", "sw_trigger", "sum_valid", "s_valid", "full"):
        getattr(dut, s).value = 0
    dut.mode.value, dut.frames.value, dut.threshold.value, dut.tap.value = mode, frames, threshold, 2
    dut.sum.value = dut.s_ch.value = dut.s_data.value = 0
    dut.ts.value, dut.faults.value = 0x1234_5678_9ABC, 0x81
    dut.rst.value = 1
    await ClockCycles(dut.clk, 2)
    dut.rst.value = 0
    dut.enable.value = 1


async def run_frames(dut, n, full_at=(), sums=None):
    """Send n frames (sample = frame * 16 + ch, one beat every 2 cycles); collect output words."""
    words = []

    async def collect():
        while True:
            await RisingEdge(dut.clk)
            if int(dut.m_valid.value):
                words.append((int(dut.m_data.value), int(dut.m_last.value)))

    task = cocotb.start_soon(collect())
    for f in range(n):
        dut.full.value = f in full_at
        if sums:
            await RisingEdge(dut.clk)
            dut.sum_valid.value, dut.sum.value = 1, sums[f]
            await RisingEdge(dut.clk)
            dut.sum_valid.value = 0
        for ch in range(8):
            await RisingEdge(dut.clk)
            dut.s_valid.value, dut.s_ch.value, dut.s_data.value = 1, ch, (f * 16 + ch) & M32
            await RisingEdge(dut.clk)
            dut.s_valid.value = 0
    await ClockCycles(dut.clk, 4)
    task.cancel()
    return words


def record(f):
    s = [f * 16 + ch for ch in range(8)]
    return [((0x1234_5678_9ABC << 16) | (2 << 14) | 0x81, 0)] + \
        [((s[i + 1] << 32) | s[i], int(i == 6)) for i in range(0, 8, 2)]


@cocotb.test()
async def continuous_with_skips(dut):
    await setup(dut, mode=0)
    words = await run_frames(dut, 5, full_at={2})
    assert words == record(0) + record(1) + record(3) + record(4)
    assert int(dut.active.value) == 1


@cocotb.test()
async def one_shot(dut):
    await setup(dut, mode=1, frames=2)
    assert await run_frames(dut, 2) == []
    assert int(dut.active.value) == 0
    dut.sw_trigger.value = 1
    await RisingEdge(dut.clk)
    dut.sw_trigger.value = 0
    await RisingEdge(dut.clk)
    assert int(dut.active.value) == 1
    words = await run_frames(dut, 4)
    assert words == record(0) + record(1)
    assert int(dut.active.value) == 0


@cocotb.test()
async def threshold_trigger(dut):
    await setup(dut, mode=2, frames=2, threshold=1000)
    dut.sw_trigger.value = 1
    await RisingEdge(dut.clk)
    dut.sw_trigger.value = 0
    words = await run_frames(dut, 6, sums=[0, 500, 999, 1001, 0, 0])
    assert words == record(3) + record(4)


def test_raw_capture():
    from runner import run
    run("raw_capture", ["rtl/raw_capture.sv"], __file__)


if __name__ == "__main__":
    test_raw_capture()
