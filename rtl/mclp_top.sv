`default_nettype none

////////////////////////////////////////////////////////////////////////////////
// mclp_top
// Reference design on the ZC702: the Zynq PS block design (register access, AXI DMA into DDR, interrupt),
// an MMCM for the core's clocks and mclp_core. Instances and wiring only.
// Clocks: clk_axi (FCLK0, 100 MHz) for the PS side and the core's AXI interfaces; clk_spi (20 MHz) and
// clk_dsp (50 MHz) from the MMCM. The PS reset holds the MMCM in reset, so locked is low whenever it is
// (mclp_core's reset contract).
////////////////////////////////////////////////////////////////////////////////
module mclp_top #(
	parameter integer N_CH = 8              // the ZC702 card has 8; other counts for simulation
) (
	// PS DDR and fixed IO
	inout  wire [14:0]  DDR_addr,
	inout  wire [2:0]   DDR_ba,
	inout  wire         DDR_cas_n,
	inout  wire         DDR_ck_n,
	inout  wire         DDR_ck_p,
	inout  wire         DDR_cke,
	inout  wire         DDR_cs_n,
	inout  wire [3:0]   DDR_dm,
	inout  wire [31:0]  DDR_dq,
	inout  wire [3:0]   DDR_dqs_n,
	inout  wire [3:0]   DDR_dqs_p,
	inout  wire         DDR_odt,
	inout  wire         DDR_ras_n,
	inout  wire         DDR_reset_n,
	inout  wire         DDR_we_n,
	inout  wire         FIXED_IO_ddr_vrn,
	inout  wire         FIXED_IO_ddr_vrp,
	inout  wire [53:0]  FIXED_IO_mio,
	inout  wire         FIXED_IO_ps_clk,
	inout  wire         FIXED_IO_ps_porb,
	inout  wire         FIXED_IO_ps_srstb,

	// AD7190 card on FMC1 (shared SCLK/DIN/CS/SYNC, one DOUT per chip)
	output wire         adc_sclk,
	output wire         adc_din,
	output wire         adc_cs_n,
	output wire         adc_sync_n,
	input  wire [N_CH-1:0] adc_dout
);

	// PS block design (clk_axi)
	wire          clk_axi;
	wire [0:0]    rst_axi_n;
	wire          irq;
	wire [31:0]   m_axi_regs_awaddr;
	wire [2:0]    m_axi_regs_awprot;
	wire          m_axi_regs_awvalid;
	wire          m_axi_regs_awready;
	wire [31:0]   m_axi_regs_wdata;
	wire [3:0]    m_axi_regs_wstrb;
	wire          m_axi_regs_wvalid;
	wire          m_axi_regs_wready;
	wire [1:0]    m_axi_regs_bresp;
	wire          m_axi_regs_bvalid;
	wire          m_axi_regs_bready;
	wire [31:0]   m_axi_regs_araddr;
	wire [2:0]    m_axi_regs_arprot;
	wire          m_axi_regs_arvalid;
	wire          m_axi_regs_arready;
	wire [31:0]   m_axi_regs_rdata;
	wire [1:0]    m_axi_regs_rresp;
	wire          m_axi_regs_rvalid;
	wire          m_axi_regs_rready;
	wire [63:0]   s_axis_raw_tdata;
	wire          s_axis_raw_tlast;
	wire          s_axis_raw_tvalid;
	wire          s_axis_raw_tready;

	// MMCM
	wire          clk_spi;
	wire          clk_dsp;
	wire          mmcm_locked;

/////////////////////////////////////////////////////////////////////////////
//PS block design
/////////////////////////////////////////////////////////////////////////////
	zynq_ps_wrapper zynq_ps_wrapper_0 (
		.DDR_addr(DDR_addr),
		.DDR_ba(DDR_ba),
		.DDR_cas_n(DDR_cas_n),
		.DDR_ck_n(DDR_ck_n),
		.DDR_ck_p(DDR_ck_p),
		.DDR_cke(DDR_cke),
		.DDR_cs_n(DDR_cs_n),
		.DDR_dm(DDR_dm),
		.DDR_dq(DDR_dq),
		.DDR_dqs_n(DDR_dqs_n),
		.DDR_dqs_p(DDR_dqs_p),
		.DDR_odt(DDR_odt),
		.DDR_ras_n(DDR_ras_n),
		.DDR_reset_n(DDR_reset_n),
		.DDR_we_n(DDR_we_n),
		.FIXED_IO_ddr_vrn(FIXED_IO_ddr_vrn),
		.FIXED_IO_ddr_vrp(FIXED_IO_ddr_vrp),
		.FIXED_IO_mio(FIXED_IO_mio),
		.FIXED_IO_ps_clk(FIXED_IO_ps_clk),
		.FIXED_IO_ps_porb(FIXED_IO_ps_porb),
		.FIXED_IO_ps_srstb(FIXED_IO_ps_srstb),

		// Clock, reset, interrupt
		.FCLK_CLK0(clk_axi),
		.peripheral_aresetn(rst_axi_n),
		.mclp_irq(irq),

		// GP0 -> register file (AXI4-Lite)
		.M_AXI_REGS_awaddr(m_axi_regs_awaddr),
		.M_AXI_REGS_awprot(m_axi_regs_awprot),
		.M_AXI_REGS_awvalid(m_axi_regs_awvalid),
		.M_AXI_REGS_awready(m_axi_regs_awready),
		.M_AXI_REGS_wdata(m_axi_regs_wdata),
		.M_AXI_REGS_wstrb(m_axi_regs_wstrb),
		.M_AXI_REGS_wvalid(m_axi_regs_wvalid),
		.M_AXI_REGS_wready(m_axi_regs_wready),
		.M_AXI_REGS_bresp(m_axi_regs_bresp),
		.M_AXI_REGS_bvalid(m_axi_regs_bvalid),
		.M_AXI_REGS_bready(m_axi_regs_bready),
		.M_AXI_REGS_araddr(m_axi_regs_araddr),
		.M_AXI_REGS_arprot(m_axi_regs_arprot),
		.M_AXI_REGS_arvalid(m_axi_regs_arvalid),
		.M_AXI_REGS_arready(m_axi_regs_arready),
		.M_AXI_REGS_rdata(m_axi_regs_rdata),
		.M_AXI_REGS_rresp(m_axi_regs_rresp),
		.M_AXI_REGS_rvalid(m_axi_regs_rvalid),
		.M_AXI_REGS_rready(m_axi_regs_rready),

		// Raw records -> AXI DMA S2MM
		.S_AXIS_RAW_tdata(s_axis_raw_tdata),
		.S_AXIS_RAW_tkeep(8'hFF),
		.S_AXIS_RAW_tlast(s_axis_raw_tlast),
		.S_AXIS_RAW_tvalid(s_axis_raw_tvalid),
		.S_AXIS_RAW_tready(s_axis_raw_tready)
	);

/////////////////////////////////////////////////////////////////////////////
//Clocks
/////////////////////////////////////////////////////////////////////////////
	clk_wiz_0 clk_wiz_0 (
		.clk_spi(clk_spi),              // output clk_spi (20 MHz)
		.clk_dsp(clk_dsp),              // output clk_dsp (50 MHz)
		.resetn(rst_axi_n[0]),          // input resetn
		.locked(mmcm_locked),           // output locked
		.clk_in1(clk_axi)               // input clk_in1 (100 MHz)
	);

/////////////////////////////////////////////////////////////////////////////
//MCLP core
/////////////////////////////////////////////////////////////////////////////
	mclp_core #(
		.N_CH(N_CH)
	) mclp_core_0 (
		.aclk(clk_axi),
		.aresetn(rst_axi_n[0]),
		.clk_spi(clk_spi),
		.clk_dsp(clk_dsp),
		.clk_locked(mmcm_locked),

		.s_axi_awaddr(m_axi_regs_awaddr[11:0]),
		.s_axi_awprot(m_axi_regs_awprot),
		.s_axi_awvalid(m_axi_regs_awvalid),
		.s_axi_awready(m_axi_regs_awready),
		.s_axi_wdata(m_axi_regs_wdata),
		.s_axi_wstrb(m_axi_regs_wstrb),
		.s_axi_wvalid(m_axi_regs_wvalid),
		.s_axi_wready(m_axi_regs_wready),
		.s_axi_bresp(m_axi_regs_bresp),
		.s_axi_bvalid(m_axi_regs_bvalid),
		.s_axi_bready(m_axi_regs_bready),
		.s_axi_araddr(m_axi_regs_araddr[11:0]),
		.s_axi_arprot(m_axi_regs_arprot),
		.s_axi_arvalid(m_axi_regs_arvalid),
		.s_axi_arready(m_axi_regs_arready),
		.s_axi_rdata(m_axi_regs_rdata),
		.s_axi_rresp(m_axi_regs_rresp),
		.s_axi_rvalid(m_axi_regs_rvalid),
		.s_axi_rready(m_axi_regs_rready),
		.irq(irq),

		.m_axis_raw_tdata(s_axis_raw_tdata),
		.m_axis_raw_tlast(s_axis_raw_tlast),
		.m_axis_raw_tvalid(s_axis_raw_tvalid),
		.m_axis_raw_tready(s_axis_raw_tready),

		.adc_sclk(adc_sclk),
		.adc_din(adc_din),
		.adc_cs_n(adc_cs_n),
		.adc_sync_n(adc_sync_n),
		.adc_dout(adc_dout)
	);

endmodule

`default_nettype wire
