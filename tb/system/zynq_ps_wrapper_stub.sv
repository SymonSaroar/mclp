// Simulation stand-in for the block-design wrapper (same module name and ports). FCLK0 runs at
// 100 MHz, reset releases after 200 ns. write32/read32 drive M_AXI_REGS (register offsets); every
// S_AXIS_RAW beat lands in raw_data/raw_last, raw_n counts them. The AXI DMA and DDR are not modelled.
`timescale 1ns / 1ps
module zynq_ps_wrapper (
	inout  wire [14:0] DDR_addr,
	inout  wire [2:0]  DDR_ba,
	inout  wire        DDR_cas_n,
	inout  wire        DDR_ck_n,
	inout  wire        DDR_ck_p,
	inout  wire        DDR_cke,
	inout  wire        DDR_cs_n,
	inout  wire [3:0]  DDR_dm,
	inout  wire [31:0] DDR_dq,
	inout  wire [3:0]  DDR_dqs_n,
	inout  wire [3:0]  DDR_dqs_p,
	inout  wire        DDR_odt,
	inout  wire        DDR_ras_n,
	inout  wire        DDR_reset_n,
	inout  wire        DDR_we_n,
	output wire        FCLK_CLK0,
	inout  wire        FIXED_IO_ddr_vrn,
	inout  wire        FIXED_IO_ddr_vrp,
	inout  wire [53:0] FIXED_IO_mio,
	inout  wire        FIXED_IO_ps_clk,
	inout  wire        FIXED_IO_ps_porb,
	inout  wire        FIXED_IO_ps_srstb,
	output wire [31:0] M_AXI_REGS_araddr,
	output wire [2:0]  M_AXI_REGS_arprot,
	input  wire [0:0]  M_AXI_REGS_arready,
	output wire [0:0]  M_AXI_REGS_arvalid,
	output wire [31:0] M_AXI_REGS_awaddr,
	output wire [2:0]  M_AXI_REGS_awprot,
	input  wire [0:0]  M_AXI_REGS_awready,
	output wire [0:0]  M_AXI_REGS_awvalid,
	output wire [0:0]  M_AXI_REGS_bready,
	input  wire [1:0]  M_AXI_REGS_bresp,
	input  wire [0:0]  M_AXI_REGS_bvalid,
	input  wire [31:0] M_AXI_REGS_rdata,
	output wire [0:0]  M_AXI_REGS_rready,
	input  wire [1:0]  M_AXI_REGS_rresp,
	input  wire [0:0]  M_AXI_REGS_rvalid,
	output wire [31:0] M_AXI_REGS_wdata,
	input  wire [0:0]  M_AXI_REGS_wready,
	output wire [3:0]  M_AXI_REGS_wstrb,
	output wire [0:0]  M_AXI_REGS_wvalid,
	input  wire [63:0] S_AXIS_RAW_tdata,
	input  wire [7:0]  S_AXIS_RAW_tkeep,
	input  wire        S_AXIS_RAW_tlast,
	output wire        S_AXIS_RAW_tready,
	input  wire        S_AXIS_RAW_tvalid,
	output wire [0:0]  peripheral_aresetn,
	input  wire        mclp_irq
);
	reg clk  = 1'b0;
	reg rstn = 1'b0;
	always #5 clk = ~clk;
	initial #200 rstn = 1'b1;
	assign FCLK_CLK0          = clk;
	assign peripheral_aresetn = rstn;

	reg [31:0] awaddr = 0, wdata = 0, araddr = 0;
	reg        awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
	assign M_AXI_REGS_awaddr  = awaddr;
	assign M_AXI_REGS_awprot  = 3'b000;
	assign M_AXI_REGS_awvalid = awvalid;
	assign M_AXI_REGS_wdata   = wdata;
	assign M_AXI_REGS_wstrb   = 4'hF;
	assign M_AXI_REGS_wvalid  = wvalid;
	assign M_AXI_REGS_bready  = bready;
	assign M_AXI_REGS_araddr  = araddr;
	assign M_AXI_REGS_arprot  = 3'b000;
	assign M_AXI_REGS_arvalid = arvalid;
	assign M_AXI_REGS_rready  = rready;

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

	reg   [63:0] raw_data [0:8191];
	reg          raw_last [0:8191];
	integer      raw_n = 0;
	assign S_AXIS_RAW_tready = 1'b1;
	always @(posedge clk) if (S_AXIS_RAW_tvalid && raw_n < 8192) begin
		raw_data[raw_n] <= S_AXIS_RAW_tdata;
		raw_last[raw_n] <= S_AXIS_RAW_tlast;
		raw_n           <= raw_n + 1;
	end
endmodule
