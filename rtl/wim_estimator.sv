`default_nettype none

////////////////////////////////////////////////////////////////////////////////
// wim_estimator
// Weigh-in-motion: a load enters when the weight rises above `enter`. After `settle` samples the plateau
// is accumulated until the weight drops below `exit_th`; the result is the plateau's sum and sample count
// (software divides). A load that leaves during the settle time gives no result.
////////////////////////////////////////////////////////////////////////////////
module wim_estimator (
	// Clock and reset
	input  wire               clk,
	input  wire               rst,

	// Weight samples
	input  wire               s_valid,
	input  wire signed [31:0] s_data,

	// Configuration
	input  wire signed [31:0] enter,
	input  wire signed [31:0] exit_th,
	input  wire [31:0]        settle,

	// Result
	output reg                stb = 0,
	output reg  signed [63:0] sum = 0,
	output reg  [31:0]        count = 0
);

	localparam [1:0] ST_IDLE   = 2'd0;
	localparam [1:0] ST_SETTLE = 2'd1;
	localparam [1:0] ST_ACC    = 2'd2;

	reg [1:0]         state = ST_IDLE;
	reg [31:0]        n     = 32'd0;
	reg signed [63:0] acc   = 64'sd0;

	always @(posedge clk) begin
		stb <= 1'b0;
		if (rst) begin
			state <= ST_IDLE;
		end else if (s_valid) begin
			case (state)
				ST_IDLE: begin
					if (s_data > enter) begin
						n     <= 32'd0;
						state <= ST_SETTLE;
					end
				end
				ST_SETTLE: begin
					if (s_data < exit_th)
						state <= ST_IDLE;
					else if (n + 1 >= settle) begin
						acc   <= 64'sd0;
						n     <= 32'd0;
						state <= ST_ACC;
					end else
						n <= n + 1'b1;
				end
				ST_ACC: begin
					if (s_data < exit_th) begin
						stb   <= 1'b1;
						sum   <= acc;
						count <= n;
						state <= ST_IDLE;
					end else begin
						acc <= acc + s_data;
						n   <= n + 1'b1;
					end
				end
				default: state <= ST_IDLE;
			endcase
		end
	end

endmodule

`default_nettype wire
