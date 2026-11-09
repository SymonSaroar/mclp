`default_nettype none

////////////////////////////////////////////////////////////////////////////////
// mclp_top
// MCLP top level: instances and wiring only.
// Clock domains: clk_axi (FCLK0, 100 MHz) for the PS, register file and DMA; clk_spi (20 MHz) and
// clk_dsp (50 MHz) from the MMCM. Control and status cross in mclp_registers. The ADC pins and
// S_AXIS_RAW are idle.
////////////////////////////////////////////////////////////////////////////////
module mclp_top (
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
	input  wire [7:0]   adc_dout
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

	// Clocks and resets
	wire          clk_spi;
	wire          clk_dsp;
	wire          mmcm_locked;
	wire          rst_axi;
	wire          rstn_spi;                       // from the reset synchronizer, active low
	wire          rst_spi   = !rstn_spi;
	wire          rstn_dsp;                       // from the reset synchronizer, active low
	wire          rst_dsp   = !rstn_dsp;
	wire          arst_axi  = !rst_axi_n[0];
	wire          rstn_axi  = !rst_axi;

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

		// Raw records: idle
		.S_AXIS_RAW_tdata(64'd0),
		.S_AXIS_RAW_tkeep(8'hFF),
		.S_AXIS_RAW_tlast(1'b0),
		.S_AXIS_RAW_tvalid(1'b0),
		.S_AXIS_RAW_tready()
	);

/////////////////////////////////////////////////////////////////////////////
//Clocks and resets
/////////////////////////////////////////////////////////////////////////////
	clk_wiz_0 clk_wiz_0 (
		.clk_spi(clk_spi),              // output clk_spi (20 MHz)
		.clk_dsp(clk_dsp),              // output clk_dsp (50 MHz)
		.resetn(rst_axi_n[0]),          // input resetn
		.locked(mmcm_locked),           // output locked
		.clk_in1(clk_axi)               // input clk_in1 (100 MHz)
	);

	xpm_cdc_async_rst #(
		.DEST_SYNC_FF(4),               // DECIMAL; range: 2-10
		.INIT_SYNC_FF(1),               // DECIMAL; 0=disable simulation init values, 1=enable simulation init values
		.RST_ACTIVE_HIGH(1)             // DECIMAL; 0=active low reset, 1=active high reset
	) xpm_cdc_rst_axi_inst (
		.dest_arst(rst_axi),
		.dest_clk(clk_axi),
		.src_arst(arst_axi)
	);

	// The PS reset holds the MMCM in reset (resetn), so locked is low whenever either reset is active.
	// locked goes straight in, active low: no logic in front of the synchronizer (report_cdc).
	xpm_cdc_async_rst #(
		.DEST_SYNC_FF(4),
		.INIT_SYNC_FF(1),
		.RST_ACTIVE_HIGH(0)
	) xpm_cdc_rst_spi_inst (
		.dest_arst(rstn_spi),
		.dest_clk(clk_spi),
		.src_arst(mmcm_locked)
	);

	// The PS reset holds the MMCM in reset (resetn), so locked is low whenever either reset is active.
	// locked goes straight in, active low: no logic in front of the synchronizer (report_cdc).
	xpm_cdc_async_rst #(
		.DEST_SYNC_FF(4),
		.INIT_SYNC_FF(1),
		.RST_ACTIVE_HIGH(0)
	) xpm_cdc_rst_dsp_inst (
		.dest_arst(rstn_dsp),
		.dest_clk(clk_dsp),
		.src_arst(mmcm_locked)
	);

/////////////////////////////////////////////////////////////////////////////
//Register file
/////////////////////////////////////////////////////////////////////////////
	mclp_registers #(
		.FIR_INIT_FILE("fir64.mem"),
		.SEQ_INIT_FILE("seq_init.mem"),
		.UNITY_INIT_FILE("unity8.mem")
	) mclp_registers_0 (
		// AXI4-Lite interface
		.s_axi_aclk(clk_axi),
		.s_axi_aresetn(rstn_axi),
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
		.mmcm_locked(mmcm_locked),

		// Front end (clk_spi)
		.clk_spi(clk_spi),
		.spi_enable(),
		.spi_loopback(),
		.spi_loopback_cfg(),
		.spi_loopback_value(),
		.spi_seq_start(),
		.spi_seq_addr(8'd0),
		.spi_seq_data(),
		.spi_seq_busy(1'b0),
		.spi_seq_resp(256'd0),

		// Processing (clk_dsp)
		.clk_dsp(clk_dsp),
		.dsp_rst(rst_dsp),
		.dsp_stab_band(),
		.dsp_stab_count(),
		.dsp_wim_enter(),
		.dsp_wim_exit(),
		.dsp_wim_settle(),
		.dsp_result_decim(),
		.dsp_trig_cfg(),
		.dsp_trig_threshold(),
		.dsp_raw_tap(),
		.dsp_raw_enable(),
		.dsp_fir_reload(),
		.dsp_sw_trigger(),
		.dsp_fault_clear(),
		.dsp_gain_ch(3'd0),
		.dsp_gain(),
		.dsp_offset(),
		.dsp_trim_ch(3'd0),
		.dsp_trim(),
		.dsp_fir_addr(6'd0),
		.dsp_fir_coef(),
		.dsp_result_new(1'b0),
		.dsp_result(32'd0),
		.dsp_wim_new(1'b0),
		.dsp_wim_sum(64'd0),
		.dsp_wim_count(32'd0),
		.dsp_stable(1'b0),
		.dsp_overload(1'b0),
		.dsp_reload_busy(1'b0),
		.dsp_capture_active(1'b0),
		.dsp_faults(40'd0)
	);

/////////////////////////////////////////////////////////////////////////////
//ADC pins idle
/////////////////////////////////////////////////////////////////////////////
	assign adc_sclk   = 1'b1;
	assign adc_din    = 1'b0;
	assign adc_cs_n   = 1'b1;
	assign adc_sync_n = 1'b1;

endmodule

`default_nettype wire
