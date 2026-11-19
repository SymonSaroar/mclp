`default_nettype none

////////////////////////////////////////////////////////////////////////////////
// afe_spi
// SPI master for N_CH AD7190 sharing SCLK/DIN/CS, one DOUT each. Mode 3: SCLK idles high, DIN changes on
// the falling edge, the ADC samples DIN and shifts DOUT on its edges. 8 clk cycles per bit:
// phase 0 SCLK falls and DIN updates, phase 4 SCLK rises, phase 5 samples dout. dout comes through a
// 2-FF synchronizer, so phase 5 sees the pin at phase 3: 150 ns after the falling edge (DOUT valid after
// 80 ns) and before the rising edge (DOUT/RDY may return high 10 ns after the last one).
// A transfer shifts ntx bits of tx (MSB first), then reads nrx bits on all N_CH lanes with DIN low.
////////////////////////////////////////////////////////////////////////////////
module afe_spi #(
	parameter integer N_CH = 8
) (
	// Clock and reset
	input  wire          clk,
	input  wire          rst,

	// Transfer request
	input  wire          start,
	input  wire [5:0]    ntx,
	input  wire [5:0]    nrx,
	input  wire [31:0]   tx,
	output reg           busy = 0,
	output reg           done = 0,          // one-cycle pulse at the end of a transfer
	output reg  [32*N_CH-1:0] rx = 0,       // lane k at [32k +: 32], last bit in the LSB

	// SPI pins (dout already synchronized)
	output reg           sclk = 1'b1,
	output reg           din = 0,
	input  wire [N_CH-1:0] dout
);

	reg [2:0]  phase     = 3'd0;
	reg [6:0]  bits_left = 7'd0;
	reg [6:0]  rx_left   = 7'd0;
	reg [31:0] sh        = 32'd0;
	integer    k;

	always @(posedge clk) begin
		done <= 1'b0;
		if (rst) begin
			busy <= 1'b0;
			sclk <= 1'b1;
			din  <= 1'b0;
		end else if (!busy) begin
			sclk <= 1'b1;
			din  <= 1'b0;
			if (start && (ntx != 0 || nrx != 0)) begin
				busy      <= 1'b1;
				phase     <= 3'd0;
				sh        <= tx;
				bits_left <= ntx + nrx;
				rx_left   <= {1'b0, nrx};
				rx        <= 0;
			end
		end else begin
			phase <= phase + 1'b1;
			case (phase)
				3'd0: begin
					sclk <= 1'b0;
					din  <= (bits_left > rx_left) ? sh[31] : 1'b0;
					if (bits_left > rx_left)
						sh <= sh << 1;
				end
				3'd4: sclk <= 1'b1;
				3'd5: begin
					if (bits_left <= rx_left)
						for (k = 0; k < N_CH; k = k + 1)
							rx[32*k +: 32] <= {rx[32*k +: 31], dout[k]};
				end
				3'd7: begin
					bits_left <= bits_left - 1'b1;
					if (bits_left <= rx_left)
						rx_left <= rx_left - 1'b1;
					if (bits_left == 7'd1) begin
						busy <= 1'b0;
						done <= 1'b1;
					end
				end
				default: ;
			endcase
		end
	end

endmodule

`default_nettype wire
