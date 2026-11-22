"""mclp_registers: AXI4-Lite access over the 64 KB window, control pulses into clk_spi/clk_dsp, memories
through both ports, status and results back into s_axi_aclk, interrupts; the inference engine's registers,
model memories and results, built with USE_NN = 1 and again with USE_NN = 0 (that window reads 0x0BAD_0BAD).
XPM macros come from tb/common/xpm_models.sv.

    python tb/mclp_registers/test_mclp_registers.py
"""
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, Timer

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
ROOT = Path(__file__).resolve().parents[2]
USE_NN = 1                                                     # set from the build's parameter in setup()


async def axil_write(dut, addr, data):
    await FallingEdge(dut.s_axi_aclk)
    dut.s_axi_awaddr.value, dut.s_axi_awvalid.value = addr, 1
    dut.s_axi_wdata.value, dut.s_axi_wstrb.value, dut.s_axi_wvalid.value = data, 0xF, 1
    while True:
        await Timer(1, "ns")
        ready = int(dut.s_axi_awready.value)
        await FallingEdge(dut.s_axi_aclk)
        if ready:
            break
    dut.s_axi_awvalid.value = dut.s_axi_wvalid.value = 0
    dut.s_axi_bready.value = 1
    while not int(dut.s_axi_bvalid.value):
        await FallingEdge(dut.s_axi_aclk)
    await FallingEdge(dut.s_axi_aclk)
    dut.s_axi_bready.value = 0


async def axil_read(dut, addr):
    await FallingEdge(dut.s_axi_aclk)
    dut.s_axi_araddr.value, dut.s_axi_arvalid.value = addr, 1
    while True:
        await Timer(1, "ns")
        ready = int(dut.s_axi_arready.value)
        await FallingEdge(dut.s_axi_aclk)
        if ready:
            break
    dut.s_axi_arvalid.value = 0
    while not int(dut.s_axi_rvalid.value):
        await FallingEdge(dut.s_axi_aclk)
    data = int(dut.s_axi_rdata.value)
    dut.s_axi_rready.value = 1
    await FallingEdge(dut.s_axi_aclk)
    dut.s_axi_rready.value = 0
    return data


async def setup(dut):
    global USE_NN
    USE_NN = int(dut.USE_NN.value)
    Clock(dut.s_axi_aclk, 10, unit="ns").start()
    Clock(dut.clk_spi, 50, unit="ns").start()
    Clock(dut.clk_dsp, 20, unit="ns").start()
    for s in ("s_axi_awaddr", "s_axi_awprot", "s_axi_awvalid", "s_axi_wdata", "s_axi_wstrb", "s_axi_wvalid",
              "s_axi_bready", "s_axi_araddr", "s_axi_arprot", "s_axi_arvalid", "s_axi_rready", "spi_seq_addr",
              "spi_seq_busy", "spi_seq_resp", "dsp_gain_ch", "dsp_trim_ch", "dsp_fir_addr", "dsp_result_new",
              "dsp_result", "dsp_wim_new", "dsp_wim_sum", "dsp_wim_count", "dsp_stable", "dsp_overload",
              "dsp_reload_busy", "dsp_capture_active", "dsp_faults", "dsp_nn_lay_addr", "dsp_nn_bias_addr",
              "dsp_nn_wt_addr", "dsp_nn_done", "dsp_nn_est", "dsp_nn_corr", "dsp_nn_cycles", "dsp_nn_busy"):
        getattr(dut, s).value = 0
    dut.mmcm_locked.value = 1
    dut.s_axi_aresetn.value, dut.dsp_rst.value = 0, 1
    await ClockCycles(dut.s_axi_aclk, 5)
    dut.s_axi_aresetn.value, dut.dsp_rst.value = 1, 0
    await ClockCycles(dut.s_axi_aclk, 5)


async def count_pulses(clk, sig, cycles, out):
    n = 0
    for _ in range(cycles):
        await RisingEdge(clk)
        n += int(sig.value)
    out.append(n)


@cocotb.test()
async def registers_and_pulses(dut):
    await setup(dut)
    assert await axil_read(dut, 0x000) == 0x4D4C_0508                # map version 5, 8 channels
    assert await axil_read(dut, 0x048) == 12
    assert await axil_read(dut, 0x05C) == 0xEE14                     # WIM_LEVEL 0.93
    assert await axil_read(dut, 0x044) == 0x0BAD_0BAD
    assert await axil_read(dut, 0x054) == 4166 << 16
    assert await axil_read(dut, 0x0F0) == 0x0BAD_0BAD
    assert await axil_read(dut, 0x1004) == (0 if USE_NN else 0x0BAD_0BAD)  # NN_STATUS, not STATUS at 0x004
    assert await axil_read(dut, 0x1018) == 0x0BAD_0BAD
    assert await axil_read(dut, 0x9000) == 0x0BAD_0BAD
    assert await axil_read(dut, 0xF048) == 0x0BAD_0BAD               # no alias of RESULT_DECIM
    assert int(dut.spi_enable.value) == 1                      # reset value, init list runs at power-up

    pulses = []
    cocotb.start_soon(count_pulses(dut.clk_spi, dut.spi_seq_start, 40, pulses))
    for s in (dut.dsp_fir_reload, dut.dsp_sw_trigger, dut.dsp_fault_clear):
        cocotb.start_soon(count_pulses(dut.clk_dsp, s, 60, pulses))
    await axil_write(dut, 0x004, 0x1FF)
    await ClockCycles(dut.clk_spi, 45)
    assert pulses == [1, 1, 1, 1]
    assert (int(dut.spi_enable.value), int(dut.spi_loopback.value)) == (1, 1)
    assert (int(dut.dsp_raw_tap.value), int(dut.dsp_raw_enable.value)) == (3, 1)
    assert await axil_read(dut, 0x004) == 0x73

    await axil_write(dut, 0x03C, 0xDEAD_BEEF)
    await axil_write(dut, 0x054, 0x1234_0071)
    await axil_write(dut, 0x05C, 0xFFFF_C000)
    await axil_write(dut, 0x1000, 1)                           # NN_CTRL.enable
    await ClockCycles(dut.clk_spi, 20)                         # worst case: one handshake in flight, then ours
    assert int(dut.dsp_wim_enter.value) == 0xDEAD_BEEF
    assert int(dut.dsp_wim_level.value) == 0xC000
    assert int(dut.dsp_nn_enable.value) == USE_NN
    assert await axil_read(dut, 0x1000) == (1 if USE_NN else 0x0BAD_0BAD)
    assert await axil_read(dut, 0x05C) == 0xC000
    assert int(dut.spi_loopback_cfg.value) == 0x1234_0071
    assert await axil_read(dut, 0x03C) == 0xDEAD_BEEF


@cocotb.test()
async def memories(dut):
    await setup(dut)
    await axil_write(dut, 0x90C, 0x1234_5678)                 # gain[3]
    await axil_write(dut, 0xA04, 0x0000_0042)                 # offset[1]
    await axil_write(dut, 0x9FC, 0x0000_0063)                 # gain[63]: the RAMs hold 64 words
    dut.dsp_gain_ch.value, dut.dsp_trim_ch.value = 3, 5
    await ClockCycles(dut.clk_dsp, 2)
    assert int(dut.dsp_gain.value) == 0x1234_5678
    assert int(dut.dsp_trim.value) == 0x4000_0000              # unity64.mem
    dut.dsp_gain_ch.value = 1
    await ClockCycles(dut.clk_dsp, 2)
    assert int(dut.dsp_offset.value) == 0x42
    assert await axil_read(dut, 0x90C) == 0x1234_5678
    assert await axil_read(dut, 0xA04) == 0x42
    assert await axil_read(dut, 0x9FC) == 0x63
    assert await axil_read(dut, 0xB00) == 0x4000_0000            # trim[0]

    first_tap = int((ROOT / "coeff" / "fir64.mem").read_text().split()[0], 16)
    assert await axil_read(dut, 0x200) == first_tap
    await axil_write(dut, 0x204, 0x0000_ABCD)
    dut.dsp_fir_addr.value = 1
    await ClockCycles(dut.clk_dsp, 2)
    assert int(dut.dsp_fir_coef.value) == 0xABCD

    first_cmd = int((ROOT / "coeff" / "seq_init.mem").read_text().split()[0], 16)
    assert await axil_read(dut, 0x400) == first_cmd            # seq_init.mem word 0
    await axil_write(dut, 0x428, 0xCAFE_0010)                  # seq word 10
    dut.spi_seq_addr.value = 10
    await ClockCycles(dut.clk_spi, 2)
    assert int(dut.spi_seq_data.value) == 0xCAFE_0010
    assert await axil_read(dut, 0x428) == 0xCAFE_0010

    if not USE_NN:
        for a in (0x2000, 0x3000, 0x4000, 0x7FFC):
            assert await axil_read(dut, a) == 0x0BAD_0BAD
        return
    for base, name in ((0x2000, "layers"), (0x3000, "bias"), (0x4000, "weights")):
        first = int((ROOT / "coeff" / f"nn_{name}.mem").read_text().split()[0], 16)
        assert await axil_read(dut, base) == first                 # nn_<name>.mem word 0
    await axil_write(dut, 0x2008, 0x1111_0002)                 # layer word 2
    await axil_write(dut, 0x33FC, 0x2222_00FF)                 # bias 255
    await axil_write(dut, 0x7FFC, 0x3333_0FFF)                 # weight word 4095
    dut.dsp_nn_lay_addr.value, dut.dsp_nn_bias_addr.value, dut.dsp_nn_wt_addr.value = 2, 255, 4095
    await ClockCycles(dut.clk_dsp, 2)
    assert int(dut.dsp_nn_lay_q.value) == 0x1111_0002
    assert int(dut.dsp_nn_bias_q.value) == 0x2222_00FF
    assert int(dut.dsp_nn_wt_q.value) == 0x3333_0FFF
    assert [await axil_read(dut, a) for a in (0x2008, 0x33FC, 0x7FFC)] == [0x1111_0002, 0x2222_00FF, 0x3333_0FFF]
    assert await axil_read(dut, 0x200C) != 0x1111_0002            # no alias inside the window


@cocotb.test()
async def status_and_irq(dut):
    await setup(dut)
    await axil_write(dut, 0x010, 0x7F)
    assert int(dut.irq.value) == 0

    await FallingEdge(dut.clk_dsp)
    dut.dsp_result.value, dut.dsp_result_new.value = 0x55, 1
    await FallingEdge(dut.clk_dsp)
    dut.dsp_result_new.value = 0
    await ClockCycles(dut.s_axi_aclk, 10)
    assert int(dut.irq.value) == 1
    assert await axil_read(dut, 0x020) == 0x55
    assert await axil_read(dut, 0x024) == 1
    assert await axil_read(dut, 0x00C) == 0x01
    await axil_write(dut, 0x00C, 0x01)
    assert int(dut.irq.value) == 0

    await FallingEdge(dut.clk_dsp)
    dut.dsp_wim_sum.value, dut.dsp_wim_count.value, dut.dsp_wim_new.value = 0x1_0000_0002, 7, 1
    await FallingEdge(dut.clk_dsp)
    dut.dsp_wim_new.value = 0
    await ClockCycles(dut.s_axi_aclk, 10)
    assert [await axil_read(dut, a) for a in (0x028, 0x02C, 0x030)] == [2, 1, 7]

    dut.dsp_faults.value = 0b10101 << 10                       # channel 2
    dut.spi_seq_resp.value = 0xA5A5_0007 << (7 * 32)
    dut.dsp_overload.value, dut.spi_seq_busy.value = 1, 1
    await ClockCycles(dut.clk_spi, 3)
    dut.spi_seq_busy.value = 0                                 # sequencer done
    await ClockCycles(dut.clk_spi, 3)
    assert await axil_read(dut, 0xC08) == 0b10101                # FAULT[2]
    assert await axil_read(dut, 0x81C) == 0xA5A5_0007            # SEQ_RESP[7]
    assert await axil_read(dut, 0x820) == 0x0BAD_0BAD            # SEQ_RESP[8]: past N_CH
    assert await axil_read(dut, 0xC20) == 0x0BAD_0BAD            # FAULT[8]
    assert await axil_read(dut, 0x008) == 0b001001             # overload, MMCM locked
    assert await axil_read(dut, 0x00C) == (1 << 2) | (1 << 3) | (1 << 4) | (1 << 5)

    if not USE_NN:
        return
    await axil_write(dut, 0x010, 0x80)                         # inference done only
    await axil_write(dut, 0x00C, 0xFF)
    dut.dsp_nn_busy.value = 1
    await ClockCycles(dut.clk_dsp, 6)
    assert await axil_read(dut, 0x1004) == 1                     # NN_STATUS busy
    await FallingEdge(dut.clk_dsp)
    dut.dsp_nn_est.value, dut.dsp_nn_corr.value, dut.dsp_nn_cycles.value = 0x8123_4567, 0xFFFF_FF9C, 44439
    dut.dsp_nn_done.value, dut.dsp_nn_busy.value = 1, 0
    await FallingEdge(dut.clk_dsp)
    dut.dsp_nn_done.value = 0
    await ClockCycles(dut.s_axi_aclk, 10)
    assert int(dut.irq.value) == 1
    assert [await axil_read(dut, a) for a in (0x1004, 0x1008, 0x100C, 0x1010, 0x1014)] == \
        [0, 1, 0x8123_4567, 0xFFFF_FF9C, 44439]
    assert await axil_read(dut, 0x00C) == 0x80


def test_mclp_registers():
    from runner import run
    for use_nn in (1, 0):
        run("mclp_registers", ["rtl/mclp_registers.sv", "rtl/axil_bram_ctrl.sv", "tb/common/xpm_models.sv"], __file__,
            parameters={"USE_NN": use_nn},
            files=["coeff/fir64.mem", "coeff/seq_init.mem", "coeff/unity64.mem", "coeff/nn_layers.mem",
                   "coeff/nn_bias.mem", "coeff/nn_weights.mem"])


if __name__ == "__main__":
    test_mclp_registers()
