# ADC card: reference design

The analog front end for MCLP: eight AD7190 24-bit ΔΣ ADCs, one per load cell, on an FMC LPC mezzanine
that plugs into FMC1 (J3) of the ZC702. This folder holds the design: this specification, the KiCad
schematic and board, and the files a board house needs to make and assemble it.

State: schematic and 4-layer layout in KiCad 10, schematic checked against the FPGA pin constraints and the
AD7190 pin table. Nothing has been built.

## Files

| File | Content |
|---|---|
| `mclp_adc.kicad_pro` | KiCad project: open this |
| `mclp_adc.kicad_sch` | root sheet: interface, power and the eight channel sheets |
| `interface.kicad_sch` | FMC connector, FRU EEPROM, clock and SPI distribution |
| `power.kicad_sch` | buck converter, LDOs, DVDD filter |
| `channel.kicad_sch` | one load-cell channel, used eight times (sheets CH0..CH7) |
| `mclp_adc.kicad_sym`, `sym-lib-table` | project symbols: AD7190, FMC LPC connector |
| `mclp_adc.kicad_pcb` | board: 184 × 100 mm, 4 layers |
| `mclp_adc.kicad_jobset` | checks and fabrication outputs, run from KiCad ([Manufacture](#manufacture)) |
| `fab/mclp_adc-gerbers.zip` | Gerber and drill files for the board house |
| `fab/mclp_adc-bom.csv` | bill of materials, grouped by value, footprint and part number |
| `fab/mclp_adc-all-pos.csv` | position of every part to place, both sides (J1 on the bottom) |
| `fab/mclp_adc-schematic.pdf` | schematic, for reading without KiCad |

- Footprints all come from KiCad 10's standard libraries; nothing else needs installing.
- Each chip sits in a dashed box, wired to its own resistors and capacitors. Boxes and sheets connect
  through net labels: pins and wires with the same label are connected.
- Reference designators: interface 1..39, power 50..69, channel k in the hundreds k + 1 (CH0: U101, J101,
  R101..). The channel sheets are instances of one sheet, so KiCad's multichannel tools (rule areas from
  sheets, then repeat layout) can copy one placed and routed channel to the other seven.

## Overview

```
 FMC LPC (J1)                                                             front edge
 12P0V ──► TPS54202 buck 6.0 V ──► ADP7118 5.0 V ─┬─ AVDD ───────────────► 8 × AD7190 AVDD
                                                  └─ net tie ── EXC_5V ──► 8 × polyfuse ──► EXC+ of each cell
 VADJ (3.3 V) ── ferrite ── DVDD ──► 8 × AD7190 DVDD, buffers, oscillator
 3P3VAUX ──► FRU EEPROM (I2C)

 LA00_P/N, LA01_P/N ── SCLK, DIN, CS_N, SYNC_N ──► 74AHC244 ──► group A (ADC 0..3), group B (ADC 4..7)
 4.9152 MHz oscillator ──► 74AHC244 (1 in, 8 out) ──► MCLK2 of ADC 0..7
 LA02..LA05 P/N ◄── DOUT/RDY of ADC 0..7

 per channel n:  7-pin terminal block ── ESD ── RC filters ── AD7190 #n
                 EXC+  SENSE+  SIG+  SIG-  SENSE-  EXC-  SHIELD
```

- 6-wire load cells: the AD7190 reference is taken from the sense lines at the cell, so the cable's
  resistance and its drift drop out of the ratio. Two solder jumpers per channel tie sense to excitation for
  4-wire cells.
- Ratiometric: excitation and reference come from the same source, so excitation drift and noise cancel.
  AVDD comes from the same regulator, so the reference can never sit above AVDD.
- All eight converters run from one 4.9152 MHz oscillator and one SYNC line, so they sample together.

## Mechanical

- Connector J1: Samtec FMC LPC mezzanine connector, footprint `Connector_Samtec:Samtec_FMC_ASP-134604-01_4x40_Vertical`
  in KiCad 10. ZC702 users report mating J3 with the ASP-134604 series; listings disagree on its gender and
  the suffix sets the stack height (10 mm clears the ZC702's parts near J3). Check the Samtec drawing against
  the ZC702's J3 part before ordering.
- The card is 184 × 100 mm, larger than the VITA 57.1 single-width outline: J1 on the left edge, four
  7-pin terminal blocks (24.5 mm each at 3.5 mm pitch) on the top edge and four on the bottom edge. Check the
  outline against the ZC702 around J3 (mounting holes, heat sink, other connectors) before ordering.
- Mount the card with the FMC standoffs; the terminal blocks take cable force, so add a support standoff near
  the front edge.

## FMC connections

| Signal | J1 pin | FPGA (ZC702 bank 34) | Card net |
|---|---|---|---|
| LA00_CC_P | G6 | K19 | SCLK (FPGA out) |
| LA00_CC_N | G7 | K20 | DIN (FPGA out) |
| LA01_CC_P | D8 | N19 | CS_N (FPGA out) |
| LA01_CC_N | D9 | N20 | SYNC_N (FPGA out) |
| LA02_P, LA02_N | H7, H8 | L21, L22 | DOUT0, DOUT1 |
| LA03_P, LA03_N | G9, G10 | J20, K21 | DOUT2, DOUT3 |
| LA04_P, LA04_N | H10, H11 | M21, M22 | DOUT4, DOUT5 |
| LA05_P, LA05_N | D11, D12 | N17, N18 | DOUT6, DOUT7 |

| Pin | Use on the card |
|---|---|
| 12P0V (C35, C37) | buck input, 1 A maximum per VITA 57.1 |
| VADJ (G39, H40) | DVDD 3.3 V: the ZC702's VADJ must be set to 3.3 V (README step 1) |
| 3P3VAUX (D32) | FRU EEPROM supply |
| 3P3V (C39, D36, D38, D40) | not used |
| GND (all GND pins) | ground plane |
| PRSNT_M2C_L (H2) | to GND: tells the carrier a card is present |
| TDI (D30), TDO (D31) | linked by R1, 0 Ω: the ZC702 switches the FMC into its JTAG chain when a card is present (UG850, FMC Connector JTAG Bypass) |
| SCL (C30), SDA (C31) | FRU EEPROM U1, 24AA02 in SOT-23: fixed address 0x50, WP to GND; the carrier has the pull-ups |
| PG_C2M (D1), GA0 (C34), GA1 (D35), TCK, TMS, TRST_L, VREF_A_M2C, CLK0/1_M2C, DP0, GBTCLK0, other LA pins | not connected |

## Power

| Rail | Source | Load | Notes |
|---|---|---|---|
| 6V0 | TPS54202 buck from 12P0V | about 170 mA | intermediate rail; the LDO filters its ripple |
| AVDD | ADP7118 U51, 5.0 V | 8 × 6.75 mA = 54 mA maximum | AD7190 analog supply |
| EXC_5V | AVDD through the net tie NT50 | 8 × 14.3 mA = 114 mA with 350 Ω cells | bridge excitation and, through the sense lines, the reference |
| DVDD | VADJ through a ferrite bead | about 15 mA | AD7190 digital supply, buffers, oscillator |

Buck U50 (values from the TPS54202 data sheet, Table 7-2 and section 7.2.3, adapted to 6 V):

- Feedback: 100 kΩ (top) and 11.0 kΩ (bottom), VOUT = 0.596 V × (100/11 + 1) = 6.01 V (5.86 to 6.17 V over the
  reference tolerance). The LDOs need at most 0.42 V of dropout at 200 mA, so 5.86 V still leaves margin.
- Inductor 22 µH, saturation current 1 A or more, shielded. Ripple at 12 V in: 0.27 A peak to peak.
- Output 2 × 22 µF ceramic (X7R or X5R, 16 V), 75 pF across the top feedback resistor.
- Input 10 µF + 100 nF ceramic, 25 V or more. Bootstrap 100 nF between BOOT and SW. EN left open (internal
  pull-up).

LDO U51 (ADP7118, LFCSP-6, fixed 5.0 V; confirm the ordering code in ADI's data sheet) feeds AVDD and the
excitation: 2.2 µF ceramic at input and output, 1 nF soft-start capacitor on SS, EN tied to VIN. The AD7190
works with a reference from 1 V up to AVDD; with excitation and AVDD from two regulators, their tolerances
could put the reference (taken from the excitation) above AVDD. Load: 114 + 54 = 168 mA of the ADP7118's
200 mA. The net tie NT50 at the output capacitor C57 is the star point: AVDD and EXC_5V leave it as separate
traces. A shorted cell pulls AVDD down too until its polyfuse trips; the converters may then reset, and the
firmware reports the fault.

Budget: 170 mA at 6 V is about 1 W; through the buck at roughly 85 % that is about 0.1 A from 12P0V.

Test points: TP50 to TP54 on 12P0V, 6V0, EXC_5V, AVDD, DVDD; TP1 to TP5 on OSC_OUT, MCLK0, SCLK_A, CS_A_N,
DOUT0; TP6, TP55, TP56 on ground (through-hole, for a wire loop).

## Clock and SPI distribution

- X1: 4.9152 MHz 3.3 V CMOS oscillator (Abracon ASE series, 3.2 × 2.5 mm), 100 nF decoupling.
- U2: 74AHC244 with all eight inputs tied to X1 and both OE low. Each output drives one MCLK2 through
  33 Ω (R10..R17). MCLK1 is left open (the firmware selects an external clock on MCLK2).
- U3: 74AHC244. Section 1 drives SCLK, DIN, CS_N, SYNC_N to ADC 0..3, section 2 to ADC 4..7, each output
  through 33 Ω (R20..R27). 10 kΩ pull-ups (R30..R33) to DVDD on all four inputs keep the converters
  deselected and idle while the FPGA is not configured, and no CMOS input floats.
- DOUT/RDY of each AD7190 goes back to its FMC pin through 33 Ω, unbuffered.
- Both buffers run from DVDD (3.3 V), the same level as the FPGA bank.

## Channel circuit (8 times)

Terminal J101..J801 (channel k: J(k+1)01), 7 positions, 3.5 mm pluggable: Phoenix MC 1,5/7-G-3,5 header with
an MC 1,5/7-ST-3,5 plug (KiCad `Connector_Phoenix_MC`):

| Pin | Net | Circuit |
|---|---|---|
| 1 | EXC+ | from EXC_5V through a polyfuse (about 100 mA hold, 0805) |
| 2 | SENSE+ | 100 Ω to REFIN1(+) |
| 3 | SIG+ | 100 Ω to AIN1 |
| 4 | SIG- | 100 Ω to AIN2 |
| 5 | SENSE- | 100 Ω to REFIN1(-) |
| 6 | EXC- | ground |
| 7 | SHIELD | ground, at the terminal |

- Input filter (AD7190 data sheet, weigh-scale application): 100 nF between AIN1 and AIN2, 10 nF from each
  to ground. C0G/NP0 for the 10 nF, C0G or film-grade X7R for the 100 nF.
- Reference filter: the same values on REFIN1(+)/REFIN1(-), so input and reference see the same filter. The
  reference is a switched-capacitor load that draws a sampling current through its two 100 Ω resistors, so
  those are 0.1 %, 25 ppm thin film (Panasonic ERA-3AEB101V): the gain error they cause stays small and
  stable, and the span calibration removes it. Fit 0 Ω instead to connect the sense lines directly. The
  AIN inputs are buffered and draw no current; 1 % resistors are enough there.
- 4-wire cells: solder jumper JP from SENSE+ to EXC+ and from SENSE- to EXC- at the terminal block.
- ESD: TPD4E05U06 on SENSE+, SIG+, SIG-, SENSE- (at the connector, before the 100 Ω); a unidirectional TVS
  with 6 V standoff (SMF6.0A) on EXC+, above the 5 V rail's tolerance. This is ESD-level protection: for long
  cables in industrial sites, add surge protection.
- AD7190 (TSSOP-24): AVDD (20) to AVDD with 100 nF + 10 µF to ground; DVDD (21) to DVDD with 100 nF + 10 µF;
  AGND (18) and DGND (19) to ground at the pins; NC (9), AINCOM (10), AIN3 (13) and AIN4 (14) to ground;
  BPDSW (17), P0..P3 (5 to 8) and MCLK1 (1) open. The firmware never closes BPDSW, so EXC- goes to ground
  directly rather than through it.

Load cell n connects to AD7190 #n, which drives DOUTn: the corner calibration refers to cells by this
number.

## Grounding and layout

Layers: F.Cu carries the parts, the analog lines and local power; In1.Cu is solid ground with nothing routed
on it; In2.Cu carries the power trunks in a ground fill; B.Cu carries the digital buses and J1's fan-out.

- One unbroken ground plane under the whole card; AGND and DGND of each AD7190 join it at the chip, as the
  data sheet recommends. Keep the buck's switching loop (VIN cap, SW, inductor, output caps) compact and away
  from the analog inputs.
- Route each channel's SIG+/SIG- and SENSE+/SENSE- as close pairs from the terminal block through the filter
  to the AD7190, symmetric and short; place the filter capacitors at the converter.
- Keep MCLK, SCLK and DIN away from the analog inputs and over continuous ground; series resistors at the
  driver.
- Place the polyfuse, TVS and ESD array at the terminal block.

## Manufacture

The board, as set up in the KiCad project:

- 4 layers, 1.6 mm FR-4, JLCPCB stackup JLC04161H-7628, 1 oz outer and 0.5 oz inner copper. No impedance
  control: the fastest signals are a 4.9 MHz clock and SPI.
- ENIG finish: the 0.5 mm pitch ESD arrays and the 2 × 2 mm LDO solder better on flat pads than on HASL.
- Tented vias, 0.6 mm with a 0.3 mm hole at the smallest; 0.15 mm minimum gap in the design rules. All of it
  is above JLCPCB's minimums.

### Checks and fabrication files

`mclp_adc.kicad_jobset` holds the checks and every output. After any change to the schematic or board:

1. In the PCB editor, refill the zones (B) and save. The Gerbers are plotted from the saved zone fills.
2. In the KiCad project manager, double-click `mclp_adc.kicad_jobset` and click **Generate All Outputs**.
3. Each output gets a green tick or a red cross. Use `fab/` only when all three have a green tick.

| Output | Jobs | Written to |
|---|---|---|
| Checks | ERC; DRC with zone refill and schematic parity; fails on any error or unconnected item | `build/kicad/checks/` at the top of the repository (reports, not kept) |
| Board fabrication | Gerbers (copper, mask, paste, silkscreen, outline), Excellon drill files with plated and non-plated holes separate | `fab/mclp_adc-gerbers.zip` |
| Assembly and documentation | position file, BOM, schematic PDF | `fab/` |

The same from a terminal, stopping at the first failed job:

```
cd hw/adc-card
kicad-cli jobset run --stop-on-error --file mclp_adc.kicad_jobset mclp_adc.kicad_pro
```

### Ordering at JLCPCB

- Board: upload `fab/mclp_adc-gerbers.zip` and choose the options above. JLCPCB prints its order number on
  the board. To choose where, put the text `JLCJLCJLCJLC` on the silkscreen and select "specify position".
- Assembly: `fab/mclp_adc-bom.csv` and `fab/mclp_adc-all-pos.csv`. If the upload asks for column names:
  Ref is the designator, PosX and PosY are Mid X and Mid Y, Rot is the rotation, Side is the layer. Check
  each part's rotation in JLCPCB's placement preview, because some packages have a different zero angle in
  KiCad.
- Every part needs an LCSC part number (see open items). Check stock for the AD7190, the ADP7118 and J1.
- J1 is the only part on the bottom side, and its 160 contacts sit under the body where an iron cannot reach.
  Supply it to the assembler, or have it reflowed separately.
- The position file leaves out what is not placed: fiducials, mounting holes, solder jumpers, the net tie
  and the test points. TP6, TP55 and TP56 take a wire loop, soldered by hand.

## Open items

- Samtec part number and stack height for J1 (gender and suffix) against the ZC702.
- Card outline, J1 position and mounting holes against the ZC702 around J3 (the hole positions are
  placeholders until checked).
- FRU EEPROM contents: VITA 57.1 expects FRU data; the ZC702 runs without it (VADJ is set by hand).
- Buck at light load: whether the TPS54202 skips pulses at about 170 mA, and how much of the 22 µF output
  capacitance remains at 6 V DC bias; check against TI's data sheet.
- SCLK, DIN, CS and SYNC: one buffer output drives four converters; measure SCLK at the farthest converter on
  the first board (fallback: a third 74AHC244 for point-to-point clocks).
- LCSC part numbers for assembly at JLCPCB.
- ADP7118 fixed-5.0 V ordering code; Abracon ASE ordering code for 4.9152 MHz.
- Inductor: the SRN6045TA footprint is a placeholder; any shielded 22 µH part with 1 A or more saturation
  current fits.
- Buck loop stability at the chosen inductor and capacitors: check on the first board.
- Polyfuse hold current against the cells used (one 350 Ω cell draws 14.3 mA; the LDO limits near 200 mA
  for all eight together).
