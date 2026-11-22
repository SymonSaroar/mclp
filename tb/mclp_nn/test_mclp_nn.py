"""mclp_nn against an integer reference that reads the packed model memories: the default model
(coeff/nn_*.mem) on load-shaped windows and on edge cases, then random models (convolution and dense layers,
sizes, strides, scales that saturate) on random windows. Also: no run while disabled, and a weigh-in-motion
result that arrives during a run is not run.

    python tb/mclp_nn/test_mclp_nn.py
"""
import math
import random
import shutil
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
ROOT = Path(__file__).resolve().parents[2]
I32 = (-(1 << 31), (1 << 31) - 1)
SIZES = {"layers": 64, "bias": 256, "weights": 4096}


def clamp(v, lo, hi):
    return min(max(v, lo), hi)


def signed(v, bits):
    return v - (1 << bits) if v >> (bits - 1) & 1 else v


def reference(mem, window, wsum, wcount):
    """(est, corr) for a window of 256 weights and the WIM result, as the header of rtl/mclp_nn.sv states."""
    lay, bias, wt = mem["layers"], mem["bias"], mem["weights"]
    ref = clamp(wsum // wcount, 1, I32[1]) if wsum > 0 else 1
    k = ref.bit_length()
    r = (1 << (k + 21)) // ref
    a = [clamp((clamp(x - ref, -(1 << k), 1 << k) * r + (1 << (k + 10))) >> (k + 11), -128, 127) for x in window]
    w8 = lambda i: signed(wt[i >> 2] >> (8 * (i & 3)) & 0xFF, 8)
    li = 0
    while True:
        w0, w1, w2, w3 = lay[4 * li:4 * li + 4]
        last, relu, st, kk, cc, oo = w0 >> 31, w0 >> 30 & 1, w0 >> 26 & 15, w0 >> 16 & 1023, w0 >> 8 & 255, w0 & 255
        ll, tt, s, m, bb, wb = w1 >> 16 & 1023, w1 & 1023, w2 >> 16 & 63, w2 & 0x7FFF, w3 >> 16, w3 & 0xFFFF
        out = []
        for o in range(oo):
            for t in range(tt):
                acc = signed(bias[bb + o], 32) + sum(w8(wb + (o * cc + c) * kk + j) * a[c * ll + t * st + j]
                                                     for c in range(cc) for j in range(kk))
                out.append((acc * m + (1 << (s - 1))) >> s)
        if last:
            corr = clamp(out[-1], *I32)
            return clamp(ref + ((ref * corr + (1 << 19)) >> 20), *I32), corr
        a = [clamp(y, 0 if relu else -128, 127) for y in out]
        li += 1


def scale_ms(scale):
    s = clamp(14 - math.floor(math.log2(scale)), 1, 47)
    return clamp(round(scale * 2**s), 1, 0x7FFF), s


def random_model(rnd):
    """Packed memories of a random model: up to three convolutions, up to two hidden dense layers, a dense output."""
    lay, bias, wbytes = [], [], []
    length, ch = 256, 1
    plan = [("conv", rnd.randint(1, 12), rnd.randint(1, 9), rnd.randint(1, 4)) for _ in range(rnd.randint(0, 3))]
    plan += [("dense", rnd.randint(1, 16), 0, 1) for _ in range(rnd.randint(0, 2))] + [("dense", 1, 0, 1)]
    for i, (op, o, k, st) in enumerate(plan):
        last = i == len(plan) - 1
        if op == "dense":
            k, st = length, 1
        t = (length - k) // st + 1
        o = max(1, min(o, 1024 // t))
        typical = math.sqrt(ch * k) * 64 * 64
        if last:
            m, s = scale_ms(2**20 * rnd.choice([0.05, 0.05, 1e4]) / typical)
        else:
            m, s = scale_ms(100 / typical * rnd.choice([0.25, 1, 4]))
        lay += [(last << 31) | (rnd.randint(0, 1) << 30) | (st << 26) | (k << 16) | (ch << 8) | o,
                (length << 16) | t, (s << 16) | m, (len(bias) << 16) | len(wbytes)]
        bias += [rnd.randint(-2**20, 2**20) & 0xFFFF_FFFF for _ in range(o)]
        wbytes += [rnd.randint(-127, 127) & 0xFF for _ in range(o * ch * k)]
        length, ch = t, o
    wbytes += [0] * (-len(wbytes) % 4)
    words = [wbytes[j] | wbytes[j + 1] << 8 | wbytes[j + 2] << 16 | wbytes[j + 3] << 24 for j in range(0, len(wbytes), 4)]
    if len(words) > SIZES["weights"] or len(bias) > SIZES["bias"]:
        return random_model(rnd)
    return {"layers": lay, "bias": bias, "weights": words}


def load_shape(rnd, ref):
    """256 weights ending at an exit: plateau with bounce and noise, an exit ramp, sometimes an entry ramp."""
    level = ref * (1 + rnd.uniform(-0.08, 0.08))
    amp, f, ph = rnd.uniform(0, 0.05), rnd.uniform(0.005, 0.05), rnd.uniform(0, 6.3)
    start, ramp = rnd.choice([0, 0, rnd.randint(0, 180)]), rnd.randint(4, 60)
    x = []
    for j in range(256):
        v = level * (1 + amp * math.sin(f * j + ph)) + rnd.gauss(0, ref * 0.002)
        if j < start:
            v = rnd.gauss(0, ref * 0.002)
        elif j < start + ramp:
            v *= (j - start) / ramp
        if j >= 256 - ramp:
            v *= (255 - j) / ramp * 0.9
        x.append(clamp(int(v), *I32))
    return x


async def run_one(dut, rnd, window, wsum, wcount, busy_poke=False):
    """Feed 1024 samples whose every 4th, ending at the last, is the window; then the WIM result."""
    stream = [rnd.randint(-2**31, 2**31 - 1) for _ in range(1024)]
    stream[3::4] = window
    for v in stream:
        dut.s_valid.value, dut.s_data.value = 1, v
        await RisingEdge(dut.clk)
    dut.s_valid.value = 0
    dut.wim_new.value, dut.wim_sum.value, dut.wim_count.value = 1, wsum, wcount
    await RisingEdge(dut.clk)
    dut.wim_new.value = 0
    for n in range(400_000):
        await RisingEdge(dut.clk)
        if busy_poke and n == 2000:                          # a result during the run is not run
            dut.wim_new.value = 1
        elif busy_poke and n == 2001:
            dut.wim_new.value = 0
        if int(dut.done.value):
            break
    else:
        raise AssertionError("no result")
    result = dut.est.value.to_signed(), dut.corr.value.to_signed(), int(dut.cycles.value)
    if busy_poke:
        for _ in range(3000):
            await RisingEdge(dut.clk)
            assert not int(dut.busy.value) and not int(dut.done.value)
    return result


def write_mem(mem):
    for name, words in mem.items():
        Path(f"nn_{name}.mem").write_text("".join(f"{v:08x}\n" for v in words + [0] * (SIZES[name] - len(words))))


def read_mem(prefix):
    return {name: [int(s, 16) for s in Path(f"{prefix}_{name}.mem").read_text().split()] for name in SIZES}


@cocotb.test()
async def models(dut):
    Clock(dut.clk, 20, unit="ns").start()
    rnd = random.Random(11)
    dut.rst.value, dut.enable.value, dut.s_valid.value, dut.wim_new.value, dut.reload.value = 1, 1, 0, 0, 0
    await ClockCycles(dut.clk, 3)
    dut.rst.value = 0

    mem = read_mem(str(ROOT / "coeff" / "nn"))
    cases = []
    for _ in range(10):
        ref = rnd.randint(2**24, 2**28)
        wcount = rnd.randint(5, 1500)
        cases.append((load_shape(rnd, ref), ref * wcount + rnd.randint(0, wcount - 1), wcount))
    cases += [([rnd.randint(-2**31, 2**31 - 1) for _ in range(256)], 0, 7),               # ref clamped to 1
              ([rnd.randint(-2**31, 2**31 - 1) for _ in range(256)], -12345, 3),
              ([2**31 - 1] * 256, (2**31 - 1) * 5, 5),                                     # ref at the top
              ([rnd.randint(2**30, 2**31 - 1) for _ in range(256)], 2**40, 1)]             # quotient clamped
    for i, (window, wsum, wcount) in enumerate(cases):
        est, corr, cyc = await run_one(dut, rnd, window, wsum, wcount, busy_poke=(i == 1))
        assert (est, corr) == reference(mem, window, wsum, wcount), i
        if i == 0:
            dut._log.info(f"default model: {cyc} clocks per inference")

    dut.enable.value = 0                                    # disabled: the result is not run
    dut.wim_new.value = 1
    await RisingEdge(dut.clk)
    dut.wim_new.value = 0
    for _ in range(3000):
        await RisingEdge(dut.clk)
        assert not int(dut.busy.value) and not int(dut.done.value)
    dut.enable.value = 1

    for _ in range(8):
        mem = random_model(rnd)
        write_mem(mem)
        dut.reload.value = 1
        await RisingEdge(dut.clk)
        dut.reload.value = 0
        await RisingEdge(dut.clk)
        for _ in range(3):
            ref = rnd.randint(1, 2**30)
            window = [clamp(int(ref * rnd.uniform(0.5, 1.5)), *I32) if rnd.random() < 0.7
                      else rnd.randint(-2**31, 2**31 - 1) for _ in range(256)]
            est, corr, _ = await run_one(dut, rnd, window, ref * 3 + 1, 3)
            assert (est, corr) == reference(mem, window, ref * 3 + 1, 3)


def test_mclp_nn():
    from runner import run
    build = ROOT / "build" / "tb" / "nn_tb"
    build.mkdir(parents=True, exist_ok=True)
    for name in SIZES:
        shutil.copy(ROOT / "coeff" / f"nn_{name}.mem", build)
    run("nn_tb", ["rtl/mclp_nn.sv", "tb/mclp_nn/nn_tb.sv"], __file__)


if __name__ == "__main__":
    test_mclp_nn()
