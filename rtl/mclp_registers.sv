`default_nettype none

////////////////////////////////////////////////////////////////////////////////
// mclp_registers
// Register file. ADDRESS SPACE: 0x43C0_0000 -> 0x43C0_0FFF (GP0).
//
// Registers live in s_axi_aclk. Every signal to or from another clock domain crosses here through an
// XPM macro: control to clk_spi and clk_dsp (SYNC OUT), status back to s_axi_aclk (SYNC IN).
// Coefficient, FIR and sequencer memories are xpm_memory_tdpram: port A on the AXI side, port B read
// by the consumer in its own clock.
//
// To add a register: an address constant, a reg with its reset value, one line in the write case,
// one line in the read case, and the output assignment (through SYNC OUT if it leaves s_axi_aclk).
////////////////////////////////////////////////////////////////////////////////
module mclp_registers #(
		parameter FIR_INIT_FILE  = "fir64.mem",
		parameter SEQ_INIT_FILE  = "seq_init.mem",
		parameter UNITY_INIT_FILE = "unity8.mem"
	) (
		// AXI4-Lite Interface (s_axi_aclk)
		input  wire          s_axi_aclk,
		input  wire          s_axi_aresetn,
		input  wire [11:0]   s_axi_awaddr,
		input  wire [2:0]    s_axi_awprot,
		input  wire          s_axi_awvalid,
		output wire          s_axi_awready,
		input  wire [31:0]   s_axi_wdata,
		input  wire [3:0]    s_axi_wstrb,
		input  wire          s_axi_wvalid,
		output wire          s_axi_wready,
		output wire [1:0]    s_axi_bresp,
		output wire          s_axi_bvalid,
		input  wire          s_axi_bready,
		input  wire [11:0]   s_axi_araddr,
		input  wire [2:0]    s_axi_arprot,
		input  wire          s_axi_arvalid,
		output wire          s_axi_arready,
		output wire [31:0]   s_axi_rdata,
		output wire [1:0]    s_axi_rresp,
		output wire          s_axi_rvalid,
		input  wire          s_axi_rready,

		// Interrupt and asynchronous status (s_axi_aclk)
		output wire          irq,
		input  wire          mmcm_locked,

		// Front end (clk_spi)
		input  wire          clk_spi,
		output wire          spi_enable,
		output wire          spi_loopback,
		output wire [31:0]   spi_loopback_cfg,
		output wire [23:0]   spi_loopback_value,
		output wire          spi_seq_start,
		input  wire [7:0]    spi_seq_addr,
		output wire [31:0]   spi_seq_data,
		input  wire          spi_seq_busy,
		input  wire [255:0]  spi_seq_resp,

		// Processing (clk_dsp)
		input  wire          clk_dsp,
		input  wire          dsp_rst,
		output wire [31:0]   dsp_stab_band,
		output wire [31:0]   dsp_stab_count,
		output wire [31:0]   dsp_wim_enter,
		output wire [31:0]   dsp_wim_exit,
		output wire [31:0]   dsp_wim_settle,
		output wire [31:0]   dsp_result_decim,
		output wire [31:0]   dsp_trig_cfg,
		output wire [31:0]   dsp_trig_threshold,
		output wire [1:0]    dsp_raw_tap,
		output wire          dsp_raw_enable,
		output wire          dsp_fir_reload,
		output wire          dsp_sw_trigger,
		output wire          dsp_fault_clear,
		input  wire [2:0]    dsp_gain_ch,
		output wire [31:0]   dsp_gain,
		output wire [31:0]   dsp_offset,
		input  wire [2:0]    dsp_trim_ch,
		output wire [31:0]   dsp_trim,
		input  wire [5:0]    dsp_fir_addr,
		output wire [31:0]   dsp_fir_coef,
		input  wire          dsp_result_new,
		input  wire [31:0]   dsp_result,
		input  wire          dsp_wim_new,
		input  wire [63:0]   dsp_wim_sum,
		input  wire [31:0]   dsp_wim_count,
		input  wire          dsp_stable,
		input  wire          dsp_overload,
		input  wire          dsp_reload_busy,
		input  wire          dsp_capture_active,
		input  wire [39:0]   dsp_faults
	);

	//Registers-address----------------------------------------------------------------------------------
	localparam [11:0] REG_RO_0000 = 12'h000;   // ID
	localparam [11:0] REG_RW_0001 = 12'h004;   // CONTROL
	localparam [11:0] REG_RO_0002 = 12'h008;   // STATUS
	localparam [11:0] REG_RW_0003 = 12'h00C;   // IRQ_STATUS (write 1 to clear)
	localparam [11:0] REG_RW_0004 = 12'h010;   // IRQ_ENABLE
	localparam [11:0] REG_RO_0008 = 12'h020;   // RESULT
	localparam [11:0] REG_RO_0009 = 12'h024;   // RESULT_SEQ
	localparam [11:0] REG_RO_0010 = 12'h028;   // WIM_SUM_LSW
	localparam [11:0] REG_RO_0011 = 12'h02C;   // WIM_SUM_MSW
	localparam [11:0] REG_RO_0012 = 12'h030;   // WIM_COUNT
	localparam [11:0] REG_RW_0013 = 12'h034;   // STAB_BAND
	localparam [11:0] REG_RW_0014 = 12'h038;   // STAB_COUNT
	localparam [11:0] REG_RW_0015 = 12'h03C;   // WIM_ENTER
	localparam [11:0] REG_RW_0016 = 12'h040;   // WIM_EXIT
	localparam [11:0] REG_RW_0017 = 12'h044;   // WIM_SETTLE
	localparam [11:0] REG_RW_0018 = 12'h048;   // RESULT_DECIM
	localparam [11:0] REG_RW_0019 = 12'h04C;   // TRIG_CFG
	localparam [11:0] REG_RW_0020 = 12'h050;   // TRIG_THRESHOLD
	localparam [11:0] REG_RW_0021 = 12'h054;   // LOOPBACK_CFG
	localparam [11:0] REG_RW_0022 = 12'h058;   // LOOPBACK_VALUE
	localparam [11:0] REG_RO_0024 = 12'h060;   // FAULT CH0
	localparam [11:0] REG_RO_0025 = 12'h064;   // FAULT CH1
	localparam [11:0] REG_RO_0026 = 12'h068;   // FAULT CH2
	localparam [11:0] REG_RO_0027 = 12'h06C;   // FAULT CH3
	localparam [11:0] REG_RO_0028 = 12'h070;   // FAULT CH4
	localparam [11:0] REG_RO_0029 = 12'h074;   // FAULT CH5
	localparam [11:0] REG_RO_0030 = 12'h078;   // FAULT CH6
	localparam [11:0] REG_RO_0031 = 12'h07C;   // FAULT CH7
	localparam [11:0] REG_RO_0512 = 12'h800;   // SEQ_RESP CH0
	localparam [11:0] REG_RO_0513 = 12'h804;   // SEQ_RESP CH1
	localparam [11:0] REG_RO_0514 = 12'h808;   // SEQ_RESP CH2
	localparam [11:0] REG_RO_0515 = 12'h80C;   // SEQ_RESP CH3
	localparam [11:0] REG_RO_0516 = 12'h810;   // SEQ_RESP CH4
	localparam [11:0] REG_RO_0517 = 12'h814;   // SEQ_RESP CH5
	localparam [11:0] REG_RO_0518 = 12'h818;   // SEQ_RESP CH6
	localparam [11:0] REG_RO_0519 = 12'h81C;   // SEQ_RESP CH7
	//Memory-windows-------------------------------------------------------------------------------------
	localparam [11:0] MEM_GAIN    = 12'h100;   // 0x100-0x11C, 8 words, Q2.30
	localparam [11:0] MEM_OFFSET  = 12'h120;   // 0x120-0x13C, 8 words
	localparam [11:0] MEM_TRIM    = 12'h140;   // 0x140-0x15C, 8 words, Q2.30
	localparam [11:0] MEM_FIR     = 12'h200;   // 0x200-0x2FC, 64 words, reload order
	localparam [11:0] MEM_SEQ     = 12'h400;   // 0x400-0x7FC, 256 words
	//---------------------------------------------------------------------------------------------------
	localparam [31:0] FPGA_ID     = 32'h4D4C_0108;   // "ML" (MCLP), register map version 1, 8 channels
	localparam [31:0] READ_BAD    = 32'h0BAD_0BAD;

	localparam [2:0] SEL_REG    = 3'd0;
	localparam [2:0] SEL_GAIN   = 3'd1;
	localparam [2:0] SEL_OFFSET = 3'd2;
	localparam [2:0] SEL_TRIM   = 3'd3;
	localparam [2:0] SEL_FIR    = 3'd4;
	localparam [2:0] SEL_SEQ    = 3'd5;

	//Register-port--------------------------------------------------------------------------------------
	wire        bram_en_a;
	wire [3:0]  bram_we_a;
	wire [11:0] bram_addr_a;
	wire [31:0] bram_wrdata_a;
	reg  [31:0] bram_rddata_a;
	wire        bram_wr = bram_en_a && (bram_we_a == 4'hF);
	wire        bram_rd = bram_en_a && (bram_we_a == 4'h0);

	wire hit_gain   = bram_addr_a[11:5]  == MEM_GAIN[11:5];
	wire hit_offset = bram_addr_a[11:5]  == MEM_OFFSET[11:5];
	wire hit_trim   = bram_addr_a[11:5]  == MEM_TRIM[11:5];
	wire hit_fir    = bram_addr_a[11:8]  == MEM_FIR[11:8];
	wire hit_seq    = bram_addr_a[11:10] == MEM_SEQ[11:10];

	//Registers------------------------------------------------------------------------------------------
	reg         reg_enable         = 1'b1;
	reg         reg_loopback       = 1'b0;
	reg  [1:0]  reg_raw_tap        = 2'd0;
	reg         reg_raw_enable     = 1'b0;
	reg         reg_fir_reload     = 1'b0;   // one-cycle pulses
	reg         reg_seq_start      = 1'b0;
	reg         reg_sw_trigger     = 1'b0;
	reg         reg_fault_clear    = 1'b0;
	reg  [31:0] reg_irq_status     = 32'd0;
	reg  [31:0] reg_irq_enable     = 32'd0;
	reg  [31:0] reg_stab_band      = 32'd4096;
	reg  [31:0] reg_stab_count     = 32'd60;          // 100 ms at 600 Hz
	reg  [31:0] reg_wim_enter      = 32'h7FFF_FFFF;   // off until software sets it
	reg  [31:0] reg_wim_exit       = 32'h7FFF_FFFF;
	reg  [31:0] reg_wim_settle     = 32'd60;
	reg  [31:0] reg_result_decim   = 32'd12;          // 600 Hz / 12 = 50 Hz
	reg  [31:0] reg_trig_cfg       = 32'd0;
	reg  [31:0] reg_trig_threshold = 32'd0;
	reg  [31:0] reg_loopback_cfg   = {16'd4166, 16'd0};   // frame period: 20 MHz / 4800
	reg  [31:0] reg_loopback_value = 32'h0012_3456;
	reg  [31:0] reg_rddata         = 32'd0;
	reg  [2:0]  rd_sel             = SEL_REG;

	//Status (s_axi_aclk)--------------------------------------------------------------------------------
	wire         locked_axi, seq_busy_axi;
	wire [255:0] seq_resp_axi;
	wire [3:0]   dsp_levels_axi;     // {capture_active, stable, overload, reload_busy}
	wire [39:0]  faults_axi;
	wire         result_valid, wim_valid;
	wire [31:0]  result_axi;
	wire [95:0]  wim_axi;
	wire [5:0]   status = {dsp_levels_axi, seq_busy_axi, locked_axi};

	reg  [31:0]  result_q    = 32'd0;
	reg  [31:0]  result_seq  = 32'd0;
	reg  [63:0]  wim_sum_q   = 64'd0;
	reg  [31:0]  wim_count_q = 32'd0;
	reg  [5:0]   status_q    = 6'd0;
	reg  [39:0]  faults_q    = 40'd0;

	wire [6:0] irq_events = {
		status_q[5] & ~status[5],        // [6] capture done
		status_q[1] & ~status[1],        // [5] sequencer done
		|(faults_axi & ~faults_q),       // [4] new fault
		status[3] & ~status_q[3],        // [3] overload
		wim_valid,                       // [2] WIM result
		status[4] & ~status_q[4],        // [1] stable
		result_valid                     // [0] result
	};

	assign irq = |(reg_irq_status & reg_irq_enable);

	//Memory-read-data-----------------------------------------------------------------------------------
	wire [31:0] gain_douta, offset_douta, trim_douta, fir_douta, seq_douta;

	always @(*) begin
		case (rd_sel)
			SEL_GAIN:   bram_rddata_a = gain_douta;
			SEL_OFFSET: bram_rddata_a = offset_douta;
			SEL_TRIM:   bram_rddata_a = trim_douta;
			SEL_FIR:    bram_rddata_a = fir_douta;
			SEL_SEQ:    bram_rddata_a = seq_douta;
			default:    bram_rddata_a = reg_rddata;
		endcase
	end

	////////////////////////////////////////////////////////////////////////////
	// AXI4-Lite to register port
	////////////////////////////////////////////////////////////////////////////
	axil_bram_ctrl #(
		.C_S_AXI_ADDR_WIDTH(12),
		.C_S_AXI_DATA_WIDTH(32)
	) axil_bram_ctrl_0 (
		.S_AXI_ACLK(s_axi_aclk),
		.S_AXI_ARESETN(s_axi_aresetn),
		.S_AXI_AWADDR(s_axi_awaddr),
		.S_AXI_AWPROT(s_axi_awprot),
		.S_AXI_AWVALID(s_axi_awvalid),
		.S_AXI_AWREADY(s_axi_awready),
		.S_AXI_WDATA(s_axi_wdata),
		.S_AXI_WSTRB(s_axi_wstrb),
		.S_AXI_WVALID(s_axi_wvalid),
		.S_AXI_WREADY(s_axi_wready),
		.S_AXI_BRESP(s_axi_bresp),
		.S_AXI_BVALID(s_axi_bvalid),
		.S_AXI_BREADY(s_axi_bready),
		.S_AXI_ARADDR(s_axi_araddr),
		.S_AXI_ARPROT(s_axi_arprot),
		.S_AXI_ARVALID(s_axi_arvalid),
		.S_AXI_ARREADY(s_axi_arready),
		.S_AXI_RDATA(s_axi_rdata),
		.S_AXI_RRESP(s_axi_rresp),
		.S_AXI_RVALID(s_axi_rvalid),
		.S_AXI_RREADY(s_axi_rready),

		// Register interface
		.bram_en_a(bram_en_a),
		.bram_we_a(bram_we_a),
		.bram_addr_a(bram_addr_a),
		.bram_wrdata_a(bram_wrdata_a),
		.bram_rddata_a(bram_rddata_a)
	);

	////////////////////////////////////////////////////////////////////////////
	// Register read / write
	////////////////////////////////////////////////////////////////////////////
	always @(posedge s_axi_aclk) begin
		reg_fir_reload  <= 1'b0;
		reg_seq_start   <= 1'b0;
		reg_sw_trigger  <= 1'b0;
		reg_fault_clear <= 1'b0;
		reg_irq_status  <= reg_irq_status | {25'd0, irq_events};
		if (!s_axi_aresetn) begin
			reg_enable         <= 1'b1;       // the AD7190 init list runs at power-up
			reg_loopback       <= 1'b0;
			reg_raw_tap        <= 2'd0;
			reg_raw_enable     <= 1'b0;
			reg_irq_status     <= 32'd0;
			reg_irq_enable     <= 32'd0;
			reg_stab_band      <= 32'd4096;
			reg_stab_count     <= 32'd60;
			reg_wim_enter      <= 32'h7FFF_FFFF;
			reg_wim_exit       <= 32'h7FFF_FFFF;
			reg_wim_settle     <= 32'd60;
			reg_result_decim   <= 32'd12;
			reg_trig_cfg       <= 32'd0;
			reg_trig_threshold <= 32'd0;
			reg_loopback_cfg   <= {16'd4166, 16'd0};
			reg_loopback_value <= 32'h0012_3456;
			rd_sel             <= SEL_REG;
		end else if (bram_wr) begin
			case (bram_addr_a)
				REG_RW_0001: begin
					reg_enable      <= bram_wrdata_a[0];
					reg_loopback    <= bram_wrdata_a[1];
					reg_fir_reload  <= bram_wrdata_a[2];
					reg_seq_start   <= bram_wrdata_a[3];
					reg_raw_tap     <= bram_wrdata_a[5:4];
					reg_raw_enable  <= bram_wrdata_a[6];
					reg_sw_trigger  <= bram_wrdata_a[7];
					reg_fault_clear <= bram_wrdata_a[8];
				end
				REG_RW_0003: reg_irq_status     <= (reg_irq_status & ~bram_wrdata_a) | {25'd0, irq_events};
				REG_RW_0004: reg_irq_enable     <= bram_wrdata_a;
				REG_RW_0013: reg_stab_band      <= bram_wrdata_a;
				REG_RW_0014: reg_stab_count     <= bram_wrdata_a;
				REG_RW_0015: reg_wim_enter      <= bram_wrdata_a;
				REG_RW_0016: reg_wim_exit       <= bram_wrdata_a;
				REG_RW_0017: reg_wim_settle     <= bram_wrdata_a;
				REG_RW_0018: reg_result_decim   <= bram_wrdata_a;
				REG_RW_0019: reg_trig_cfg       <= bram_wrdata_a;
				REG_RW_0020: reg_trig_threshold <= bram_wrdata_a;
				REG_RW_0021: reg_loopback_cfg   <= bram_wrdata_a;
				REG_RW_0022: reg_loopback_value <= bram_wrdata_a;
				default: ;
			endcase
		end else if (bram_rd) begin
			rd_sel <= hit_gain ? SEL_GAIN : hit_offset ? SEL_OFFSET : hit_trim ? SEL_TRIM :
			          hit_fir ? SEL_FIR : hit_seq ? SEL_SEQ : SEL_REG;
			case (bram_addr_a)
				REG_RO_0000: reg_rddata <= FPGA_ID;
				REG_RW_0001: reg_rddata <= {25'd0, reg_raw_enable, reg_raw_tap, 2'b00, reg_loopback, reg_enable};
				REG_RO_0002: reg_rddata <= {26'd0, status};
				REG_RW_0003: reg_rddata <= reg_irq_status;
				REG_RW_0004: reg_rddata <= reg_irq_enable;
				REG_RO_0008: reg_rddata <= result_q;
				REG_RO_0009: reg_rddata <= result_seq;
				REG_RO_0010: reg_rddata <= wim_sum_q[31:0];
				REG_RO_0011: reg_rddata <= wim_sum_q[63:32];
				REG_RO_0012: reg_rddata <= wim_count_q;
				REG_RW_0013: reg_rddata <= reg_stab_band;
				REG_RW_0014: reg_rddata <= reg_stab_count;
				REG_RW_0015: reg_rddata <= reg_wim_enter;
				REG_RW_0016: reg_rddata <= reg_wim_exit;
				REG_RW_0017: reg_rddata <= reg_wim_settle;
				REG_RW_0018: reg_rddata <= reg_result_decim;
				REG_RW_0019: reg_rddata <= reg_trig_cfg;
				REG_RW_0020: reg_rddata <= reg_trig_threshold;
				REG_RW_0021: reg_rddata <= reg_loopback_cfg;
				REG_RW_0022: reg_rddata <= reg_loopback_value;
				REG_RO_0024: reg_rddata <= {27'd0, faults_axi[4:0]};
				REG_RO_0025: reg_rddata <= {27'd0, faults_axi[9:5]};
				REG_RO_0026: reg_rddata <= {27'd0, faults_axi[14:10]};
				REG_RO_0027: reg_rddata <= {27'd0, faults_axi[19:15]};
				REG_RO_0028: reg_rddata <= {27'd0, faults_axi[24:20]};
				REG_RO_0029: reg_rddata <= {27'd0, faults_axi[29:25]};
				REG_RO_0030: reg_rddata <= {27'd0, faults_axi[34:30]};
				REG_RO_0031: reg_rddata <= {27'd0, faults_axi[39:35]};
				REG_RO_0512: reg_rddata <= seq_resp_axi[31:0];
				REG_RO_0513: reg_rddata <= seq_resp_axi[63:32];
				REG_RO_0514: reg_rddata <= seq_resp_axi[95:64];
				REG_RO_0515: reg_rddata <= seq_resp_axi[127:96];
				REG_RO_0516: reg_rddata <= seq_resp_axi[159:128];
				REG_RO_0517: reg_rddata <= seq_resp_axi[191:160];
				REG_RO_0518: reg_rddata <= seq_resp_axi[223:192];
				REG_RO_0519: reg_rddata <= seq_resp_axi[255:224];
				default:     reg_rddata <= READ_BAD;
			endcase
		end
	end

	// Latched status: result and WIM values, previous levels for the interrupt edges
	always @(posedge s_axi_aclk) begin
		status_q <= status;
		faults_q <= faults_axi;
		if (result_valid) begin
			result_q   <= result_axi;
			result_seq <= result_seq + 1;
		end
		if (wim_valid) begin
			wim_sum_q   <= wim_axi[95:32];
			wim_count_q <= wim_axi[31:0];
		end
		if (!s_axi_aresetn) begin
			result_q    <= 32'd0;
			result_seq  <= 32'd0;
			wim_sum_q   <= 64'd0;
			wim_count_q <= 32'd0;
		end
	end

	////////////////////////////////////////////////////////////////////////////
	// Memories: port A on the register port, port B read by the consumer
	////////////////////////////////////////////////////////////////////////////
	xpm_memory_tdpram #(
		.ADDR_WIDTH_A(3),                  // DECIMAL
		.ADDR_WIDTH_B(3),                  // DECIMAL
		.BYTE_WRITE_WIDTH_A(32),           // DECIMAL
		.BYTE_WRITE_WIDTH_B(32),           // DECIMAL
		.CLOCKING_MODE("independent_clock"),
		.MEMORY_INIT_FILE(UNITY_INIT_FILE),// gain 1.0 on every channel
		.MEMORY_PRIMITIVE("block"),
		.MEMORY_SIZE(256),                 // DECIMAL, bits
		.READ_DATA_WIDTH_A(32),            // DECIMAL
		.READ_DATA_WIDTH_B(32),            // DECIMAL
		.READ_LATENCY_A(1),                // DECIMAL
		.READ_LATENCY_B(1),                // DECIMAL
		.USE_MEM_INIT(1),                  // DECIMAL
		.WRITE_DATA_WIDTH_A(32),           // DECIMAL
		.WRITE_DATA_WIDTH_B(32),           // DECIMAL
		.WRITE_MODE_A("no_change"),
		.WRITE_MODE_B("no_change")
	) xpm_memory_gain_inst (
		.sleep(1'b0),
		.clka(s_axi_aclk),
		.rsta(1'b0),
		.ena(bram_en_a && hit_gain),
		.regcea(1'b1),
		.wea(bram_wr),
		.addra(bram_addr_a[4:2]),
		.dina(bram_wrdata_a),
		.injectsbiterra(1'b0),
		.injectdbiterra(1'b0),
		.douta(gain_douta),
		.sbiterra(),
		.dbiterra(),
		.clkb(clk_dsp),
		.rstb(1'b0),
		.enb(1'b1),
		.regceb(1'b1),
		.web(1'b0),
		.addrb(dsp_gain_ch),
		.dinb(32'd0),
		.injectsbiterrb(1'b0),
		.injectdbiterrb(1'b0),
		.doutb(dsp_gain),
		.sbiterrb(),
		.dbiterrb()
	);

	xpm_memory_tdpram #(
		.ADDR_WIDTH_A(3),
		.ADDR_WIDTH_B(3),
		.BYTE_WRITE_WIDTH_A(32),
		.BYTE_WRITE_WIDTH_B(32),
		.CLOCKING_MODE("independent_clock"),
		.MEMORY_INIT_FILE("none"),         // offset 0 on every channel
		.MEMORY_PRIMITIVE("block"),
		.MEMORY_SIZE(256),
		.READ_DATA_WIDTH_A(32),
		.READ_DATA_WIDTH_B(32),
		.READ_LATENCY_A(1),
		.READ_LATENCY_B(1),
		.USE_MEM_INIT(1),
		.WRITE_DATA_WIDTH_A(32),
		.WRITE_DATA_WIDTH_B(32),
		.WRITE_MODE_A("no_change"),
		.WRITE_MODE_B("no_change")
	) xpm_memory_offset_inst (
		.sleep(1'b0),
		.clka(s_axi_aclk),
		.rsta(1'b0),
		.ena(bram_en_a && hit_offset),
		.regcea(1'b1),
		.wea(bram_wr),
		.addra(bram_addr_a[4:2]),
		.dina(bram_wrdata_a),
		.injectsbiterra(1'b0),
		.injectdbiterra(1'b0),
		.douta(offset_douta),
		.sbiterra(),
		.dbiterra(),
		.clkb(clk_dsp),
		.rstb(1'b0),
		.enb(1'b1),
		.regceb(1'b1),
		.web(1'b0),
		.addrb(dsp_gain_ch),
		.dinb(32'd0),
		.injectsbiterrb(1'b0),
		.injectdbiterrb(1'b0),
		.doutb(dsp_offset),
		.sbiterrb(),
		.dbiterrb()
	);

	xpm_memory_tdpram #(
		.ADDR_WIDTH_A(3),
		.ADDR_WIDTH_B(3),
		.BYTE_WRITE_WIDTH_A(32),
		.BYTE_WRITE_WIDTH_B(32),
		.CLOCKING_MODE("independent_clock"),
		.MEMORY_INIT_FILE(UNITY_INIT_FILE),// trim 1.0 on every channel
		.MEMORY_PRIMITIVE("block"),
		.MEMORY_SIZE(256),
		.READ_DATA_WIDTH_A(32),
		.READ_DATA_WIDTH_B(32),
		.READ_LATENCY_A(1),
		.READ_LATENCY_B(1),
		.USE_MEM_INIT(1),
		.WRITE_DATA_WIDTH_A(32),
		.WRITE_DATA_WIDTH_B(32),
		.WRITE_MODE_A("no_change"),
		.WRITE_MODE_B("no_change")
	) xpm_memory_trim_inst (
		.sleep(1'b0),
		.clka(s_axi_aclk),
		.rsta(1'b0),
		.ena(bram_en_a && hit_trim),
		.regcea(1'b1),
		.wea(bram_wr),
		.addra(bram_addr_a[4:2]),
		.dina(bram_wrdata_a),
		.injectsbiterra(1'b0),
		.injectdbiterra(1'b0),
		.douta(trim_douta),
		.sbiterra(),
		.dbiterra(),
		.clkb(clk_dsp),
		.rstb(1'b0),
		.enb(1'b1),
		.regceb(1'b1),
		.web(1'b0),
		.addrb(dsp_trim_ch),
		.dinb(32'd0),
		.injectsbiterrb(1'b0),
		.injectdbiterrb(1'b0),
		.doutb(dsp_trim),
		.sbiterrb(),
		.dbiterrb()
	);

	xpm_memory_tdpram #(
		.ADDR_WIDTH_A(6),
		.ADDR_WIDTH_B(6),
		.BYTE_WRITE_WIDTH_A(32),
		.BYTE_WRITE_WIDTH_B(32),
		.CLOCKING_MODE("independent_clock"),
		.MEMORY_INIT_FILE(FIR_INIT_FILE),
		.MEMORY_PRIMITIVE("block"),
		.MEMORY_SIZE(2048),
		.READ_DATA_WIDTH_A(32),
		.READ_DATA_WIDTH_B(32),
		.READ_LATENCY_A(1),
		.READ_LATENCY_B(1),
		.USE_MEM_INIT(1),
		.WRITE_DATA_WIDTH_A(32),
		.WRITE_DATA_WIDTH_B(32),
		.WRITE_MODE_A("no_change"),
		.WRITE_MODE_B("no_change")
	) xpm_memory_fir_inst (
		.sleep(1'b0),
		.clka(s_axi_aclk),
		.rsta(1'b0),
		.ena(bram_en_a && hit_fir),
		.regcea(1'b1),
		.wea(bram_wr),
		.addra(bram_addr_a[7:2]),
		.dina(bram_wrdata_a),
		.injectsbiterra(1'b0),
		.injectdbiterra(1'b0),
		.douta(fir_douta),
		.sbiterra(),
		.dbiterra(),
		.clkb(clk_dsp),
		.rstb(1'b0),
		.enb(1'b1),
		.regceb(1'b1),
		.web(1'b0),
		.addrb(dsp_fir_addr),
		.dinb(32'd0),
		.injectsbiterrb(1'b0),
		.injectdbiterrb(1'b0),
		.doutb(dsp_fir_coef),
		.sbiterrb(),
		.dbiterrb()
	);

	xpm_memory_tdpram #(
		.ADDR_WIDTH_A(8),
		.ADDR_WIDTH_B(8),
		.BYTE_WRITE_WIDTH_A(32),
		.BYTE_WRITE_WIDTH_B(32),
		.CLOCKING_MODE("independent_clock"),
		.MEMORY_INIT_FILE(SEQ_INIT_FILE),
		.MEMORY_PRIMITIVE("block"),
		.MEMORY_SIZE(8192),
		.READ_DATA_WIDTH_A(32),
		.READ_DATA_WIDTH_B(32),
		.READ_LATENCY_A(1),
		.READ_LATENCY_B(1),
		.USE_MEM_INIT(1),
		.WRITE_DATA_WIDTH_A(32),
		.WRITE_DATA_WIDTH_B(32),
		.WRITE_MODE_A("no_change"),
		.WRITE_MODE_B("no_change")
	) xpm_memory_seq_inst (
		.sleep(1'b0),
		.clka(s_axi_aclk),
		.rsta(1'b0),
		.ena(bram_en_a && hit_seq),
		.regcea(1'b1),
		.wea(bram_wr),
		.addra(bram_addr_a[9:2]),
		.dina(bram_wrdata_a),
		.injectsbiterra(1'b0),
		.injectdbiterra(1'b0),
		.douta(seq_douta),
		.sbiterra(),
		.dbiterra(),
		.clkb(clk_spi),
		.rstb(1'b0),
		.enb(1'b1),
		.regceb(1'b1),
		.web(1'b0),
		.addrb(spi_seq_addr),
		.dinb(32'd0),
		.injectsbiterrb(1'b0),
		.injectdbiterrb(1'b0),
		.doutb(spi_seq_data),
		.sbiterrb(),
		.dbiterrb()
	);

	////////////////////////////////////////////////////////////////////////////
	// SYNC OUT: s_axi_aclk -> clk_spi, clk_dsp
	// Configuration buses use free-running xpm_cdc_handshake transfers: src_send restarts as soon as
	// src_rcv drops, and the hold register only loads between transfers, so every word arrives whole.
	////////////////////////////////////////////////////////////////////////////
	reg  [57:0]  spi_cfg_hold = 58'd0;
	reg          spi_cfg_send = 1'b0;
	wire         spi_cfg_rcv;
	reg  [258:0] dsp_cfg_hold = 259'd0;
	reg          dsp_cfg_send = 1'b0;
	wire         dsp_cfg_rcv;

	always @(posedge s_axi_aclk) begin
		if (!spi_cfg_send) spi_cfg_hold <= {reg_enable, reg_loopback, reg_loopback_cfg, reg_loopback_value[23:0]};
		if (!dsp_cfg_send) dsp_cfg_hold <= {reg_stab_band, reg_stab_count, reg_wim_enter, reg_wim_exit, reg_wim_settle,
		                                    reg_result_decim, reg_trig_cfg, reg_trig_threshold, reg_raw_tap, reg_raw_enable};
		spi_cfg_send <= !spi_cfg_rcv;
		dsp_cfg_send <= !dsp_cfg_rcv;
	end

	xpm_cdc_handshake #(
		.DEST_EXT_HSK(0),    // DECIMAL; 0=internal handshake, 1=external handshake
		.DEST_SYNC_FF(2),    // DECIMAL; range: 2-10
		.INIT_SYNC_FF(1),    // DECIMAL; 0=disable simulation init values, 1=enable simulation init values
		.SIM_ASSERT_CHK(0),  // DECIMAL; 0=disable simulation messages, 1=enable simulation messages
		.SRC_SYNC_FF(2),     // DECIMAL; range: 2-10
		.WIDTH(58)           // DECIMAL; range: 1-1024
	) xpm_cdc_spi_cfg_inst (
		.dest_out({spi_enable, spi_loopback, spi_loopback_cfg, spi_loopback_value}),
		.dest_req(),
		.src_rcv(spi_cfg_rcv),
		.dest_ack(1'b0),
		.dest_clk(clk_spi),
		.src_clk(s_axi_aclk),
		.src_in(spi_cfg_hold),
		.src_send(spi_cfg_send)
	);

	xpm_cdc_pulse #(
		.DEST_SYNC_FF(4),    // DECIMAL; range: 2-10
		.INIT_SYNC_FF(1),    // DECIMAL; 0=disable simulation init values, 1=enable simulation init values
		.REG_OUTPUT(0),      // DECIMAL; 0=disable registered output, 1=enable registered output
		.RST_USED(0),        // DECIMAL; 0=no reset, 1=implement reset
		.SIM_ASSERT_CHK(0)   // DECIMAL; 0=disable simulation messages, 1=enable simulation messages
	) xpm_cdc_seq_start_inst (
		.dest_pulse(spi_seq_start),
		.dest_clk(clk_spi),
		.dest_rst(1'b0),
		.src_clk(s_axi_aclk),
		.src_pulse(reg_seq_start),
		.src_rst(1'b0)
	);

	xpm_cdc_handshake #(
		.DEST_EXT_HSK(0),
		.DEST_SYNC_FF(2),
		.INIT_SYNC_FF(1),
		.SIM_ASSERT_CHK(0),
		.SRC_SYNC_FF(2),
		.WIDTH(259)
	) xpm_cdc_dsp_cfg_inst (
		.dest_out({dsp_stab_band, dsp_stab_count, dsp_wim_enter, dsp_wim_exit, dsp_wim_settle, dsp_result_decim,
		           dsp_trig_cfg, dsp_trig_threshold, dsp_raw_tap, dsp_raw_enable}),
		.dest_req(),
		.src_rcv(dsp_cfg_rcv),
		.dest_ack(1'b0),
		.dest_clk(clk_dsp),
		.src_clk(s_axi_aclk),
		.src_in(dsp_cfg_hold),
		.src_send(dsp_cfg_send)
	);

	xpm_cdc_pulse #(
		.DEST_SYNC_FF(4),
		.INIT_SYNC_FF(1),
		.REG_OUTPUT(0),
		.RST_USED(0),
		.SIM_ASSERT_CHK(0)
	) xpm_cdc_fir_reload_inst (
		.dest_pulse(dsp_fir_reload),
		.dest_clk(clk_dsp),
		.dest_rst(1'b0),
		.src_clk(s_axi_aclk),
		.src_pulse(reg_fir_reload),
		.src_rst(1'b0)
	);

	xpm_cdc_pulse #(
		.DEST_SYNC_FF(4),
		.INIT_SYNC_FF(1),
		.REG_OUTPUT(0),
		.RST_USED(0),
		.SIM_ASSERT_CHK(0)
	) xpm_cdc_sw_trigger_inst (
		.dest_pulse(dsp_sw_trigger),
		.dest_clk(clk_dsp),
		.dest_rst(1'b0),
		.src_clk(s_axi_aclk),
		.src_pulse(reg_sw_trigger),
		.src_rst(1'b0)
	);

	xpm_cdc_pulse #(
		.DEST_SYNC_FF(4),
		.INIT_SYNC_FF(1),
		.REG_OUTPUT(0),
		.RST_USED(0),
		.SIM_ASSERT_CHK(0)
	) xpm_cdc_fault_clear_inst (
		.dest_pulse(dsp_fault_clear),
		.dest_clk(clk_dsp),
		.dest_rst(1'b0),
		.src_clk(s_axi_aclk),
		.src_pulse(reg_fault_clear),
		.src_rst(1'b0)
	);

	////////////////////////////////////////////////////////////////////////////
	// SYNC IN: mmcm, clk_spi, clk_dsp -> s_axi_aclk
	////////////////////////////////////////////////////////////////////////////
	xpm_cdc_single #(
		.DEST_SYNC_FF(2),    // DECIMAL; range: 2-10
		.INIT_SYNC_FF(1),    // DECIMAL; 0=disable simulation init values, 1=enable simulation init values
		.SIM_ASSERT_CHK(0),  // DECIMAL; 0=disable simulation messages, 1=enable simulation messages
		.SRC_INPUT_REG(0)    // DECIMAL; 0=do not register input, 1=register input
	) xpm_cdc_locked_inst (
		.dest_out(locked_axi),
		.dest_clk(s_axi_aclk),
		.src_clk(1'b0),
		.src_in(mmcm_locked)
	);

	xpm_cdc_single #(
		.DEST_SYNC_FF(2),
		.INIT_SYNC_FF(1),
		.SIM_ASSERT_CHK(0),
		.SRC_INPUT_REG(1)
	) xpm_cdc_seq_busy_inst (
		.dest_out(seq_busy_axi),
		.dest_clk(s_axi_aclk),
		.src_clk(clk_spi),
		.src_in(spi_seq_busy)
	);

	// ID answers cross bit by bit. They only change during an XFER and software reads them after
	// the sequencer-done interrupt, many cycles after the last bit settles. Use xpm_cdc_handshake if
	// software ever polls SEQ_RESP while the list runs.
	xpm_cdc_array_single #(
		.DEST_SYNC_FF(2),
		.INIT_SYNC_FF(1),
		.SIM_ASSERT_CHK(0),
		.SRC_INPUT_REG(1),
		.WIDTH(256)
	) xpm_cdc_seq_resp_inst (
		.dest_out(seq_resp_axi),
		.dest_clk(s_axi_aclk),
		.src_clk(clk_spi),
		.src_in(spi_seq_resp)
	);

	xpm_cdc_array_single #(
		.DEST_SYNC_FF(2),
		.INIT_SYNC_FF(1),
		.SIM_ASSERT_CHK(0),
		.SRC_INPUT_REG(1),
		.WIDTH(4)
	) xpm_cdc_dsp_levels_inst (
		.dest_out(dsp_levels_axi),
		.dest_clk(s_axi_aclk),
		.src_clk(clk_dsp),
		.src_in({dsp_capture_active, dsp_stable, dsp_overload, dsp_reload_busy})
	);

	// Sticky fault bits cross bit by bit; each bit only sets until fault_clear
	xpm_cdc_array_single #(
		.DEST_SYNC_FF(2),
		.INIT_SYNC_FF(1),
		.SIM_ASSERT_CHK(0),
		.SRC_INPUT_REG(1),
		.WIDTH(40)
	) xpm_cdc_faults_inst (
		.dest_out(faults_axi),
		.dest_clk(s_axi_aclk),
		.src_clk(clk_dsp),
		.src_in(dsp_faults)
	);

	// Result and WIM values with their strobes: small async FIFOs, one entry per event
	xpm_fifo_axis #(
		.CDC_SYNC_STAGES(2),                // DECIMAL
		.CLOCKING_MODE("independent_clock"),
		.FIFO_DEPTH(16),                    // DECIMAL
		.FIFO_MEMORY_TYPE("distributed"),
		.PACKET_FIFO("false"),
		.PROG_FULL_THRESH(10),              // DECIMAL
		.TDATA_WIDTH(32),                   // DECIMAL
		.USE_ADV_FEATURES("1000")
	) xpm_fifo_result_inst (
		.s_aresetn(!dsp_rst),
		.s_aclk(clk_dsp),
		.m_aclk(s_axi_aclk),
		.s_axis_tvalid(dsp_result_new),
		.s_axis_tready(),
		.s_axis_tdata(dsp_result),
		.s_axis_tstrb(4'hF),
		.s_axis_tkeep(4'hF),
		.s_axis_tlast(1'b0),
		.s_axis_tid(1'b0),
		.s_axis_tdest(1'b0),
		.s_axis_tuser(1'b0),
		.m_axis_tvalid(result_valid),
		.m_axis_tready(1'b1),
		.m_axis_tdata(result_axi),
		.m_axis_tstrb(),
		.m_axis_tkeep(),
		.m_axis_tlast(),
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

	xpm_fifo_axis #(
		.CDC_SYNC_STAGES(2),
		.CLOCKING_MODE("independent_clock"),
		.FIFO_DEPTH(16),
		.FIFO_MEMORY_TYPE("distributed"),
		.PACKET_FIFO("false"),
		.PROG_FULL_THRESH(10),
		.TDATA_WIDTH(96),
		.USE_ADV_FEATURES("1000")
	) xpm_fifo_wim_inst (
		.s_aresetn(!dsp_rst),
		.s_aclk(clk_dsp),
		.m_aclk(s_axi_aclk),
		.s_axis_tvalid(dsp_wim_new),
		.s_axis_tready(),
		.s_axis_tdata({dsp_wim_sum, dsp_wim_count}),
		.s_axis_tstrb(12'hFFF),
		.s_axis_tkeep(12'hFFF),
		.s_axis_tlast(1'b0),
		.s_axis_tid(1'b0),
		.s_axis_tdest(1'b0),
		.s_axis_tuser(1'b0),
		.m_axis_tvalid(wim_valid),
		.m_axis_tready(1'b1),
		.m_axis_tdata(wim_axi),
		.m_axis_tstrb(),
		.m_axis_tkeep(),
		.m_axis_tlast(),
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

endmodule

`default_nettype wire
