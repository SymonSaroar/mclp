`default_nettype none

////////////////////////////////////////////////////////////////////////////////
// mclp_dsp
// Processing subsystem, clk domain clk_dsp: CIC, gain/offset, corner trim, channel sum, FIR with
// coefficient reload, weight, result decimation, stability and WIM.
// Every input is already in clk_dsp (mclp_registers does the crossings); configuration is quasi-static.
////////////////////////////////////////////////////////////////////////////////
module mclp_dsp (
	// Clock and reset
	input  wire               clk,
	input  wire               rst,

	// Configuration and pulses (clk)
	input  wire [31:0]        stab_band,
	input  wire [31:0]        stab_count,
	input  wire [31:0]        wim_enter,
	input  wire [31:0]        wim_exit,
	input  wire [31:0]        wim_settle,
	input  wire [31:0]        result_decim,
	input  wire               fir_reload,

	// Coefficient RAM read ports (mclp_registers, read latency 1)
	output wire [2:0]         gain_ch,
	input  wire [31:0]        gain,
	input  wire [31:0]        offset,
	output wire [2:0]         trim_ch,
	input  wire [31:0]        trim,
	output wire [5:0]         fir_addr,
	input  wire [31:0]        fir_coef,

	// AFE beats {ts, flags, ch, data} from CDC FIFO 1
	input  wire               s_valid,
	output wire               s_ready,
	input  wire [79:0]        s_data,
	input  wire               s_last,

	// Results and status (to mclp_registers)
	output reg  signed [31:0] result = 0,
	output reg                result_new = 0,
	output wire signed [63:0] wim_sum,
	output wire [31:0]        wim_count,
	output wire               wim_new,
	output wire               stable,
	output reg                overload = 0,
	output wire               reload_busy
);

	localparam signed [39:0] W_MAX = 40'sd2147483647;
	localparam signed [39:0] W_MIN = -40'sd2147483648;

	wire        cic_ready;

	assign s_ready = cic_ready;

	/////////////////////////////////////////////////////////////////////////////
	// CIC: 8 channels, R = 8, N = 3, 24 -> 32 bits. The channel is counted between tlasts.
	/////////////////////////////////////////////////////////////////////////////
	wire               cic_valid;
	wire               cic_last;
	wire signed [31:0] cic_data;
	reg  [2:0]         cic_ch = 3'd0;

	mclp_cic mclp_cic_0 (
		.aclk(clk),
		.aresetn(!rst),
		.s_axis_data_tdata(s_data[23:0]),
		.s_axis_data_tvalid(s_valid),
		.s_axis_data_tready(cic_ready),
		.s_axis_data_tlast(s_last),
		.m_axis_data_tdata(cic_data),
		.m_axis_data_tuser(),
		.m_axis_data_tvalid(cic_valid),
		.m_axis_data_tlast(cic_last),
		.event_tlast_unexpected(),
		.event_tlast_missing()
	);

	always @(posedge clk) begin
		if (rst)
			cic_ch <= 3'd0;
		else if (cic_valid)
			cic_ch <= cic_last ? 3'd0 : cic_ch + 1'b1;
	end

	/////////////////////////////////////////////////////////////////////////////
	// Gain/offset, corner trim, channel sum
	/////////////////////////////////////////////////////////////////////////////
	wire               go_valid, go_last, go_sat;
	wire               tr_valid, tr_last, tr_sat;
	wire               sum_valid, sum_overload;
	wire [2:0]         go_ch, tr_ch;
	wire signed [31:0] go_data, tr_data;
	wire signed [35:0] sum_data;

	ch_scale ch_scale_gain (
		.clk(clk),
		.rst(rst),
		.s_valid(cic_valid),
		.s_ch(cic_ch),
		.s_last(cic_last),
		.s_sat(1'b0),
		.s_data(cic_data),
		.coef_ch(gain_ch),
		.k(gain),
		.offset(offset),
		.m_valid(go_valid),
		.m_ch(go_ch),
		.m_last(go_last),
		.m_sat(go_sat),
		.m_data(go_data)
	);

	ch_scale ch_scale_trim (
		.clk(clk),
		.rst(rst),
		.s_valid(go_valid),
		.s_ch(go_ch),
		.s_last(go_last),
		.s_sat(go_sat),
		.s_data(go_data),
		.coef_ch(trim_ch),
		.k(trim),
		.offset(32'sd0),
		.m_valid(tr_valid),
		.m_ch(tr_ch),
		.m_last(tr_last),
		.m_sat(tr_sat),
		.m_data(tr_data)
	);

	sat_sum sat_sum_0 (
		.clk(clk),
		.rst(rst),
		.s_valid(tr_valid),
		.s_last(tr_last),
		.s_sat(tr_sat),
		.s_data(tr_data),
		.m_valid(sum_valid),
		.m_data(sum_data),
		.m_overload(sum_overload)
	);

	/////////////////////////////////////////////////////////////////////////////
	// 64-tap FIR with coefficient reload. s_axis_data_tready unused; the core takes one
	// sample per 1.67 ms and needs 64 cycles for it.
	/////////////////////////////////////////////////////////////////////////////
	wire               fir_valid;
	wire signed [63:0] fir_data;
	wire               reload_valid, reload_ready, reload_last;
	wire [23:0]        reload_data;
	wire               config_valid, config_ready;

	mclp_fir mclp_fir_0 (
		.aresetn(!rst),
		.aclk(clk),
		.s_axis_data_tvalid(sum_valid),
		.s_axis_data_tready(),
		.s_axis_data_tdata({{4{sum_data[35]}}, sum_data}),
		.s_axis_config_tvalid(config_valid),
		.s_axis_config_tready(config_ready),
		.s_axis_config_tdata(8'd0),
		.s_axis_reload_tvalid(reload_valid),
		.s_axis_reload_tready(reload_ready),
		.s_axis_reload_tlast(reload_last),
		.s_axis_reload_tdata(reload_data),
		.m_axis_data_tvalid(fir_valid),
		.m_axis_data_tdata(fir_data),
		.event_s_reload_tlast_missing(),
		.event_s_reload_tlast_unexpected()
	);

	coef_reload #(
		.N(64)
	) coef_reload_0 (
		.clk(clk),
		.rst(rst),
		.start(fir_reload),
		.busy(reload_busy),
		.addr(fir_addr),
		.q(fir_coef),
		.reload_valid(reload_valid),
		.reload_ready(reload_ready),
		.reload_data(reload_data),
		.reload_last(reload_last),
		.config_valid(config_valid),
		.config_ready(config_ready)
	);

	/////////////////////////////////////////////////////////////////////////////
	// Weight: FIR output >> 20 (taps sum to 2^20), clipped to 32 bits
	/////////////////////////////////////////////////////////////////////////////
	wire signed [39:0] y40    = fir_data[59:20];
	wire signed [31:0] weight = (y40 > W_MAX) ? W_MAX[31:0] : (y40 < W_MIN) ? W_MIN[31:0] : y40[31:0];

	stability_detect stability_detect_0 (
		.clk(clk),
		.rst(rst),
		.s_valid(fir_valid),
		.s_data(weight),
		.band(stab_band),
		.count(stab_count),
		.stable(stable)
	);

	wim_estimator wim_estimator_0 (
		.clk(clk),
		.rst(rst),
		.s_valid(fir_valid),
		.s_data(weight),
		.enter(wim_enter),
		.exit_th(wim_exit),
		.settle(wim_settle),
		.stb(wim_new),
		.sum(wim_sum),
		.count(wim_count)
	);

	// Result: every Nth weight (N = result_decim, 12 gives 50 Hz); overload of the latest frame
	reg [31:0] dec_cnt = 32'd0;

	always @(posedge clk) begin
		result_new <= 1'b0;
		if (rst) begin
			dec_cnt  <= 32'd0;
			overload <= 1'b0;
		end else begin
			if (fir_valid) begin
				if (dec_cnt + 1 >= result_decim) begin
					dec_cnt    <= 32'd0;
					result     <= weight;
					result_new <= 1'b1;
				end else
					dec_cnt <= dec_cnt + 1'b1;
			end
			if (sum_valid)
				overload <= sum_overload;
		end
	end

endmodule

`default_nettype wire
