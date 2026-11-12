"""rtl/mclp_fir.sv against exact convolution: the initial taps from coeff/fir64.mem (impulse response), random
full-range data, a reloaded set that takes effect only at CONFIG, a CONFIG without a reload, extreme taps
and data (the full 60-bit output), and a CONFIG arriving during a pass.

    python tb/mclp_fir/test_mclp_fir.py

With MCLP_FIR_GOLDEN=<file> it replays that file instead: events written by AMD's FIR Compiler bit-accurate C
model, with the model's outputs as the expected values.
"""
import os
import random
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
ROOT = Path(__file__).resolve().parents[2]
N = 64


def mem_taps():
    return [(v ^ 0x8000_0000) - 0x8000_0000 for v in (int(s, 16) for s in (ROOT / "coeff/fir64.mem").read_text().split())]


def scenario():
    """Events ("D", x, y), ("R", taps), ("C",) with y from exact convolution, staged reload until CONFIG."""
    rnd = random.Random(2)
    h, staged, hist, ev = mem_taps(), None, [0] * N, []

    def d(x):
        hist.insert(0, x)
        del hist[N:]
        ev.append(("D", x, sum(a * b for a, b in zip(h, hist))))

    def r(taps):
        nonlocal staged
        staged = list(taps)
        ev.append(("R", staged))

    def c():
        nonlocal h, staged
        if staged:
            h, staged = staged, None
        ev.append(("C",))

    assert sum(h) == 2**20                          # unity DC gain after mclp_dsp's >> 20
    d(1)
    for _ in range(N + 4):
        d(0)
    for _ in range(150):
        d(rnd.randint(-2**35, 2**35 - 1))
    c()                                             # CONFIG without a reload changes nothing
    for _ in range(10):
        d(rnd.randint(-2**35, 2**35 - 1))
    r([rnd.randint(-2**17, 2**17 - 1) for _ in range(N)])
    for _ in range(10):                             # staged: old set until CONFIG
        d(rnd.randint(-2**35, 2**35 - 1))
    c()
    for _ in range(150):
        d(rnd.randint(-2**35, 2**35 - 1))
    r([-2**17] * N)                                 # worst case: |y| = 64 * 2^17 * 2^35 = 2^58
    c()
    for i in range(80):
        d(-2**35 if i % 3 else 2**35 - 1)
    r(mem_taps())
    c()
    for _ in range(20):
        d(rnd.randint(-2**23, 2**23 - 1) * 256)
    return ev


def golden(path):
    ev = []
    for line in open(path):
        f = line.split()
        if f[0] == "R":
            ev.append(("R", [int(v) for v in f[1:]]))
        elif f[0] == "C":
            ev.append(("C",))
        else:
            ev.append(("D", int(f[1]), int(f[2])))
    return ev


@cocotb.test()
async def replay(dut):
    Clock(dut.aclk, 20, unit="ns").start()
    src = os.environ.get("MCLP_FIR_GOLDEN")
    events = golden(src) if src else scenario()
    got = []

    async def sink():
        while True:
            await RisingEdge(dut.aclk)
            await ReadOnly()
            if int(dut.m_axis_data_tvalid.value):
                got.append(dut.m_axis_data_tdata.value.to_signed())
            assert not int(dut.event_s_reload_tlast_missing.value)
            assert not int(dut.event_s_reload_tlast_unexpected.value)

    async def beat(valid, ready, **data):
        """One AXI4-Stream transfer: hold tvalid until tready."""
        for k, v in data.items():
            getattr(dut, k).value = v
        getattr(dut, valid).value = 1
        while True:
            await RisingEdge(dut.aclk)
            if int(getattr(dut, ready).value):
                break
        getattr(dut, valid).value = 0

    for s in ("s_axis_data_tvalid", "s_axis_config_tvalid", "s_axis_reload_tvalid", "s_axis_reload_tlast"):
        getattr(dut, s).value = 0
    dut.s_axis_config_tdata.value = 0
    dut.aresetn.value = 0
    await ClockCycles(dut.aclk, 3)
    dut.aresetn.value = 1
    cocotb.start_soon(sink())

    expect = []
    for e in events:
        if e[0] == "D":
            expect.append(e[2])
            await beat("s_axis_data_tvalid", "s_axis_data_tready", s_axis_data_tdata=e[1] & (2**40 - 1))
        elif e[0] == "R":
            for i, c in enumerate(e[1]):
                await beat("s_axis_reload_tvalid", "s_axis_reload_tready",
                           s_axis_reload_tdata=c & 0xFF_FFFF, s_axis_reload_tlast=int(i == N - 1))
            dut.s_axis_reload_tlast.value = 0
        else:
            await beat("s_axis_config_tvalid", "s_axis_config_tready")
    await ClockCycles(dut.aclk, N + 10)
    assert len(got) == len(expect), f"{len(got)} outputs for {len(expect)} samples"
    bad = [i for i, (a, b) in enumerate(zip(got, expect)) if a != b]
    assert not bad, f"{len(bad)} mismatches, first at sample {bad[0]}: {got[bad[0]]} != {expect[bad[0]]}"
    dut._log.info(f"{len(got)} outputs match {'the C model' if src else 'exact convolution'}")


def test_mclp_fir():
    from runner import run
    run("mclp_fir", ["rtl/mclp_fir.sv"], __file__, files=["coeff/fir64.mem"])


if __name__ == "__main__":
    test_mclp_fir()
