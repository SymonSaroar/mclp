`default_nettype none

////////////////////////////////////////////////////////////////////////////////
// ch_scale
// Per-channel scale on the TDM stream: y = sat32(((x - offset[ch]) * k[ch]) >>> 30), k in Q2.30
// (1.0 = 0x4000_0000). Instantiated twice: gain/offset (cell calibration) and corner trim (offset 0).
// coef_ch addresses the coefficient RAMs (read latency 1), so k and offset belong to the beat that was
// on the input one cycle earlier. `sat` marks a clipped sample and travels with it.
// Latency 4 cycles, no back-pressure: beats arrive at most once per 8 cycles.
////////////////////////////////////////////////////////////////////////////////
module ch_scale (
	// Clock and reset
	input  wire               clk,
	input  wire               rst,

	// TDM input stream
	input  wire               s_valid,
	input  wire [5:0]         s_ch,
	input  wire               s_last,
	input  wire               s_sat,
	input  wire signed [31:0] s_data,

	// Coefficient RAM read port (read latency 1)
	output wire [5:0]         coef_ch,
	input  wire signed [31:0] k,
	input  wire signed [31:0] offset,

	// TDM output stream
	output wire               m_valid,
	output reg  [5:0]         m_ch = 0,
	output reg                m_last = 0,
	output reg                m_sat = 0,
	output reg  signed [31:0] m_data = 0
);

	localparam signed [34:0] MAX = 35'sd2147483647;
	localparam signed [34:0] MIN = -35'sd2147483648;

	reg  [3:0]         v   = 4'd0;
	reg  [5:0]         ch0 = 6'd0, ch1 = 6'd0, ch2 = 6'd0;
	reg  [2:0]         l   = 3'd0;
	reg  [2:0]         s   = 3'd0;
	reg  signed [31:0] x0  = 32'sd0;
	reg  signed [32:0] d   = 33'sd0;
	reg  signed [31:0] kq  = 32'sd0;
	reg  signed [64:0] p   = 65'sd0;
	wire signed [34:0] y   = p >>> 30;    // |p| < 2^63, so y fits in 35 bits

	assign coef_ch = s_ch;
	assign m_valid = v[3];

	always @(posedge clk) begin
		v <= rst ? 4'd0 : {v[2:0], s_valid};
		// stage 0: input held while the coefficient RAMs read
		x0   <= s_data;
		ch0  <= s_ch;
		l[0] <= s_last;
		s[0] <= s_sat;
		// stage 1: subtract the offset
		d    <= x0 - offset;
		kq   <= k;
		ch1  <= ch0;
		l[1] <= l[0];
		s[1] <= s[0];
		// stage 2: multiply
		p    <= d * kq;
		ch2  <= ch1;
		l[2] <= l[1];
		s[2] <= s[1];
		// stage 3: shift and clip
		m_data <= (y > MAX) ? MAX[31:0] : (y < MIN) ? MIN[31:0] : y[31:0];
		m_sat  <= s[2] | (y > MAX) | (y < MIN);
		m_ch   <= ch2;
		m_last <= l[2];
	end

endmodule

`default_nettype wire
