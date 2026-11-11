"""afe_frontend against 8 AD7190 models: init list, streaming, loopback BIST, burnout and NOREF faults.

MCLK runs 4x fast (19.66 MHz) to shorten the run; frames come every 52 us.

    python tb/afe_frontend/test_afe_frontend.py
"""
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, with_timeout

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

SAMPLES = [-300_000 + 100_003 * k for k in range(8)]
MCLK_NS = 50.862                      # 19.66 MHz, 4x the AD7190 nominal
FRAME_CYCLES = 1024 * MCLK_NS / 50       # clk (20 MHz) cycles per conversion at FS = 1


def s24(v):
    return v - (1 << 24) if v & 0x80_0000 else v


def beat(d):
    return {"ts": d >> 32, "flags": (d >> 27) & 0x1F, "ch": (d >> 24) & 7, "data": s24(d & 0xFF_FFFF)}


async def frames(dut, n):
    out = []
    while len(out) < n:
        f = []
        while True:
            await RisingEdge(dut.clk)
            if int(dut.m_valid.value) and int(dut.m_ready.value):
                f.append(beat(int(dut.m_data.value)))
                if int(dut.m_last.value):
                    break
        out.append(f)
    return out


async def setup(dut):
    Clock(dut.clk, 50, unit="ns").start()
    Clock(dut.mclk, MCLK_NS, unit="ns").start()
    dut.rst.value, dut.enable.value, dut.loopback.value, dut.seq_start.value = 1, 0, 0, 0
    dut.loopback_cfg.value, dut.loopback_value.value = 1000 << 16, 0x01_2345
    dut.ram_we.value = dut.ram_waddr.value = dut.ram_wdata.value = 0
    dut.samples.value = sum((s & 0xFF_FFFF) << (24 * k) for k, s in enumerate(SAMPLES))
    dut.open_wire.value = dut.no_ref.value = 0
    dut.m_ready.value = 1
    await ClockCycles(dut.clk, 4)
    dut.rst.value = 0


async def load(dut, words):
    for a, w in enumerate(words):
        await RisingEdge(dut.clk)
        dut.ram_we.value, dut.ram_waddr.value, dut.ram_wdata.value = 1, a, w
    await RisingEdge(dut.clk)
    dut.ram_we.value = 0


async def restart(dut):
    await RisingEdge(dut.clk)
    dut.seq_start.value = 1
    await RisingEdge(dut.clk)
    dut.seq_start.value = 0


@cocotb.test()
async def init_and_stream(dut):
    await setup(dut)
    dut.enable.value = 1                                   # rising edge starts the init list
    await ClockCycles(dut.clk, 10)
    assert int(dut.seq_busy.value) == 1
    got = await with_timeout(frames(dut, 3), 3, "ms")
    assert int(dut.seq_busy.value) == 0                    # list done, streaming

    resp = int(dut.seq_resp.value)
    assert all((resp >> (32 * k)) & 0xFF == 0x04 for k in range(8)), "ID register"
    adc = dut.g_adc[0].u_adc
    assert int(adc.mode.value) == 0x14_2001 and int(adc.conf.value) == 0x00_0157

    for f in got:
        assert [b["ch"] for b in f] == list(range(8))
        assert [b["data"] for b in f] == SAMPLES
        assert all(b["flags"] == 0 for b in f), f
    d = got[2][0]["ts"] - got[1][0]["ts"]
    assert abs(d - FRAME_CYCLES) < 3, d


@cocotb.test()
async def loopback_bist(dut):
    await setup(dut)
    await load(dut, [0x5000_0000, 0])                     # STREAM only
    dut.loopback.value, dut.enable.value = 1, 1
    got = await with_timeout(frames(dut, 2), 1, "ms")
    for f in got:
        assert [b["data"] & 0xFF_FFFF for b in f] == [(0x01_2345 + (k << 16)) & 0xFF_FFFF for k in range(8)]
        assert all(b["flags"] == 0 for b in f), f

    dut.loopback_cfg.value = (1000 << 16) | (3 << 4) | 0b011   # ramp, ERR injected on channel 3
    got = await with_timeout(frames(dut, 3), 1, "ms")
    base = [f[0]["data"] & 0xFF_FFFF for f in got[1:]]
    assert base[1] == (base[0] + 1) & 0xFF_FFFF, base
    assert [b["flags"] for b in got[2]] == [0, 0, 0, 0b00001, 0, 0, 0, 0]

    dut.loopback_cfg.value = (1000 << 16) | (5 << 4) | 0b100   # parity error injected on channel 5
    got = await with_timeout(frames(dut, 2), 1, "ms")
    assert [b["flags"] for b in got[1]] == [0, 0, 0, 0, 0, 0b00100, 0, 0]


@cocotb.test()
async def burnout_and_noref(dut):
    await setup(dut)
    dut.enable.value = 1
    await with_timeout(frames(dut, 1), 3, "ms")
    dut.open_wire.value, dut.no_ref.value = 1 << 6, 1 << 1
    await load(dut, [
        0x4000_0000, 0,               # WAIT_RDY: the exit command needs RDY low
        0x1220_0000, 0x5800_0000,     # exit continuous read: 0x58 out, 32 bits in
        0x1800_0000, 0x1000_01D7,     # config with BURN
        0x1200_0000, 0x5C00_0000,     # enter continuous read
        0x5000_0000, 0,               # STREAM
    ])
    await restart(dut)
    got = await with_timeout(frames(dut, 3), 3, "ms")
    f = got[2]
    assert int(dut.g_adc[0].u_adc.conf.value) == 0x00_01D7
    assert f[6]["data"] == 0x7F_FFFF and f[6]["flags"] & 1, "open wire reads full scale with ERR"
    assert f[1]["flags"] & 0b11 == 0b11, "NOREF and ERR"
    assert [b["data"] for i, b in enumerate(f) if i not in (1, 6)] == [s for i, s in enumerate(SAMPLES) if i not in (1, 6)]


def test_afe_frontend():
    from runner import run
    run("afe_tb", ["rtl/afe_spi.sv", "rtl/afe_sequencer.sv", "rtl/afe_loopback.sv", "rtl/tdm_mux.sv",
                   "rtl/afe_frontend.sv", "tb/system/ad7190_model.sv", "tb/afe_frontend/afe_tb.sv",
                   "tb/common/xpm_models.sv"],
        __file__, files=["coeff/seq_init.mem"])


if __name__ == "__main__":
    test_afe_frontend()
