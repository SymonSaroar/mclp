// Simulation stand-in for the reference block design (same module name and ports as mclp_top_wrapper), for
// the system test: the PS clock and reset, an ideal MMCM and the real mclp_core.
// FCLK0 runs at 100 MHz and the reset releases after 200 ns. clk_spi (20 MHz) and clk_dsp (50 MHz) run from
// then on, and clk_locked rises 1 us later, like clk_wiz; its MMCME2_ADV model toggles a 1 GHz VCO, too slow
// here. The PL clocks wait for the reset because the xpm_cdc_async_rst synchronizers read "not in reset"
// during glbl.GSR (first 100 ns).
// write32/read32 drive the core's AXI4-Lite port (full addresses; the core decodes [15:0]); every raw record
// beat lands in raw_data/raw_last, raw_n counts them. The AXI DMA and DDR are not modelled.
// N_CH exists only here, for testing other channel counts; the block design sets the core's N_CH (8).
`timescale 1ns / 1ps
module mclp_top_wrapper #(
	parameter integer N_CH = 8
) (
	inout  wire [14:0]     DDR_addr,
	inout  wire [2:0]      DDR_ba,
	inout  wire            DDR_cas_n,
	inout  wire            DDR_ck_n,
	inout  wire            DDR_ck_p,
	inout  wire            DDR_cke,
	inout  wire            DDR_cs_n,
	inout  wire [3:0]      DDR_dm,
	inout  wire [31:0]     DDR_dq,
	inout  wire [3:0]      DDR_dqs_n,
	inout  wire [3:0]      DDR_dqs_p,
	inout  wire            DDR_odt,
	inout  wire            DDR_ras_n,
	inout  wire            DDR_reset_n,
	inout  wire            DDR_we_n,
	inout  wire            FIXED_IO_ddr_vrn,
	inout  wire            FIXED_IO_ddr_vrp,
	inout  wire [53:0]     FIXED_IO_mio,
	inout  wire            FIXED_IO_ps_clk,
	inout  wire            FIXED_IO_ps_porb,
	inout  wire            FIXED_IO_ps_srstb,
	output wire            spi_sclk,
	output wire            spi_sdo,
	output wire            spi_cs_n,
	output wire            adc_sync_n,
	input  wire [N_CH-1:0] spi_sdi
);
	reg clk  = 1'b0;
	reg rstn = 1'b0;
	always #5 clk = ~clk;
	initial #200 rstn = 1'b1;

	// Ideal MMCM: outputs low while in reset, locked 100 clk cycles after it
	reg       clk_spi  = 1'b0;
	reg       clk_dsp  = 1'b0;
	reg [6:0] lock_cnt = 7'd0;
	always #25 clk_spi = ~clk_spi & rstn;
	always #10 clk_dsp = ~clk_dsp & rstn;
	always @(posedge clk)
		if (!rstn)                   lock_cnt <= 7'd0;
		else if (lock_cnt != 7'd100) lock_cnt <= lock_cnt + 7'd1;
	wire locked = (lock_cnt == 7'd100);

	// AXI4-Lite master
	reg  [31:0] awaddr = 0, wdata = 0, araddr = 0;
	reg         awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
	wire        M_AXI_REGS_awready, M_AXI_REGS_wready, M_AXI_REGS_bvalid, M_AXI_REGS_arready, M_AXI_REGS_rvalid;
	wire [1:0]  M_AXI_REGS_bresp, M_AXI_REGS_rresp;
	wire [31:0] M_AXI_REGS_rdata;

	// Inputs change on the falling edge; ready/valid are sampled at the rising edge.
	task automatic write32(input [31:0] a, input [31:0] d);
		@(negedge clk);
		awaddr = a; wdata = d; awvalid = 1; wvalid = 1;
		do @(posedge clk); while (!(M_AXI_REGS_awready && M_AXI_REGS_wready));
		@(negedge clk);
		awvalid = 0; wvalid = 0; bready = 1;
		do @(posedge clk); while (!M_AXI_REGS_bvalid);
		@(negedge clk);
		bready = 0;
	endtask

	task automatic read32(input [31:0] a, output [31:0] d);
		@(negedge clk);
		araddr = a; arvalid = 1;
		do @(posedge clk); while (!M_AXI_REGS_arready);
		@(negedge clk);
		arvalid = 0; rready = 1;
		do @(posedge clk); while (!M_AXI_REGS_rvalid);
		d = M_AXI_REGS_rdata;
		@(negedge clk);
		rready = 0;
	endtask

	// Raw record sink in place of the AXI DMA
	wire [63:0] raw_tdata;
	wire        raw_tlast, raw_tvalid;
	reg  [63:0] raw_data [0:8191];
	reg         raw_last [0:8191];
	integer     raw_n = 0;
	always @(posedge clk) if (raw_tvalid && raw_n < 8192) begin
		raw_data[raw_n] <= raw_tdata;
		raw_last[raw_n] <= raw_tlast;
		raw_n           <= raw_n + 1;
	end

	wire irq;

	mclp_core #(
		.N_CH(N_CH)
	) mclp_core_0 (
		.aclk(clk),
		.aresetn(rstn),
		.clk_spi(clk_spi),
		.clk_dsp(clk_dsp),
		.clk_locked(locked),
		.s_axi_awaddr(awaddr[15:0]),
		.s_axi_awprot(3'b000),
		.s_axi_awvalid(awvalid),
		.s_axi_awready(M_AXI_REGS_awready),
		.s_axi_wdata(wdata),
		.s_axi_wstrb(4'hF),
		.s_axi_wvalid(wvalid),
		.s_axi_wready(M_AXI_REGS_wready),
		.s_axi_bresp(M_AXI_REGS_bresp),
		.s_axi_bvalid(M_AXI_REGS_bvalid),
		.s_axi_bready(bready),
		.s_axi_araddr(araddr[15:0]),
		.s_axi_arprot(3'b000),
		.s_axi_arvalid(arvalid),
		.s_axi_arready(M_AXI_REGS_arready),
		.s_axi_rdata(M_AXI_REGS_rdata),
		.s_axi_rresp(M_AXI_REGS_rresp),
		.s_axi_rvalid(M_AXI_REGS_rvalid),
		.s_axi_rready(rready),
		.irq(irq),
		.m_axis_raw_tdata(raw_tdata),
		.m_axis_raw_tlast(raw_tlast),
		.m_axis_raw_tvalid(raw_tvalid),
		.m_axis_raw_tready(1'b1),
		.spi_sclk(spi_sclk),
		.spi_sdo(spi_sdo),
		.spi_cs_n(spi_cs_n),
		.adc_sync_n(adc_sync_n),
		.spi_sdi(spi_sdi)
	);
endmodule
