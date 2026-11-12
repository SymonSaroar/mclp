`default_nettype none

////////////////////////////////////////////////////////////////////////////////
// stability_detect
// No-motion detector: `stable` rises once `count` consecutive samples stay within +/-band of a reference.
// A sample outside the band clears `stable` and becomes the new reference.
////////////////////////////////////////////////////////////////////////////////
module stability_detect (
	// Clock and reset
	input  wire               clk,
	input  wire               rst,

	// Weight samples
	input  wire               s_valid,
	input  wire signed [31:0] s_data,

	// Configuration
	input  wire [31:0]        band,
	input  wire [31:0]        count,

	// Status
	output reg                stable = 0
);

	reg  signed [31:0] ref_w = 32'sd0;
	reg  [31:0]        n     = 32'd0;
	wire signed [32:0] diff  = s_data - ref_w;
	wire [32:0]        mag   = (diff < 0) ? -diff : diff;

	always @(posedge clk) begin
		if (rst) begin
			ref_w  <= 32'sd0;
			n      <= 32'd0;
			stable <= 1'b0;
		end else if (s_valid) begin
			if (mag > band) begin
				ref_w  <= s_data;
				n      <= 32'd0;
				stable <= 1'b0;
			end else begin
				if (n < count)
					n <= n + 1'b1;
				stable <= (n + 1 >= count);
			end
		end
	end

endmodule

`default_nettype wire
