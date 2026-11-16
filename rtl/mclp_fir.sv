`default_nettype none

////////////////////////////////////////////////////////////////////////////////
// mclp_fir
// Single-rate FIR, y[n] = sum_k h[k] x[n-k], in full precision: OW = DW + CW + ceil(log2(TAPS)) bits, exact
// for any data and coefficients. Same results as AMD's FIR Compiler v7.2 with integer coefficients and
// full-precision output (checked against its bit-accurate C model).
// One multiply-accumulate per clock: an input sample starts a pass over the TAPS products, and the output
// follows TAPS + 4 clocks later. s_axis_data_tready is low during the pass; at the design's 600 Hz sample
// rate and 50 MHz clock a pass takes 0.1 % of the sample period.
// Coefficients are double-buffered. Reload beats (s_axis_reload, coefficient order h[0]..h[TAPS-1], tlast
// on the last) fill the inactive bank; the next CONFIG beat makes it active, and only a complete reload
// packet is applied. The sample history carries over. The initial taps come from INIT (32-bit hex words,
// sign-extended), as written by coeff/fir64.py. Reset clears the handshakes, not the taps or the history.
////////////////////////////////////////////////////////////////////////////////
module mclp_fir #(
	parameter integer TAPS = 64,
	parameter integer DW   = 36,                    // data
	parameter integer CW   = 18,                    // coefficients
	parameter         INIT = "fir64.mem",
	// AXI4-Stream widths: byte multiples of DW, CW and the output OW = DW + CW + ceil(log2(TAPS))
	parameter integer DTW  = (DW + 7) / 8 * 8,
	parameter integer CTW  = (CW + 7) / 8 * 8,
	parameter integer OTW  = (DW + CW + $clog2(TAPS) + 7) / 8 * 8
) (
	input  wire           aresetn,
	input  wire           aclk,

	// Samples
	input  wire           s_axis_data_tvalid,
	output wire           s_axis_data_tready,
	input  wire [DTW-1:0] s_axis_data_tdata,

	// CONFIG: applies a complete reload packet (tdata unused)
	input  wire           s_axis_config_tvalid,
	output wire           s_axis_config_tready,
	input  wire [7:0]     s_axis_config_tdata,

	// Coefficient reload
	input  wire           s_axis_reload_tvalid,
	output wire           s_axis_reload_tready,
	input  wire           s_axis_reload_tlast,
	input  wire [CTW-1:0] s_axis_reload_tdata,

	// Output, OW bits sign-extended to OTW
	output reg            m_axis_data_tvalid              = 0,
	output reg  [OTW-1:0] m_axis_data_tdata               = 0,
	output reg            event_s_reload_tlast_missing    = 0,
	output reg            event_s_reload_tlast_unexpected = 0
);

	localparam integer OW = DW + CW + $clog2(TAPS);
	localparam integer AB = (TAPS > 1) ? $clog2(TAPS) : 1;

	reg  [31:0]            coef [0:2*TAPS-1];       // bank b at b*TAPS; 32-bit words as in INIT
	reg  [DW-1:0]          hist [0:TAPS-1];         // sample history, circular, newest at wp
	reg                    bank   = 1'b0;           // active coefficient bank
	reg  [AB-1:0]          wp     = 0;
	reg  [AB-1:0]          r_idx  = 0;
	reg                    r_done = 1'b0;           // a complete reload packet waits for CONFIG
	reg                    busy   = 1'b0;
	reg                    rd_on  = 1'b0;           // reading taps
	reg  [AB-1:0]          k      = 0;              // tap being read
	reg  [AB-1:0]          xi     = 0;              // its sample, wp - k modulo TAPS

	// pipeline: read, RAM output register, multiply, accumulate
	reg  [31:0]            c_rd = 0, c_q = 0;
	reg  [DW-1:0]          x_rd = 0, x_q = 0;
	reg                    v_rd = 1'b0, first_rd = 1'b0, last_rd = 1'b0;
	reg                    v_q = 1'b0, first_q = 1'b0, last_q = 1'b0;
	reg  signed [DW+CW-1:0] prod = 0;
	reg                    v_p = 1'b0, first_p = 1'b0, last_p = 1'b0;
	reg  signed [OW-1:0]   acc = 0;
	wire signed [OW-1:0]   base = first_p ? 0 : acc;   // signed 0: an unsigned operand would zero-extend prod
	wire signed [OW-1:0]   sum  = base + prod;

	integer i;
	initial begin
		$readmemh(INIT, coef, 0, TAPS - 1);
		for (i = 0; i < TAPS; i = i + 1)
			hist[i] = 0;                            // zero history, as the C model starts
	end

	wire take_cfg  = aresetn && !busy && s_axis_config_tvalid;
	wire take_data = aresetn && !busy && !s_axis_config_tvalid && s_axis_data_tvalid;
	wire swap      = take_cfg && r_done;
	wire take_rld  = aresetn && !swap && s_axis_reload_tvalid;

	assign s_axis_config_tready = aresetn && !busy;
	assign s_axis_data_tready   = aresetn && !busy && !s_axis_config_tvalid;  // CONFIG first in a tie
	assign s_axis_reload_tready = aresetn && !swap;   // no beat into the bank that is becoming active

	// coefficient RAM: reload writes the inactive bank, the pass reads the active one
	always @(posedge aclk) begin
		if (take_rld)
			coef[(bank ? 0 : TAPS) + r_idx] <= {{(32 - CW){s_axis_reload_tdata[CW-1]}}, s_axis_reload_tdata[CW-1:0]};
		c_rd <= coef[(bank ? TAPS : 0) + k];
		c_q  <= c_rd;                               // block RAM output register
	end

	// sample history
	always @(posedge aclk) begin
		if (take_data)
			hist[(wp == TAPS - 1) ? 0 : wp + 1] <= s_axis_data_tdata[DW-1:0];
		x_rd <= hist[xi];
		x_q  <= x_rd;
	end

	always @(posedge aclk) begin
		m_axis_data_tvalid              <= 1'b0;
		event_s_reload_tlast_missing    <= 1'b0;
		event_s_reload_tlast_unexpected <= 1'b0;

		// reload handshake and CONFIG
		if (!aresetn) begin
			r_idx  <= 0;
			r_done <= 1'b0;
		end else begin
			if (take_rld) begin
				event_s_reload_tlast_unexpected <= s_axis_reload_tlast && (r_idx != TAPS - 1);
				event_s_reload_tlast_missing    <= !s_axis_reload_tlast && (r_idx == TAPS - 1);
				r_idx <= s_axis_reload_tlast ? 0 : r_idx + 1'b1;
				if (s_axis_reload_tlast)
					r_done <= 1'b1;
			end
			if (swap) begin
				bank   <= !bank;
				r_done <= 1'b0;
			end
		end

		// pass control: k runs 0..TAPS-1 over the taps, newest sample first
		if (!aresetn) begin
			busy  <= 1'b0;
			rd_on <= 1'b0;
		end else if (take_data) begin
			busy  <= 1'b1;
			rd_on <= 1'b1;
			wp    <= (wp == TAPS - 1) ? 0 : wp + 1'b1;
			xi    <= (wp == TAPS - 1) ? 0 : wp + 1'b1;
			k     <= 0;
		end else if (rd_on) begin
			rd_on <= (k != TAPS - 1);
			k     <= k + 1'b1;
			xi    <= (xi == 0) ? TAPS - 1 : xi - 1'b1;
		end

		v_rd     <= aresetn && rd_on;
		first_rd <= (k == 0);
		last_rd  <= (k == TAPS - 1);

		v_q     <= aresetn && v_rd;
		first_q <= first_rd;
		last_q  <= last_rd;

		prod    <= $signed(x_q) * $signed(c_q[CW-1:0]);
		v_p     <= aresetn && v_q;
		first_p <= first_q;
		last_p  <= last_q;

		if (v_p) begin
			acc <= sum;
			if (last_p) begin
				m_axis_data_tvalid <= 1'b1;
				m_axis_data_tdata  <= {{(OTW - OW){sum[OW-1]}}, sum};
				busy               <= 1'b0;
			end
		end
	end

endmodule

`default_nettype wire
