`default_nettype none

////////////////////////////////////////////////////////////////////////////////
// coef_reload
// Streams the FIR coefficient RAM (N words, coefficient sign-extended in the low bits, in coefficient
// order) into mclp_fir's reload channel, then sends one CONFIG transfer. The filter switches to the
// new set when it consumes the CONFIG transfer. RAM reads take one cycle.
////////////////////////////////////////////////////////////////////////////////
module coef_reload #(
	parameter integer N = 64
) (
	// Clock and reset
	input  wire                  clk,
	input  wire                  rst,

	// Control
	input  wire                  start,
	output wire                  busy,

	// Coefficient RAM read port (read latency 1)
	output reg  [$clog2(N)-1:0]  addr = 0,
	input  wire [31:0]           q,

	// mclp_fir reload and config channels
	output reg                   reload_valid = 0,
	input  wire                  reload_ready,
	output reg  [23:0]           reload_data = 0,
	output reg                   reload_last = 0,
	output reg                   config_valid = 0,
	input  wire                  config_ready
);

	localparam [2:0] ST_IDLE   = 3'd0;
	localparam [2:0] ST_WAIT   = 3'd1;
	localparam [2:0] ST_LOAD   = 3'd2;
	localparam [2:0] ST_SEND   = 3'd3;
	localparam [2:0] ST_CONFIG = 3'd4;

	reg [2:0] state = ST_IDLE;

	assign busy = (state != ST_IDLE);

	always @(posedge clk) begin
		if (rst) begin
			state        <= ST_IDLE;
			addr         <= 0;
			reload_valid <= 1'b0;
			config_valid <= 1'b0;
		end else begin
			case (state)
				ST_IDLE: begin
					if (start) begin
						addr  <= 0;
						state <= ST_WAIT;
					end
				end
				ST_WAIT: state <= ST_LOAD;               // RAM sees addr
				ST_LOAD: begin
					reload_data  <= q[23:0];
					reload_last  <= (addr == N - 1);
					reload_valid <= 1'b1;
					state        <= ST_SEND;
				end
				ST_SEND: begin
					if (reload_ready) begin
						reload_valid <= 1'b0;
						if (reload_last) begin
							config_valid <= 1'b1;
							state        <= ST_CONFIG;
						end else begin
							addr  <= addr + 1'b1;
							state <= ST_WAIT;
						end
					end
				end
				ST_CONFIG: begin
					if (config_ready) begin
						config_valid <= 1'b0;
						state        <= ST_IDLE;
					end
				end
				default: state <= ST_IDLE;
			endcase
		end
	end

endmodule

`default_nettype wire
