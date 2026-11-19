`default_nettype none

////////////////////////////////////////////////////////////////////////////////
// mclp_core
// The MCLP IP: AD7190 front end, processing and register file, without a processor or clock generation.
// Clock domains: aclk for the AXI4-Lite registers and the raw record stream (100 MHz in the reference
// design), clk_spi (20 MHz) for the AD7190 front end, clk_dsp (50 MHz) for processing. Control and status
// cross in mclp_registers, the sample and record streams through the two XPM FIFOs here.
// N_CH (1 to 64) AD7190 chips, one per load cell; the ID register reports the number.
// Resets: aresetn resets the aclk domain; clk_spi and clk_dsp stay in reset while clk_locked is low.
// clk_locked must also be low while aresetn is (the reference design resets its MMCM with
// aresetn); synchronize both into each domain if a design needs them independent.
////////////////////////////////////////////////////////////////////////////////
module mclp_core #(
	parameter integer N_CH = 8              // channels, 1 to 64
) (
	// Clocks and resets
	input  wire         aclk,
	input  wire         aresetn,            // asynchronous, active low
	input  wire         clk_spi,            // 20 MHz
	input  wire         clk_dsp,            // 50 MHz
	input  wire         clk_locked,         // clk_spi and clk_dsp running; asynchronous

	// Register file (AXI4-Lite, 4 KB, aclk)
	input  wire [11:0]  s_axi_awaddr,
	input  wire [2:0]   s_axi_awprot,
	input  wire         s_axi_awvalid,
	output wire         s_axi_awready,
	input  wire [31:0]  s_axi_wdata,
	input  wire [3:0]   s_axi_wstrb,
	input  wire         s_axi_wvalid,
	output wire         s_axi_wready,
	output wire [1:0]   s_axi_bresp,
	output wire         s_axi_bvalid,
	input  wire         s_axi_bready,
	input  wire [11:0]  s_axi_araddr,
	input  wire [2:0]   s_axi_arprot,
	input  wire         s_axi_arvalid,
	output wire         s_axi_arready,
	output wire [31:0]  s_axi_rdata,
	output wire [1:0]   s_axi_rresp,
	output wire         s_axi_rvalid,
	input  wire         s_axi_rready,
	output wire         irq,                // level, aclk

	// Raw records (AXI4-Stream, 64 bit, aclk), to a DMA
	output wire [63:0]  m_axis_raw_tdata,
	output wire         m_axis_raw_tlast,
	output wire         m_axis_raw_tvalid,
	input  wire         m_axis_raw_tready,

	// AD7190 chips (shared SCLK/DIN/CS/SYNC, one DOUT per chip)
	output wire         adc_sclk,
	output wire         adc_din,
	output wire         adc_cs_n,
	output wire         adc_sync_n,
	input  wire [N_CH-1:0] adc_dout
);

	// Resets, each from its synchronizer, active low
	wire          rstn_axi;
	wire          rstn_spi;
	wire          rst_spi   = !rstn_spi;
	wire          rstn_dsp;
	wire          rst_dsp   = !rstn_dsp;

	// Register file to front end (clk_spi)
	wire          spi_enable;
	wire          spi_loopback;
	wire [31:0]   spi_loopback_cfg;
	wire [23:0]   spi_loopback_value;
	wire          spi_seq_start;
	wire [7:0]    spi_seq_addr;
	wire [31:0]   spi_seq_data;
	wire          spi_seq_busy;
	wire [32*N_CH-1:0] spi_seq_resp;

	// Register file to processing (clk_dsp)
	wire [31:0]   dsp_stab_band;
	wire [31:0]   dsp_stab_count;
	wire [31:0]   dsp_wim_enter;
	wire [31:0]   dsp_wim_exit;
	wire [31:0]   dsp_wim_settle;
	wire [31:0]   dsp_result_decim;
	wire [31:0]   dsp_trig_cfg;
	wire [31:0]   dsp_trig_threshold;
	wire [1:0]    dsp_raw_tap;
	wire          dsp_raw_enable;
	wire          dsp_fir_reload;
	wire          dsp_sw_trigger;
	wire          dsp_fault_clear;
	wire [5:0]    dsp_gain_ch;
	wire [31:0]   dsp_gain;
	wire [31:0]   dsp_offset;
	wire [5:0]    dsp_trim_ch;
	wire [31:0]   dsp_trim;
	wire [5:0]    dsp_fir_addr;
	wire [31:0]   dsp_fir_coef;
	wire          dsp_result_new;
	wire [31:0]   dsp_result;
	wire          dsp_wim_new;
	wire [63:0]   dsp_wim_sum;
	wire [31:0]   dsp_wim_count;
	wire          dsp_stable;
	wire          dsp_overload;
	wire          dsp_reload_busy;
	wire          dsp_capture_active;
	wire [5*N_CH-1:0] dsp_faults;

	// Sample stream (clk_spi -> clk_dsp) and record stream (clk_dsp -> aclk)
	wire          fe_tvalid;
	wire          fe_tready;
	wire [87:0]   fe_tdata;
	wire          fe_tlast;
	wire          smp_tvalid;
	wire          smp_tready;
	wire [87:0]   smp_tdata;
	wire          smp_tlast;
	wire          rec_tvalid;
	wire [63:0]   rec_tdata;
	wire          rec_tlast;
	wire          rec_prog_full;

/////////////////////////////////////////////////////////////////////////////
//Resets
/////////////////////////////////////////////////////////////////////////////
	xpm_cdc_async_rst #(
		.DEST_SYNC_FF(4),               // DECIMAL; range: 2-10
		.INIT_SYNC_FF(1),               // DECIMAL; 0=disable simulation init values, 1=enable simulation init values
		.RST_ACTIVE_HIGH(0)             // DECIMAL; 0=active low reset, 1=active high reset
	) xpm_cdc_rst_axi_inst (
		.dest_arst(rstn_axi),
		.dest_clk(aclk),
		.src_arst(aresetn)
	);

	// Resets go straight in, active low: no logic in front of a synchronizer (report_cdc).
	xpm_cdc_async_rst #(
		.DEST_SYNC_FF(4),
		.INIT_SYNC_FF(1),
		.RST_ACTIVE_HIGH(0)
	) xpm_cdc_rst_spi_inst (
		.dest_arst(rstn_spi),
		.dest_clk(clk_spi),
		.src_arst(clk_locked)
	);

	xpm_cdc_async_rst #(
		.DEST_SYNC_FF(4),
		.INIT_SYNC_FF(1),
		.RST_ACTIVE_HIGH(0)
	) xpm_cdc_rst_dsp_inst (
		.dest_arst(rstn_dsp),
		.dest_clk(clk_dsp),
		.src_arst(clk_locked)
	);

/////////////////////////////////////////////////////////////////////////////
//Register file
/////////////////////////////////////////////////////////////////////////////
	mclp_registers #(
		.N_CH(N_CH),
		.FIR_INIT_FILE("fir64.mem"),
		.SEQ_INIT_FILE("seq_init.mem"),
		.UNITY_INIT_FILE("unity64.mem")
	) mclp_registers_0 (
		// AXI4-Lite interface
		.s_axi_aclk(aclk),
		.s_axi_aresetn(rstn_axi),
		.s_axi_awaddr(s_axi_awaddr),
		.s_axi_awprot(s_axi_awprot),
		.s_axi_awvalid(s_axi_awvalid),
		.s_axi_awready(s_axi_awready),
		.s_axi_wdata(s_axi_wdata),
		.s_axi_wstrb(s_axi_wstrb),
		.s_axi_wvalid(s_axi_wvalid),
		.s_axi_wready(s_axi_wready),
		.s_axi_bresp(s_axi_bresp),
		.s_axi_bvalid(s_axi_bvalid),
		.s_axi_bready(s_axi_bready),
		.s_axi_araddr(s_axi_araddr),
		.s_axi_arprot(s_axi_arprot),
		.s_axi_arvalid(s_axi_arvalid),
		.s_axi_arready(s_axi_arready),
		.s_axi_rdata(s_axi_rdata),
		.s_axi_rresp(s_axi_rresp),
		.s_axi_rvalid(s_axi_rvalid),
		.s_axi_rready(s_axi_rready),
		.irq(irq),
		.mmcm_locked(clk_locked),

		// Front end (clk_spi)
		.clk_spi(clk_spi),
		.spi_enable(spi_enable),
		.spi_loopback(spi_loopback),
		.spi_loopback_cfg(spi_loopback_cfg),
		.spi_loopback_value(spi_loopback_value),
		.spi_seq_start(spi_seq_start),
		.spi_seq_addr(spi_seq_addr),
		.spi_seq_data(spi_seq_data),
		.spi_seq_busy(spi_seq_busy),
		.spi_seq_resp(spi_seq_resp),

		// Processing (clk_dsp)
		.clk_dsp(clk_dsp),
		.dsp_rst(rst_dsp),
		.dsp_stab_band(dsp_stab_band),
		.dsp_stab_count(dsp_stab_count),
		.dsp_wim_enter(dsp_wim_enter),
		.dsp_wim_exit(dsp_wim_exit),
		.dsp_wim_settle(dsp_wim_settle),
		.dsp_result_decim(dsp_result_decim),
		.dsp_trig_cfg(dsp_trig_cfg),
		.dsp_trig_threshold(dsp_trig_threshold),
		.dsp_raw_tap(dsp_raw_tap),
		.dsp_raw_enable(dsp_raw_enable),
		.dsp_fir_reload(dsp_fir_reload),
		.dsp_sw_trigger(dsp_sw_trigger),
		.dsp_fault_clear(dsp_fault_clear),
		.dsp_gain_ch(dsp_gain_ch),
		.dsp_gain(dsp_gain),
		.dsp_offset(dsp_offset),
		.dsp_trim_ch(dsp_trim_ch),
		.dsp_trim(dsp_trim),
		.dsp_fir_addr(dsp_fir_addr),
		.dsp_fir_coef(dsp_fir_coef),
		.dsp_result_new(dsp_result_new),
		.dsp_result(dsp_result),
		.dsp_wim_new(dsp_wim_new),
		.dsp_wim_sum(dsp_wim_sum),
		.dsp_wim_count(dsp_wim_count),
		.dsp_stable(dsp_stable),
		.dsp_overload(dsp_overload),
		.dsp_reload_busy(dsp_reload_busy),
		.dsp_capture_active(dsp_capture_active),
		.dsp_faults(dsp_faults)
	);

/////////////////////////////////////////////////////////////////////////////
//AD7190 front end (clk_spi)
/////////////////////////////////////////////////////////////////////////////
	afe_frontend #(
		.N_CH(N_CH)
	) afe_frontend_0 (
		.clk(clk_spi),
		.rst(rst_spi),
		.enable(spi_enable),
		.loopback(spi_loopback),
		.seq_start(spi_seq_start),
		.loopback_cfg(spi_loopback_cfg),
		.loopback_value(spi_loopback_value),
		.seq_addr(spi_seq_addr),
		.seq_q(spi_seq_data),
		.seq_busy(spi_seq_busy),
		.seq_resp(spi_seq_resp),
		.adc_sclk(adc_sclk),
		.adc_din(adc_din),
		.adc_cs_n(adc_cs_n),
		.adc_sync_n(adc_sync_n),
		.adc_dout(adc_dout),
		.m_valid(fe_tvalid),
		.m_ready(fe_tready),
		.m_data(fe_tdata),
		.m_last(fe_tlast)
	);

	// CDC FIFO 1: samples clk_spi -> clk_dsp, {ts, flags, ch, data}
	xpm_fifo_axis #(
		.CDC_SYNC_STAGES(2),            // DECIMAL
		.CLOCKING_MODE("independent_clock"),
		.FIFO_DEPTH(64),                // DECIMAL
		.FIFO_MEMORY_TYPE("auto"),
		.PACKET_FIFO("false"),
		.PROG_FULL_THRESH(10),          // DECIMAL
		.TDATA_WIDTH(88),               // DECIMAL
		.USE_ADV_FEATURES("1000")
	) xpm_fifo_samples_inst (
		.s_aresetn(rstn_spi),
		.s_aclk(clk_spi),
		.m_aclk(clk_dsp),
		.s_axis_tvalid(fe_tvalid),
		.s_axis_tready(fe_tready),
		.s_axis_tdata(fe_tdata),
		.s_axis_tstrb({11{1'b1}}),
		.s_axis_tkeep({11{1'b1}}),
		.s_axis_tlast(fe_tlast),
		.s_axis_tid(1'b0),
		.s_axis_tdest(1'b0),
		.s_axis_tuser(1'b0),
		.m_axis_tvalid(smp_tvalid),
		.m_axis_tready(smp_tready),
		.m_axis_tdata(smp_tdata),
		.m_axis_tstrb(),
		.m_axis_tkeep(),
		.m_axis_tlast(smp_tlast),
		.m_axis_tid(),
		.m_axis_tdest(),
		.m_axis_tuser(),
		.prog_full_axis(),
		.wr_data_count_axis(),
		.almost_full_axis(),
		.prog_empty_axis(),
		.rd_data_count_axis(),
		.almost_empty_axis(),
		.injectsbiterr_axis(1'b0),
		.injectdbiterr_axis(1'b0),
		.sbiterr_axis(),
		.dbiterr_axis()
	);

/////////////////////////////////////////////////////////////////////////////
//Processing (clk_dsp)
/////////////////////////////////////////////////////////////////////////////
	mclp_dsp #(
		.N_CH(N_CH)
	) mclp_dsp_0 (
		.clk(clk_dsp),
		.rst(rst_dsp),
		.stab_band(dsp_stab_band),
		.stab_count(dsp_stab_count),
		.wim_enter(dsp_wim_enter),
		.wim_exit(dsp_wim_exit),
		.wim_settle(dsp_wim_settle),
		.result_decim(dsp_result_decim),
		.trig_cfg(dsp_trig_cfg),
		.trig_threshold(dsp_trig_threshold),
		.raw_tap(dsp_raw_tap),
		.raw_enable(dsp_raw_enable),
		.fir_reload(dsp_fir_reload),
		.sw_trigger(dsp_sw_trigger),
		.fault_clear(dsp_fault_clear),
		.gain_ch(dsp_gain_ch),
		.gain(dsp_gain),
		.offset(dsp_offset),
		.trim_ch(dsp_trim_ch),
		.trim(dsp_trim),
		.fir_addr(dsp_fir_addr),
		.fir_coef(dsp_fir_coef),
		.s_valid(smp_tvalid),
		.s_ready(smp_tready),
		.s_data(smp_tdata),
		.s_last(smp_tlast),
		.result(dsp_result),
		.result_new(dsp_result_new),
		.wim_sum(dsp_wim_sum),
		.wim_count(dsp_wim_count),
		.wim_new(dsp_wim_new),
		.stable(dsp_stable),
		.overload(dsp_overload),
		.reload_busy(dsp_reload_busy),
		.capture_active(dsp_capture_active),
		.faults(dsp_faults),
		.m_valid(rec_tvalid),
		.m_data(rec_tdata),
		.m_last(rec_tlast),
		.raw_full(rec_prog_full)
	);

	// CDC FIFO 2: raw records clk_dsp -> aclk, into the DMA. Records start only below the
	// programmable-full threshold, and the longest record (34 words at 64 channels) fits above it.
	xpm_fifo_axis #(
		.CDC_SYNC_STAGES(2),
		.CLOCKING_MODE("independent_clock"),
		.FIFO_DEPTH(512),
		.FIFO_MEMORY_TYPE("auto"),
		.PACKET_FIFO("false"),
		.PROG_FULL_THRESH(448),
		.TDATA_WIDTH(64),
		.USE_ADV_FEATURES("1002")       // prog_full_axis
	) xpm_fifo_records_inst (
		.s_aresetn(rstn_dsp),
		.s_aclk(clk_dsp),
		.m_aclk(aclk),
		.s_axis_tvalid(rec_tvalid),
		.s_axis_tready(),
		.s_axis_tdata(rec_tdata),
		.s_axis_tstrb({8{1'b1}}),
		.s_axis_tkeep({8{1'b1}}),
		.s_axis_tlast(rec_tlast),
		.s_axis_tid(1'b0),
		.s_axis_tdest(1'b0),
		.s_axis_tuser(1'b0),
		.m_axis_tvalid(m_axis_raw_tvalid),
		.m_axis_tready(m_axis_raw_tready),
		.m_axis_tdata(m_axis_raw_tdata),
		.m_axis_tstrb(),
		.m_axis_tkeep(),
		.m_axis_tlast(m_axis_raw_tlast),
		.m_axis_tid(),
		.m_axis_tdest(),
		.m_axis_tuser(),
		.prog_full_axis(rec_prog_full),
		.wr_data_count_axis(),
		.almost_full_axis(),
		.prog_empty_axis(),
		.rd_data_count_axis(),
		.almost_empty_axis(),
		.injectsbiterr_axis(1'b0),
		.injectdbiterr_axis(1'b0),
		.sbiterr_axis(),
		.dbiterr_axis()
	);

endmodule

`default_nettype wire
