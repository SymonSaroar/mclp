# MCLP load-cell core

`mclp_core` is a load-cell weighing IP core for AMD FPGAs. It reads 1 to 64 Analog Devices AD7190 24-bit
sigma-delta ADCs in parallel, one per load cell, and computes the weight in the FPGA. Each channel is
decimated, corrected for offset and gain, and trimmed for its position on the platform. The core then sums the
channels and low-pass filters the sum. Software configures the core and reads the weight over AXI4-Lite. Raw
per-channel samples stream out over AXI4-Stream for calibration and diagnostics.

The repository also contains:

- A reference design for the AMD ZC702 evaluation board (Zynq-7000): Vivado block design, PetaLinux image,
  console application and REST/MQTT service
- An 8-channel AD7190 FMC card in KiCad: [hw/adc-card](hw/adc-card/README.md)
- cocotb unit tests, a system test with AD7190 models, and a DMA test of the reference design

Status: passes simulation at 1, 8 and 64 channels. Not yet tested on hardware.

## License

MCLP is available under the CERN Open Hardware Licence Version 2 - Strongly Reciprocal (hardware) and the
GPL-3.0 (software in `sw/`), or under a paid commercial license. See [LICENSE](LICENSE).

## Features

- Up to 64 channels
- Simultaneous sampling of all channels
- Up to 4800 samples/s per channel
- Weight output rate programmable up to 600 Hz
- Per-channel offset, gain and corner-trim calibration
- 64-tap FIR filter, coefficients reloadable at run time
- Stability detection
- Weigh-in-motion
- Overload detection
- Per-channel fault detection: open wire, missing excitation, over-range, data errors
- Raw data capture, continuous or triggered
- Built-in self-test
- AXI4-Lite control interface
- AXI4-Stream raw data interface
- Interrupt output

## Supported devices and tools

- FPGA families declared in the IP package: Zynq-7000, Spartan-7, Artix-7, Kintex-7, Virtex-7, Kintex and
  Virtex UltraScale and UltraScale+, Zynq UltraScale+ MPSoC. Implemented and timed on `xc7z020clg484-1` only.
- Vivado 2025.1. The reference block-design script refuses other versions.
- Simulators: Vivado simulator; Icarus Verilog 12 with the XPM models in `tb/common/xpm_models.sv`
- ADC: AD7190

## Resource utilization

`N_CH = 8`, out-of-context synthesis, `xc7z020clg484-1`, Vivado 2025.1:

| LUT | LUT as memory | FF | Block RAM tiles | DSP48E1 |
|---|---|---|---|---|
| 3,130 | 167 | 6,013 | 10 (9 RAMB36, 2 RAMB18) | 11 |

Timing closes in the reference design on the -1 speed grade with `aclk` at 100 MHz, `clk_spi` at 20 MHz and
`clk_dsp` at 50 MHz. Worst negative slack: +1.83 ns.

## Getting started

### Add the core to a Vivado project

1. Get the packaged core. Download `mclp_core-1.0.zip` from the [releases page](../../releases) and unzip it,
   or package it from this repository:

   ```sh
   vivado -mode batch -source tcl/package_ip.tcl      # writes build/ip_repo/mclp_core
   ```

2. Add the folder that holds `mclp_core` to the project's IP repositories (Settings > IP > Repository).
3. Add MCLP load-cell core to a block design. Set Channels (`N_CH`).
4. Connect the interfaces:

   | Core | Connect to |
   |---|---|
   | `s_axi` | AXI4-Lite master; address range 4 KB |
   | `m_axis_raw` | AXI DMA S2MM, 64-bit stream. Optional. With `tready` low, raw records are dropped and the weight path runs on. |
   | `aclk`, `aresetn` | AXI clock and its reset |
   | `clk_spi`, `clk_dsp`, `clk_locked` | MMCM outputs at 20 MHz and 50 MHz, and its `locked`. Reset the MMCM from the AXI reset. |
   | `irq` | interrupt controller |
   | `spi_*`, `adc_sync_n` | FPGA pins to the AD7190s |

   [tcl/mclp_top_bd.tcl](tcl/mclp_top_bd.tcl) builds the reference block design with these connections.

5. Constrain the ADC pins: package pins, an I/O standard that matches the AD7190 DVDD, and the false paths in
   [xdc/mclp_timing.xdc](xdc/mclp_timing.xdc). The XPM macros inside the core carry their own clock-domain
   crossing constraints.
6. Write the software against the [register space](#register-space) and the
   [programming sequence](#programming-sequence). `sw/common` is a C implementation for bare metal and Linux.

### Prototype on the ZC702

The [reference design](#reference-design-zc702) runs the core with 8 channels on a ZC702 with the FMC card.
Each release carries prebuilt boot files for it.

## Product specification

### Parameters

| Parameter | Values | Default | Description |
|---|---|---|---|
| `N_CH` | 1 to 64 | 8 | Number of AD7190 chips; width of `spi_sdi` |

### Ports

| Port | Dir | Width | Clock | Description |
|---|---|---|---|---|
| `aclk` | in | 1 | | AXI clock |
| `aresetn` | in | 1 | async | Reset, active low |
| `clk_spi` | in | 1 | | 20 MHz: SPI master, sequencer, loopback emulator |
| `clk_dsp` | in | 1 | | 50 MHz: processing chain, raw capture |
| `clk_locked` | in | 1 | async | `clk_spi` and `clk_dsp` running. Resets their domains while low. |
| `s_axi_*` | | | `aclk` | AXI4-Lite slave, 12-bit address, 32-bit data |
| `m_axis_raw_*` | out | 64 | `aclk` | AXI4-Stream master: `tdata`, `tlast`, `tvalid`, `tready` |
| `irq` | out | 1 | `aclk` | Interrupt, level, active high |
| `spi_sclk` | out | 1 | `clk_spi` | SPI clock, to SCLK of every AD7190 |
| `spi_sdo` | out | 1 | `clk_spi` | SPI data out, to DIN of every AD7190 |
| `spi_cs_n` | out | 1 | `clk_spi` | Chip select, to CS of every AD7190 |
| `adc_sync_n` | out | 1 | `clk_spi` | Filter reset, to SYNC of every AD7190 |
| `spi_sdi` | in | `N_CH` | async | SPI data in, bit k from DOUT/RDY of AD7190 k. Its falling edge marks data ready. |

### Clocks and resets

| Clock | Frequency | Logic |
|---|---|---|
| `aclk` | 100 MHz tested | AXI interfaces, registers, interrupt |
| `clk_spi` | 20 MHz required | SPI master, sequencer, loopback emulator, timestamps |
| `clk_dsp` | 50 MHz tested | CIC, scaling, sum, FIR, stability, weigh-in-motion, raw capture |

SCLK is `clk_spi` / 8. A SYNC pulse lasts 32 `clk_spi` cycles (1.6 µs). The sequencer's `WAIT_US` counts 20
cycles per microsecond.

`aresetn` resets the `aclk` logic. `clk_locked` resets the `clk_spi` and `clk_dsp` logic. Both are
asynchronous and synchronized inside the core. Hold `clk_locked` low while `aresetn` is low. An MMCM reset
driven by the AXI reset does this.

### Data path

| Stage | Operation | Rate | Width |
|---|---|---|---|
| AD7190 | continuous conversion, sinc4, FS = 1, chop off | 4800 Hz | 24 data + 8 status |
| SPI receive | `N_CH` lanes in parallel, offset binary to two's complement | 4800 Hz | 24 |
| CIC | R = 8, N = 3, gain 256 per ADC code | 600 Hz | 32 |
| Gain/offset | `sat32(((x - OFFSET) * GAIN) >>> 30)` | 600 Hz | 32 |
| Trim | `sat32((x * TRIM) >>> 30)` | 600 Hz | 32 |
| Sum | exact sum of `N_CH` channels | 600 Hz | 40 |
| FIR | 64 taps, 18-bit coefficients, full precision | 600 Hz | 64 |
| Weight | `sat32(FIR >>> (20 + ceil(log2(N_CH))))` | 600 Hz | 32 |
| RESULT | every RESULT_DECIM-th weight | 50 Hz | 32 |

The default FIR is a 12 Hz Hamming-windowed sinc with taps summing to 2^20 (`coeff/fir64.py`). Group delay:
31.5 samples, 52.5 ms. At unity gain and trim, RESULT changes by 256 / 2^ceil(log2(N_CH)) counts per ADC code
on one channel: 32 at 8 channels. All channels at full scale fit in 32 bits.

The stability flag rises after STAB_COUNT consecutive weights within ±STAB_BAND of a reference. A weight
outside the band clears it and becomes the new reference.

Weigh-in-motion starts when the weight rises above WIM_ENTER. After WIM_SETTLE samples the core sums the
weights until the weight drops below WIM_EXIT. Result: WIM_SUM / WIM_COUNT. A load that leaves during the
settle time gives no result.

### Register space

4 KB. Offsets from the base address assigned in the block design (0x43C0_0000 in the reference design).
Register map version 3. Per-channel arrays take one 64-word block each, channel k at +4k.

| Offset | Name | Description |
|---|---|---|
| 0x000 | ID | 0x4D4C_03nn. [31:16] 0x4D4C ("ML"), [15:8] register map version, [7:0] `N_CH` |
| 0x004 | CTRL | [0] enable (reset 1), [1] loopback, [5:4] raw_tap, [6] raw_enable. Self-clearing: [2] fir_reload, [3] seq_start, [7] sw_trigger, [8] fault_clear |
| 0x008 | STATUS | [0] clocks locked, [1] seq_busy, [2] reload_busy, [3] overload, [4] stable, [5] capture_active |
| 0x00C | IRQ_STATUS | Write 1 to clear. [0] result, [1] stable, [2] weigh-in-motion, [3] overload, [4] fault, [5] sequencer done, [6] capture done |
| 0x010 | IRQ_ENABLE | Same bits as IRQ_STATUS |
| 0x020 | RESULT | Weight, signed |
| 0x024 | RESULT_SEQ | Increments with each RESULT update |
| 0x028, 0x02C | WIM_SUM_LO, WIM_SUM_HI | Weigh-in-motion plateau sum, 64 bit |
| 0x030 | WIM_COUNT | Weigh-in-motion plateau samples |
| 0x034 | STAB_BAND | Reset 4096 |
| 0x038 | STAB_COUNT | Reset 60 |
| 0x03C, 0x040 | WIM_ENTER, WIM_EXIT | Reset 0x7FFF_FFFF (off) |
| 0x044 | WIM_SETTLE | Reset 60 |
| 0x048 | RESULT_DECIM | Reset 12 |
| 0x04C | TRIG_CFG | [1:0] mode: 0 continuous, 1 one-shot, 2 threshold. [31:16] frames per one-shot |
| 0x050 | TRIG_THRESHOLD | Sum level that starts a mode 2 capture |
| 0x054 | LOOPBACK_CFG | [0] ramp, [1] inject ERR, [2] inject parity error, [9:4] channel for injection, [31:16] frame period in `clk_spi` cycles (reset 4166) |
| 0x058 | LOOPBACK_VALUE | Constant-mode data, reset 0x123456 |
| 0x200-0x2FC | FIR | 64 coefficients, word i applies to x[n-i]. Reset from `coeff/fir64.mem` |
| 0x400-0x7FC | SEQ | Sequencer RAM, 256 words. Reset from `coeff/seq_init.mem` |
| 0x800-0x8FC | SEQ_RESP[64] | Last XFER read per chip |
| 0x900-0x9FC | GAIN[64] | Q2.30, reset 1.0 |
| 0xA00-0xAFC | OFFSET[64] | CIC units, reset 0 |
| 0xB00-0xBFC | TRIM[64] | Q2.30, reset 1.0 |
| 0xC00-0xCFC | FAULT[64] | Sticky. [0] ERR, [1] NOREF, [2] parity error, [3] stale (RDY set), [4] loopback mismatch |

Unmapped addresses and array entries at or above `N_CH` read 0x0BAD_0BAD. A configuration write reaches
`clk_spi` and `clk_dsp` within about 1 µs.

Fault flags: ERR is the AD7190's error bit (over-range, open input with burnout currents on, missing reference
when REFDET is on). NOREF is its reference-detect bit. A parity error is a corrupted word on the cable. Stale
means the chip had not finished a conversion when read. A new flag sets IRQ_STATUS[4]. CTRL.fault_clear clears
all flags.

### Sequencer

The sequencer drives the shared SPI lines from a command list in its RAM. It runs the list from word 0 after
reset, on CTRL.seq_start, and on a rising edge of CTRL.enable. Each command is two words:

```
w0 = {op[3:0], ntx[5:0], nrx[5:0], arg[15:0]}
w1 = data shifted out, MSB first
```

| op | Command | Action |
|---|---|---|
| 0 | END | Stop |
| 1 | XFER | Shift `ntx` bits of `w1` out, then read `nrx` bits from every chip into SEQ_RESP |
| 2 | SYNC | SYNC low for 1.6 µs |
| 3 | WAIT_US | Wait `arg` µs |
| 4 | WAIT_RDY | Wait for DOUT/RDY low on chip 0 |
| 5 | STREAM | Read a 32-bit word (data + status) from every chip on each DOUT/RDY falling edge |

STATUS.seq_busy falls and IRQ_STATUS[5] sets when the list reaches END or STREAM.

The default list (`coeff/seq_init.py`) resets the chips, reads their ID registers, writes the configuration,
runs the internal zero-scale calibration, starts continuous conversion, pulses SYNC and streams. AD7190
configuration: AIN1/AIN2, REFIN1, reference detect on, buffer on, bipolar, gain 128; external clock on MCLK2,
sinc4, FS = 1, status byte and parity appended to each word. To leave continuous read: `WAIT_RDY`, then `XFER`
of 0x58 with `ntx = 8`, `nrx = 32`.

### Raw records

CTRL.raw_tap selects the source: 0 ADC code (24 bit, sign-extended), 1 CIC output, 2 after gain/offset, 3
after trim. Each frame becomes one record of 2 + ceil(`N_CH` / 2) 64-bit words, `tlast` on the last word: 48
bytes at 8 channels, 272 at 64.

| Word | Content |
|---|---|
| 0 | [63:16] timestamp, `clk_spi` cycles at the DOUT/RDY edge; [15:14] tap; [13:0] 0 |
| 1 to ceil(`N_CH` / 2) | Samples `{ch1, ch0}`, `{ch3, ch2}`, ...; `{0, chN-1}` when `N_CH` is odd |
| last | Fault word: bit k set when channel k had a fault flag in this frame |

At tap 0 the timestamp and fault word belong to the record's own frame. At taps 1 to 3 they come from the
newest complete frame. A record starts at channel 0 only when the output FIFO has room for it. Records that do
not fit are skipped whole.

Trigger modes (TRIG_CFG[1:0]): 0 continuous while CTRL.raw_enable is set. 1 one-shot of TRIG_CFG[31:16]
records after CTRL.sw_trigger. 2 one-shot armed by CTRL.sw_trigger, starting at the first frame whose sum
exceeds TRIG_THRESHOLD. IRQ_STATUS[6] sets when a one-shot ends.

### Loopback BIST

With CTRL.loopback set, an AD7190 emulator drives the DOUT inputs. It answers the core's own SCLK, CS and
SYNC with AD7190 continuous-read timing and sends 32-bit words with a status byte and parity. Channel k sends
`LOOPBACK_VALUE + (k << 16)`, or a frame counter plus `k << 16` in ramp mode. LOOPBACK_CFG injects an ERR bit
or a parity error on one channel. A checker compares each received word with the emulator's and sets FAULT[k]
bit 4 on a mismatch. With a constant pattern, software can predict RESULT and the raw records bit for bit
from the coefficients.

### Programming sequence

1. Read ID. Check [31:8] = 0x4D4C03 and take `N_CH` from [7:0].
2. Wait for STATUS[0] (clocks locked) and IRQ_STATUS[5] (sequencer done). After reset the core runs the
   default list on its own.
3. Check the AD7190 ID answers: SEQ_RESP[k] bits [3:0] read 0x4 for each chip k below `N_CH`.
4. Write OFFSET[k], GAIN[k] and TRIM[k] for each channel.
5. Optional: write 64 FIR coefficients, pulse CTRL.fir_reload, wait for STATUS[2] (reload_busy) to clear.
   The new set takes over between two samples.
6. Write IRQ_ENABLE. On the interrupt, read IRQ_STATUS, write the set bits back to clear them, and read
   RESULT and RESULT_SEQ.
7. Convert RESULT to mass in software: `(RESULT - zero) * span`.

To rerun the default list or run another one: write it to SEQ, write 1 to IRQ_STATUS[5], pulse
CTRL.seq_start, wait for IRQ_STATUS[5].

Calibration in `sw/common/calib.c`: offsets from 1 s of CIC data at no load, corner trims from a test weight
placed over each cell in turn (regularized least squares), span from the test weight's mass.

### Connecting the AD7190s

- One 4.9152 MHz CMOS oscillator drives MCLK2 on every AD7190; MCLK1 stays open. The chips then convert in
  lockstep from the shared SYNC.
- SCLK, DIN, CS_N and SYNC_N go to every chip. Buffer them for more than a few loads: the reference card
  drives four chips from one 74AHC244 output.
- DOUT/RDY of chip k goes to `spi_sdi[k]`.
- DVDD equals the VCCO of the FPGA bank, or the lines need level translators.
- Bridge excitation feeds REFIN1(+) and REFIN1(-) for a ratiometric measurement.
- Input filter per channel: 100 Ω in series per line, 0.1 µF across the pair, 0.01 µF from each line to
  AGND (AD7190 data sheet, p. 38).

## Simulation

Unit tests: cocotb on Icarus Verilog, one folder per RTL module, each checked against a Python model. Each
test builds its module in `build/tb/<module>/`.

```sh
python tb/afe_frontend/test_afe_frontend.py         # one module
for t in tb/*/test_*.py; do python "$t"; done       # all
```

System test: `mclp_core` with one AD7190 model per channel, about 180 ms of simulated time. Covers the init
list, bit-exact records at taps 0 and 3, static weight and stability, the result interrupt, overload, the
loopback BIST with ERR injection, the burnout and reference self-test, and FIR reload. Ends with
`SYSTEM TEST PASSED` or `FAILED`. Runs in the Vivado simulator (Run Simulation in the project) or Icarus:

```sh
mkdir -p build/tb/system && cp coeff/*.mem build/tb/system/
iverilog -g2012 -s mclp_top_tb -o build/tb/system/sys.vvp tb/system/*.sv rtl/*.sv tb/common/xpm_models.sv
cd build/tb/system && vvp -n sys.vvp
```

`-P mclp_top_tb.N_CH=64` on the `iverilog` line runs it at another channel count. At 64 channels the run takes
about 20 minutes.

DMA test: the reference block design with the PS7 verification IP, in the Vivado simulator. It checks the ID,
then one raw record from the core through the AXI DMA into DDR.

```sh
vivado -mode batch -source tcl/mclp.tcl -tclargs --project_name mclp_dma --sim dma --simulate
```

Calibration math in `sw/common` (FIR design, corner trim solver, Q2.30, checksum), on the PC:

```sh
gcc -O2 -Isw/common -o build/test_calib sw/common/test/test_calib.c sw/common/calib.c -lm
build/test_calib
```

## Reference design: ZC702

`tcl/mclp_top_bd.tcl` builds the block design `mclp_top` on the ZC702 (`xc7z020clg484-1`):

| Block | Configuration |
|---|---|
| `processing_system7_0` | ZC702 preset; FCLK0 100 MHz; GP0, HP0, IRQ_F2P |
| `smartconnect_0` | GP0 to the core's registers and the DMA control port |
| `axi_dma` | S2MM, scatter-gather; control at 0x4040_0000 |
| `smartconnect_1` | DMA descriptors and data to HP0 |
| `clk_wiz` | 20 MHz and 50 MHz from FCLK0, reset by the PS reset |
| `mclp_core_0` | `N_CH = 8`, registers at 0x43C0_0000 |
| `irq_concat` | IRQ_F2P[0] DMA, IRQ_F2P[1] core |

Placed and routed, the whole design takes 7,724 LUTs, 12,900 FFs, 11.5 block RAM tiles and 11 DSP48E1.

### Hardware

- ZC702 evaluation board (EK-Z7-ZC702-G) with its 12 V supply and USB cables
- ADC card with eight AD7190 on an FMC LPC connector: [hw/adc-card](hw/adc-card/README.md)
- Eight bridge load cells
- microSD card, 4 GB or larger
- For the one-time VADJ change: TI USB Interface Adapter (USB-TO-GPIO or USB-TO-GPIO2) and a Windows PC with
  TI Fusion Digital Power Designer

### Set VADJ to 3.3 V

The card uses 3.3 V logic. The ZC702 ships with VADJ at 2.5 V. VADJ supplies PL banks 13, 33, 34 and 35:
both FMC connectors, the PMOD headers, the HDMI codec interface and the user switches (UG850 Table 1-3).
Regulator U19 makes VADJ under control of UCD9248 U33, PMBus address 53, rail 1 (UG850 Table 1-30). The setting
is stored in U33 and needs to be made once per board.

> [!WARNING]
> A wrong PMBus write can shut down rails or overvolt the SoC I/O. Change one value at a time and read it back.
> The absolute maximum VCCO of the Zynq-7000 HR banks is 3.6 V (DS187).

| PMBus value | Factory, 2.5 V | New, 3.3 V |
|---|---|---|
| VOUT_OV_FAULT_LIMIT | 2.875 V | 3.6 V |
| VOUT_COMMAND | 2.5 V | 3.3 V |
| POWER_GOOD_ON | 2.25 V | 2.97 V |
| POWER_GOOD_OFF | 2.125 V | 2.805 V |

Factory values from UG850 Table 1-32. The new power-good thresholds keep the factory ratios, 0.90 and 0.85 of
nominal. Scale the OV warn, UV warn, UV fault and margin limits by 3.3/2.5 and keep OV warn below 3.6 V.
VOUT_MAX must be 3.3 V or higher.

1. Power the board off. Leave jumper J12 installed (factory default). With J12 installed, U33 turns VADJ on at
   power-up.
2. Connect the TI adapter to PMBus header J59 and to the PC.
3. Power the board on and start Fusion Digital Power Designer. The Fusion Manufacturing tool from the same
   suite fails to configure the ZC702 controllers (TI E2E).
4. Scan the bus. Fusion finds three UCD9248 controllers, at addresses 52, 53 and 54. Select address 53, rail 1.
5. Raise the limits ahead of the output: margin high and low, OV warn and OV fault, VOUT_COMMAND, then UV warn,
   UV fault and the power-good thresholds. Click Write to Hardware after each change.
6. Click Store RAM to Flash. Values left in RAM are lost at the next power cycle.
7. Power-cycle the board. Check 3.3 V in the Fusion monitor view and with a meter.

To return to 2.5 V, apply the factory values in reverse order: power-good and UV thresholds, VOUT_COMMAND,
then the OV limits. Store to flash.

Without the TI adapter, PS software can set VADJ at every boot. With J12 removed, VADJ stays off at power-up.
The software writes the U33 values over PMBus, then pulls FMC_VADJ_ON_B low through the TCA6416 port expander
U80, pin 13, behind the PCA9548 I2C switch (UG850, VADJ Voltage Control). The repository does not implement
it.

### FMC pinout

The card plugs into FMC1 (J3, LPC). All 12 signals are in bank 34, LVCMOS33.

| Signal | Dir | FMC net | J3 pin | Ball |
|---|---|---|---|---|
| `spi_sclk` | out | LA00_CC_P | G6 | K19 |
| `spi_sdo` | out | LA00_CC_N | G7 | K20 |
| `spi_cs_n` | out | LA01_CC_P | D8 | N19 |
| `adc_sync_n` | out | LA01_CC_N | D9 | N20 |
| `spi_sdi[0]` | in | LA02_P | H7 | L21 |
| `spi_sdi[1]` | in | LA02_N | H8 | L22 |
| `spi_sdi[2]` | in | LA03_P | G9 | J20 |
| `spi_sdi[3]` | in | LA03_N | G10 | K21 |
| `spi_sdi[4]` | in | LA04_P | H10 | M21 |
| `spi_sdi[5]` | in | LA04_N | H11 | M22 |
| `spi_sdi[6]` | in | LA05_P | D11 | N17 |
| `spi_sdi[7]` | in | LA05_N | D12 | N18 |

Card power: AD7190 DVDD from the FMC VADJ pins (G39, H40). 5 V AVDD and bridge excitation regulated from
VCC12_P (C35, C37): 6.75 mA per AD7190 (data sheet maximum, gain 128, buffer on) plus 15 mA per 350 Ω bridge,
174 mA for eight channels.

Load cell k connects to AD7190 k (AIN1/AIN2). The corner calibration refers to the cells by these numbers.

### Prebuilt images

Files in each release:

| File | Content |
|---|---|
| `BOOT.BIN` | First-stage boot loader, bitstream, U-Boot and its device tree |
| `boot.scr` | U-Boot script that boots `image.ub` |
| `image.ub` | Linux kernel and device tree |
| `rootfs.tar.gz` | Root file system with `mclp`, `mclpd`, the boot script and their settings |
| `system.dtb` | Device tree alone, for a custom kernel or boot setup (`image.ub` has a copy) |

The SD card has a FAT32 boot partition and an ext4 root partition. Calibration and settings are stored on the
ext4 partition and survive a power cycle. Prepare the card on a Linux PC. `lsblk` shows its device name:
`/dev/sdX` on a USB reader, `/dev/mmcblk0` with partitions `p1` and `p2` on a built-in reader. The commands
erase the device they are given.

```sh
sudo parted -s /dev/sdX mklabel msdos mkpart primary fat32 4MiB 516MiB mkpart primary ext4 516MiB 100% set 1 boot on
sudo mkfs.vfat -F 32 -n BOOT /dev/sdX1
sudo mkfs.ext4 -L rootfs /dev/sdX2
sudo mount /dev/sdX1 /mnt && sudo cp BOOT.BIN boot.scr image.ub /mnt && sudo umount /mnt
sudo mount /dev/sdX2 /mnt && sudo tar -xzpf rootfs.tar.gz -C /mnt && sudo umount /mnt
```

1. Set SW16 to SD boot: positions 3 and 4 at 1, the others at 0 (UG850 Table 1-2).
2. Connect the USB-UART port (J17, CP210x) at 115200 8N1.
3. Insert the card and power on. Log in as `petalinux`. The first login asks for a new password, which `sudo`
   then uses.

At boot, `/etc/init.d/mclp` loads the UIO driver and runs `mclp init`: ID check, calibration load, AD7190
power-up list. The boot log shows the eight chip IDs. Then it starts `mclpd`. First checks on the board:

```sh
sudo mclp status        # ID 4D4C0308, clocks locked, sequencer streaming
sudo mclp bist          # loopback BIST through the whole capture path
sudo mclp selftest      # per channel: open wire, missing reference, offset and noise
```

[sw/linux/README.md](sw/linux/README.md) documents `mclp` (console commands, calibration) and `mclpd` (REST
and MQTT).

### Build from source

Tools: Vivado 2025.1; PetaLinux 2025.1 on a Linux host or Vitis 2025.1 for bare metal; Python 3, cocotb 2.x
and Icarus Verilog 12 for the tests.

Vivado project, bitstream and hardware description (XSA):

```sh
vivado -mode batch -source tcl/mclp.tcl
vivado build/mclp/mclp.xpr
```

`tcl/mclp.tcl` packages the core into `build/ip_repo`, creates the project in `build/`, adds `xdc/` and sources
every `tcl/*_bd.tcl`. The top is `mclp_top_wrapper`. `rtl/`, `tb/system/` and `coeff/*.mem` go into the
simulation set. Delete `build/` to start over.

| Option, after `-tclargs` | Default |
|---|---|
| `--project_name <name>` | `mclp` |
| `--build_dir <path>` | `<repo>/build` |
| `--origin_dir <path>` | parent directory of `tcl/` |
| `--sim system` or `--sim dma` | `system`: simulation set for the system test or the DMA test |
| `--simulate` | off: run the simulation after creating the project |

In the Vivado Tcl console:

```tcl
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
write_hw_platform -fixed -include_bit -force -file build/mclp.xsa
```

Linux image: [sw/linux/README.md](sw/linux/README.md) builds it from the XSA with PetaLinux.

Bare metal: `sw/baremetal` is a standalone application for Cortex-A9 core 0 with the same console commands. It
stores the calibration in `0:/mclp.cal` on the SD card.

```sh
vitis -s sw/baremetal/build.py          # Vitis workspace in build/vitis, writes build/vitis/jtag.tcl and build/sd/BOOT.BIN
```

Run it over JTAG (SW16 all 0) with `xsdb build/vitis/jtag.tcl`, or from an SD card (SW16 positions 3 and 4 at
1) holding `build/sd/BOOT.BIN`. The console prompt is `mclp>` on the USB-UART at 115200 8N1.

## Porting

### Another channel count in the reference design

Set `N_CH` on `mclp_core_0`, make the `spi_sdi` port as wide (port property `LEFT`), give every `spi_sdi` bit
a pin in `xdc/mclp_pins.xdc`, and export the block design with `write_bd_tcl -force tcl/mclp_top_bd.tcl`.
`mclp` and `mclpd` read `N_CH` from the ID register. A calibration stored for another channel count is not
loaded.

### Another Zynq-7000 board

1. Set `part` and `board_part` at the top of `tcl/mclp.tcl`.
2. Regenerate the PS7 configuration (DDR timing, MIO, clocks): open the block design, run block automation
   with the board preset, keep the PL-side ports, export with `write_bd_tcl`.
3. Map the 12 ADC signals to the board's pins in `xdc/`. Bank VCCO must equal the card's DVDD.
4. FCLK0 is 100 MHz. Another FCLK0 needs the matching input frequency on `clk_wiz`.

### Zynq UltraScale+ MPSoC

Replace `processing_system7` with `zynq_ultra_ps_e` and remap: M_AXI_GP0 to M_AXI_HPM0_FPD, S_AXI_HP0 to
S_AXI_HP0_FPD, IRQ_F2P to pl_ps_irq0, FCLK_CLK0 to pl_clk0. The register window moves into the HPM0_FPD
address range. HP I/O banks stop at 1.8 V. Put the ADC signals on HD banks (up to 3.3 V) or add translators.

### FPGA without a hard processor

Drive `s_axi` from MicroBlaze or a host bridge (UART, PCIe). Point the AXI DMA at a MIG DDR controller.

### Carriers with a fixed VADJ

VITA 57.1 lets the carrier set VADJ, and many carriers fix it at 1.8 V or 2.5 V. On those, the ADC card needs
level translators powered from VADJ on the FPGA side and 3.3 V on the AD7190 side.

## Source files

```
rtl/mclp_core.sv          Core top level: reset synchronizers, CDC FIFOs, the three blocks below
rtl/mclp_registers.sv     Register file and memories, clock-domain crossings, interrupt (aclk)
rtl/axil_bram_ctrl.sv     AXI4-Lite to register port
rtl/afe_frontend.sv       ADC front end (clk_spi): SPI, sequencer, loopback, TDM mux
rtl/afe_spi.sv            SPI master with N_CH receive lanes
rtl/afe_sequencer.sv      Command sequencer
rtl/afe_loopback.sv       AD7190 emulator and checker for the BIST
rtl/tdm_mux.sv            Lanes to one channel-tagged stream
rtl/mclp_dsp.sv           Processing chain (clk_dsp), sticky faults, raw tap select
rtl/mclp_cic.sv           CIC decimator, R = 8, N = 3
rtl/ch_scale.sv           Per-channel Q2.30 scaling: gain/offset, trim
rtl/sat_sum.sv            Channel sum, overload
rtl/mclp_fir.sv           64-tap FIR with two coefficient banks
rtl/coef_reload.sv        FIR coefficient reload from RAM
rtl/stability_detect.sv   Stability flag
rtl/wim_estimator.sv      Weigh-in-motion
rtl/raw_capture.sv        Raw records and triggers
coeff/fir64.py            Default FIR coefficients, writes fir64.mem
coeff/seq_init.py         Default sequencer list and unity gain image: seq_init.mem, unity64.mem, sw/common/seq_init.h
tcl/package_ip.tcl        Packages the core as mclp:ip:mclp_core:1.0
tcl/mclp.tcl              Vivado project of the reference design
tcl/mclp_top_bd.tcl       Reference block design
xdc/mclp_pins.xdc         ZC702 pins
xdc/mclp_timing.xdc       ADC pin false paths
tb/<module>/              cocotb unit tests
tb/common/xpm_models.sv   XPM models for Icarus
tb/system/                System test, AD7190 model, block design stand-in
tb/dma/                   DMA test
sw/common/                Register operations, calibration, console commands (bare metal and Linux)
sw/baremetal/             Bare-metal console and its Vitis build script
sw/linux/                 PetaLinux project, meta-mclp layer, mclp and mclpd
hw/adc-card/              8-channel AD7190 FMC card, KiCad
docs/architecture.drawio  Block diagram with instance names and clock-domain crossings
```

### Changing the design

- Block design: edit it in Vivado, then `write_bd_tcl -force tcl/mclp_top_bd.tcl`. A new block design goes in
  `tcl/<name>_bd.tcl`.
- Core RTL, constraints, test benches: add the file to its folder and rerun `tcl/mclp.tcl`, which packages the
  core again.
- Default sequencer list: edit `coeff/seq_init.py` and run it.
