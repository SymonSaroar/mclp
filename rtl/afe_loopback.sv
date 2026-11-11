`default_nettype none

////////////////////////////////////////////////////////////////////////////////
// afe_loopback
// BIST front-end loopback: emulates 8 AD7190 in continuous-read mode on the FPGA's own SCLK.
// Every `period` clk cycles all DOUT/RDY lines fall; each SCLK falling edge shifts out the next bit of a
// 32-bit word {offset-binary data, status}; the lines return high after the 32nd bit.
// Lane k sends data = base + (k << 16), base = value (constant mode) or a frame counter (ramp).
// cfg: [0] ramp, [1] inject ERR, [2] inject parity error, [6:4] channel for injection, [31:16] period.
////////////////////////////////////////////////////////////////////////////////
module afe_loopback (
	// Clock and reset
	input  wire          clk,
	input  wire          rst,

	// Configuration
	input  wire [31:0]   cfg,
	input  wire [23:0]   value,

	// Emulated AD7190 lines
	input  wire          sclk,
	output reg  [7:0]    dout = 8'hFF,
	output reg  [255:0]  words = 0           // words of the current frame, for the checker
);

	reg  [15:0] tick   = 16'd0;
	reg  [23:0] frames = 24'd0;
	reg  [5:0]  nbit   = 6'd0;
	reg         sclk_q = 1'b1;
	reg         active = 1'b0;
	wire [23:0] base   = cfg[0] ? frames : value;
	integer     k;

	// {offset-binary data, RDY=0, ERR, NOREF=0, PARITY, 0, CHD=000}; parity makes the data's 1s even
	function [31:0] word;
		input [23:0] b;
		input [2:0]  ch;
		input [31:0] c;
		reg   [23:0] d;
		begin
			d    = (b + {ch, 16'h0}) ^ 24'h80_0000;
			word = {d, 1'b0, c[1] && c[6:4] == ch, 1'b0, ^d ^ (c[2] && c[6:4] == ch), 4'b0000};
		end
	endfunction

	always @(posedge clk) begin
		sclk_q <= sclk;
		tick   <= tick + 1'b1;
		if (rst) begin
			tick   <= 16'd0;
			frames <= 24'd0;
			active <= 1'b0;
			dout   <= 8'hFF;
		end else if (tick >= cfg[31:16] - 1) begin
			tick   <= 16'd0;
			frames <= frames + 1'b1;
			active <= 1'b1;
			nbit   <= 6'd0;
			dout   <= 8'h00;
			for (k = 0; k < 8; k = k + 1)
				words[32*k +: 32] <= word(base, k[2:0], cfg);
		end else if (active && sclk_q && !sclk) begin          // SCLK falling edge
			for (k = 0; k < 8; k = k + 1)
				dout[k] <= words[32*k + 31 - nbit];
			nbit <= nbit + 1'b1;
		end else if (active && !sclk_q && sclk && nbit == 6'd32) begin
			active <= 1'b0;
			dout   <= 8'hFF;
		end
	end

endmodule

`default_nettype wire
