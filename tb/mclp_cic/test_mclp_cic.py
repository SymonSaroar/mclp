"""rtl/mclp_cic.sv against a direct-form reference: impulse response of three 8-sample boxcars (22 taps,
DC gain 512), decimated by 8, LSB truncated. Random data on six channels, full scale of both signs on two,
random gaps between frames.

    python tb/mclp_cic/test_mclp_cic.py
"""
import random
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

R, CH, FRAMES = 8, 8, 200


def conv(a, b):
    y = [0] * (len(a) + len(b) - 1)
    for i, p in enumerate(a):
        for j, q in enumerate(b):
            y[i + j] += p * q
    return y


H = conv(conv([1] * R, [1] * R), [1] * R)


def reference(x):
    return [sum(H[k] * x[n - k] for k in range(len(H)) if n >= k) >> 1 for n in range(R - 1, len(x), R)]


@cocotb.test()
async def random_frames(dut):
    Clock(dut.aclk, 20, unit="ns").start()
    rnd = random.Random(1)
    x = [[rnd.randint(-2**23, 2**23 - 1) for _ in range(FRAMES)] for _ in range(CH)]
    x[0] = [2**23 - 1] * FRAMES                     # full scale: 512 x needs all 33 bits
    x[1] = [-2**23] * FRAMES
    got = [[] for _ in range(CH)]

    async def sink():
        while True:
            await RisingEdge(dut.aclk)
            if int(dut.m_axis_data_tvalid.value):
                ch = int(dut.m_axis_data_tuser.value)
                assert int(dut.m_axis_data_tlast.value) == (ch == CH - 1)
                got[ch].append(dut.m_axis_data_tdata.value.to_signed())
            assert not int(dut.event_tlast_unexpected.value) and not int(dut.event_tlast_missing.value)

    dut.aresetn.value, dut.s_axis_data_tvalid.value, dut.s_axis_data_tlast.value = 0, 0, 0
    await ClockCycles(dut.aclk, 3)
    dut.aresetn.value = 1
    cocotb.start_soon(sink())
    for f in range(FRAMES):
        for ch in range(CH):
            dut.s_axis_data_tvalid.value = 1
            dut.s_axis_data_tdata.value = x[ch][f] & 0xFF_FFFF
            dut.s_axis_data_tlast.value = ch == CH - 1
            await RisingEdge(dut.aclk)
        dut.s_axis_data_tvalid.value = 0
        await ClockCycles(dut.aclk, rnd.randint(0, 3))
    await ClockCycles(dut.aclk, 5)
    for ch in range(CH):
        assert got[ch] == reference(x[ch]), f"channel {ch}"
    assert got[0][-1] == 256 * (2**23 - 1) and got[1][-1] == -2**31


def test_mclp_cic():
    from runner import run
    run("mclp_cic", ["rtl/mclp_cic.sv"], __file__)


if __name__ == "__main__":
    test_mclp_cic()
