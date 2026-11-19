`default_nettype none

////////////////////////////////////////////////////////////////////////////////
// sat_sum
// Sums the channels of a frame (tlast on the last) into 40 bits. The inputs are clipped to 32 bits in
// ch_scale, so the sum is exact for up to 256 channels, and the clipping shows up here as `overload` for
// the frame.
////////////////////////////////////////////////////////////////////////////////
module sat_sum (
	// Clock and reset
	input  wire               clk,
	input  wire               rst,

	// TDM input stream
	input  wire               s_valid,
	input  wire               s_last,
	input  wire               s_sat,
	input  wire signed [31:0] s_data,

	// Frame sum
	output reg                m_valid = 0,
	output reg  signed [39:0] m_data = 0,
	output reg                m_overload = 0
);

	reg signed [39:0] acc = 40'sd0;
	reg               ov  = 1'b0;

	always @(posedge clk) begin
		m_valid <= 1'b0;
		if (rst) begin
			acc <= 40'sd0;
			ov  <= 1'b0;
		end else if (s_valid) begin
			if (s_last) begin
				m_valid    <= 1'b1;
				m_data     <= acc + s_data;
				m_overload <= ov | s_sat;
				acc        <= 40'sd0;
				ov         <= 1'b0;
			end else begin
				acc <= acc + s_data;
				ov  <= ov | s_sat;
			end
		end
	end

endmodule

`default_nettype wire
