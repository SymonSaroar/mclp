/*
 * Register map of rtl/mclp_registers.sv and the AXI DMA used for raw capture.
 * Addresses come from the address map in tcl/zynq_ps_bd.tcl. Keep this file in step with the RTL.
 */
#ifndef MCLP_REGS_H
#define MCLP_REGS_H

#define MCLP_BASE        0x43C00000u   /* M_AXI_REGS on GP0 */
#define DMA_BASE          0x40400000u   /* axi_dma S_AXI_LITE */

#define MAX_CH            64            /* channels the map and records allow; ID[7:0] gives the build's */
#define FIR_TAPS          64
#define SEQ_WORDS         256
#define CIC_RATE_HZ       600.0         /* 4800 SPS / 8 */
#define FPGA_ID_MAP       0x4D4C0300u   /* "ML" (MCLP), register map version 3; [7:0] channels */
#define ID_CHANNELS(id)   ((unsigned)(id) & 0xFFu)

/* Registers (byte offsets from MCLP_BASE) */
#define REG_ID            0x000u
#define REG_CTRL          0x004u
#define REG_STATUS        0x008u
#define REG_IRQ_STATUS    0x00Cu        /* write 1 to clear */
#define REG_IRQ_ENABLE    0x010u
#define REG_RESULT        0x020u
#define REG_RESULT_SEQ    0x024u
#define REG_WIM_SUM_LO    0x028u
#define REG_WIM_SUM_HI    0x02Cu
#define REG_WIM_COUNT     0x030u
#define REG_STAB_BAND     0x034u
#define REG_STAB_COUNT    0x038u
#define REG_WIM_ENTER     0x03Cu
#define REG_WIM_EXIT      0x040u
#define REG_WIM_SETTLE    0x044u
#define REG_RESULT_DECIM  0x048u
#define REG_TRIG_CFG      0x04Cu
#define REG_TRIG_THRESH   0x050u
#define REG_LB_CFG        0x054u
#define REG_LB_VALUE      0x058u
#define REG_FIR(i)        (0x200u + 4u * (unsigned)(i))     /* coefficient i, 18-bit signed */
#define REG_SEQ(i)        (0x400u + 4u * (unsigned)(i))
/* per-channel arrays: one 64-word block each */
#define REG_SEQ_RESP(ch)  (0x800u + 4u * (unsigned)(ch))
#define REG_GAIN(ch)      (0x900u + 4u * (unsigned)(ch))    /* Q2.30 */
#define REG_OFFSET(ch)    (0xA00u + 4u * (unsigned)(ch))    /* CIC units */
#define REG_TRIM(ch)      (0xB00u + 4u * (unsigned)(ch))    /* Q2.30 */
#define REG_FAULT(ch)     (0xC00u + 4u * (unsigned)(ch))

/* CTRL: level bits read back, pulse bits read as 0 */
#define CTRL_ENABLE       (1u << 0)
#define CTRL_LOOPBACK     (1u << 1)
#define CTRL_FIR_RELOAD   (1u << 2)     /* pulse */
#define CTRL_SEQ_START    (1u << 3)     /* pulse */
#define CTRL_TAP_SHIFT    4
#define CTRL_TAP_MASK     (3u << 4)     /* 0 AFE words, 1 CIC, 2 gain/offset, 3 trim */
#define CTRL_RAW_ENABLE   (1u << 6)
#define CTRL_SW_TRIGGER   (1u << 7)     /* pulse */
#define CTRL_FAULT_CLEAR  (1u << 8)     /* pulse */

/* STATUS */
#define ST_LOCKED         (1u << 0)
#define ST_SEQ_BUSY       (1u << 1)     /* low once the list reaches STREAM */
#define ST_RELOAD_BUSY    (1u << 2)
#define ST_OVERLOAD       (1u << 3)
#define ST_STABLE         (1u << 4)
#define ST_CAPTURE        (1u << 5)

/* IRQ_STATUS / IRQ_ENABLE */
#define IRQ_RESULT        (1u << 0)
#define IRQ_STABLE        (1u << 1)     /* stable rising */
#define IRQ_WIM           (1u << 2)
#define IRQ_OVERLOAD      (1u << 3)     /* overload rising */
#define IRQ_FAULT         (1u << 4)     /* new fault bit */
#define IRQ_SEQ_DONE      (1u << 5)
#define IRQ_CAPTURE_DONE  (1u << 6)

/* FAULT[ch], sticky until CTRL_FAULT_CLEAR */
#define FLT_ERR           (1u << 0)     /* over-range, open wire with burnout, missing reference */
#define FLT_NOREF         (1u << 1)
#define FLT_PARITY        (1u << 2)
#define FLT_STALE         (1u << 3)     /* RDY bit set in the status byte */
#define FLT_MISMATCH      (1u << 4)     /* loopback checker */

/* LOOPBACK_CFG; lane k sends LOOPBACK_VALUE + (k << 16) in constant mode */
#define LB_RAMP           (1u << 0)
#define LB_INJECT_ERR     (1u << 1)
#define LB_INJECT_PARITY  (1u << 2)
#define LB_CH(ch)         ((unsigned)(ch) << 4)     /* [9:4] */
#define LB_PERIOD(n)      ((unsigned)(n) << 16)
#define LB_PERIOD_4800    4166u         /* clk_spi cycles per frame at 20 MHz */

/* TRIG_CFG */
#define TRIG_CONTINUOUS   0u
#define TRIG_ONESHOT      1u            /* TRIG_FRAMES records after CTRL_SW_TRIGGER */
#define TRIG_LEVEL        2u            /* armed by CTRL_SW_TRIGGER, starts when the sum passes TRIG_THRESH */
#define TRIG_FRAMES(n)    ((unsigned)(n) << 16)

/* Sequencer: two words per command, w0 = {op, ntx, nrx, arg}, w1 = bits shifted out MSB first */
#define SEQ_END           0u
#define SEQ_XFER          1u
#define SEQ_SYNC          2u
#define SEQ_WAIT_US       3u
#define SEQ_WAIT_RDY      4u
#define SEQ_STREAM        5u
#define SEQ_CMD(op, ntx, nrx, arg) \
	(((unsigned)(op) << 28) | ((unsigned)(ntx) << 22) | ((unsigned)(nrx) << 16) | (unsigned)(arg))

/* AD7190 commands and configuration bits (datasheet register layout) */
#define AD_WR_CONFIG      0x10000000u   /* communications byte, MSB aligned for a 32-bit XFER */
#define AD_EXIT_CREAD     0x58000000u
#define AD_ENTER_CREAD    0x5C000000u
#define AD_CFG_BURN       0x000080u
#define AD_CFG_CH0        0x000100u     /* AIN1-AIN2 */
#define AD_CFG_SHORT      0x000800u     /* CH3, AIN2-AIN2 */
#define AD_LSB_NV         4.657         /* 2 x 5 V / 128 / 2^24, in nV */

/* AXI DMA S2MM (PG021), scatter-gather */
#define S2MM_DMACR        0x30u
#define S2MM_DMASR        0x34u
#define S2MM_CURDESC      0x38u
#define S2MM_TAILDESC     0x40u
#define DMACR_RS          (1u << 0)
#define DMACR_RESET       (1u << 2)
#define DMACR_CYCLIC      (1u << 4)
#define DMASR_HALTED      (1u << 0)
#define DMASR_ERRORS      0x770u        /* internal, slave, decode errors on data and SG */
#define BD_CMPLT          (1u << 31)
#define BD_LEN_MASK       0x3FFFFFFu

#endif
