"""mclp_registers: AXI4-Lite access, control pulses into clk_spi/clk_dsp, memories through both ports,
status and results back into s_axi_aclk, interrupts. XPM macros come from tb/common/xpm_models.sv.

    python tb/mclp_registers/test_mclp_registers.py
"""
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, Timer

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
ROOT = Path(__file__).resolve().parents[2]


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
    Clock(dut.s_axi_aclk, 10, unit="ns").start()
    Clock(dut.clk_spi, 50, unit="ns").start()
    Clock(dut.clk_dsp, 20, unit="ns").start()
    for s in ("s_axi_awaddr", "s_axi_awprot", "s_axi_awvalid", "s_axi_wdata", "s_axi_wstrb", "s_axi_wvalid",
              "s_axi_bready", "s_axi_araddr", "s_axi_arprot", "s_axi_arvalid", "s_axi_rready", "spi_seq_addr",
              "spi_seq_busy", "spi_seq_resp", "dsp_gain_ch", "dsp_trim_ch", "dsp_fir_addr", "dsp_result_new",
              "dsp_result", "dsp_wim_new", "dsp_wim_sum", "dsp_wim_count", "dsp_stable", "dsp_overload",
              "dsp_reload_busy", "dsp_capture_active", "dsp_faults"):
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
    assert await axil_read(dut, 0x000) == 0x4D4C_0108
    assert await axil_read(dut, 0x048) == 12
    assert await axil_read(dut, 0x054) == 4166 << 16
    assert await axil_read(dut, 0x0F0) == 0x0BAD_0BAD
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
    await ClockCycles(dut.clk_spi, 20)                         # worst case: one handshake in flight, then ours
    assert int(dut.dsp_wim_enter.value) == 0xDEAD_BEEF
    assert int(dut.spi_loopback_cfg.value) == 0x1234_0071
    assert await axil_read(dut, 0x03C) == 0xDEAD_BEEF


@cocotb.test()
async def memories(dut):
    await setup(dut)
    await axil_write(dut, 0x10C, 0x1234_5678)                 # gain[3]
    await axil_write(dut, 0x124, 0x0000_0042)                 # offset[1]
    dut.dsp_gain_ch.value, dut.dsp_trim_ch.value = 3, 5
    await ClockCycles(dut.clk_dsp, 2)
    assert int(dut.dsp_gain.value) == 0x1234_5678
    assert int(dut.dsp_trim.value) == 0x4000_0000              # unity8.mem
    dut.dsp_gain_ch.value = 1
    await ClockCycles(dut.clk_dsp, 2)
    assert int(dut.dsp_offset.value) == 0x42
    assert await axil_read(dut, 0x10C) == 0x1234_5678
    assert await axil_read(dut, 0x124) == 0x42

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
    assert await axil_read(dut, 0x068) == 0b10101
    assert await axil_read(dut, 0x81C) == 0xA5A5_0007
    assert await axil_read(dut, 0x008) == 0b001001             # overload, MMCM locked
    assert await axil_read(dut, 0x00C) == (1 << 2) | (1 << 3) | (1 << 4) | (1 << 5)


def test_mclp_registers():
    from runner import run
    run("mclp_registers", ["rtl/mclp_registers.sv", "rtl/axil_bram_ctrl.sv", "tb/common/xpm_models.sv"], __file__,
        files=["coeff/fir64.mem", "coeff/seq_init.mem", "coeff/unity8.mem"])


if __name__ == "__main__":
    test_mclp_registers()
