`default_nettype none

////////////////////////////////////////////////////////////////////////////////
// wim_estimator
// Weigh-in-motion: a load enters with the first sample above `enter` and leaves at the first sample below
// `exit_th`. The result is the sum and count of its samples at or above `level` times its peak (software
// divides), so the entry and exit ramps drop out at any speed. `level` is Q0.16.
// The load's samples wait in a DEPTH-deep buffer. When the buffer is full, the oldest sample is compared with
// the peak up to the arriving one; the rest are compared with the final peak after the exit.
// Timing: samples of a load at least 3 clocks apart; after the exit the buffer is read back, so the next
// sample must come DEPTH + 3 clocks later or more. The 600 Hz weight stream gives 83333 clocks at 50 MHz.
////////////////////////////////////////////////////////////////////////////////
module wim_estimator #(
	parameter integer DEPTH = 1024                 // power of two
) (
	// Clock and reset
	input  wire               clk,
	input  wire               rst,

	// Weight samples
	input  wire               s_valid,
	input  wire signed [31:0] s_data,

	// Configuration
	input  wire signed [31:0] enter,
	input  wire signed [31:0] exit_th,
	input  wire [15:0]        level,

	// Result
	output reg                stb = 0,
	output reg  signed [63:0] sum = 0,
	output reg  [31:0]        count = 0
);

	localparam integer  AW   = $clog2(DEPTH);
	localparam [AW:0]   FULL = DEPTH;

	localparam [2:0] ST_IDLE  = 3'd0;
	localparam [2:0] ST_EVENT = 3'd1;
	localparam [2:0] ST_THR   = 3'd2;              // threshold of the new peak settles
	localparam [2:0] ST_STORE = 3'd3;
	localparam [2:0] ST_DRAIN = 3'd4;
	localparam [2:0] ST_TAIL  = 3'd5;
	localparam [2:0] ST_DONE  = 3'd6;

	reg  signed [31:0] mem [0:DEPTH-1];
	reg  [2:0]         state = ST_IDLE;
	reg  [AW-1:0]      wp    = 0;                  // next write; the oldest sample once the buffer is full
	reg                full  = 1'b0;
	reg  [AW:0]        dr    = 0;                  // read-back address
	reg  signed [31:0] x     = 32'sd0;             // sample to store
	reg  signed [31:0] peak  = 32'sd0;
	reg  signed [48:0] thr   = 49'sd0;             // peak * level
	reg  signed [31:0] q     = 32'sd0;             // buffer read data
	reg                q_dr  = 1'b0;               // q is a read-back word
	reg  signed [63:0] acc   = 64'sd0;
	reg  [31:0]        n     = 32'd0;

	wire [AW-1:0] ra  = (state == ST_DRAIN) ? dr[AW-1:0] : wp;
	wire          hit = $signed({q, 16'd0}) >= thr;
	wire [AW:0]   len = full ? FULL : {1'b0, wp};

	always @(posedge clk) begin
		q    <= mem[ra];
		q_dr <= (state == ST_DRAIN);
		thr  <= peak * $signed({1'b0, level});
		if (state == ST_STORE)
			mem[wp] <= x;
	end

	always @(posedge clk) begin
		stb <= 1'b0;
		if ((state == ST_STORE && full && hit) || (q_dr && hit)) begin
			acc <= acc + q;
			n   <= n + 1'b1;
		end
		if (rst) begin
			state <= ST_IDLE;
		end else begin
			case (state)
				ST_IDLE: begin
					if (s_valid && s_data > enter) begin
						x     <= s_data;
						peak  <= s_data;
						wp    <= 0;
						full  <= 1'b0;
						acc   <= 64'sd0;
						n     <= 32'd0;
						state <= ST_THR;
					end
				end
				ST_EVENT: begin
					if (s_valid) begin
						if (s_data < exit_th) begin
							dr    <= 0;
							state <= ST_DRAIN;
						end else begin
							x     <= s_data;
							if (s_data > peak)
								peak <= s_data;
							state <= ST_THR;
						end
					end
				end
				ST_THR:   state <= ST_STORE;
				ST_STORE: begin
					wp    <= wp + 1'b1;
					if (&wp)
						full <= 1'b1;
					state <= ST_EVENT;
				end
				ST_DRAIN: begin
					dr <= dr + 1'b1;
					if (dr + 1'b1 == len)
						state <= ST_TAIL;
				end
				ST_TAIL:  state <= ST_DONE;            // the last read-back word is counted here
				ST_DONE: begin
					stb   <= 1'b1;
					sum   <= acc;
					count <= n;
					state <= ST_IDLE;
				end
				default: state <= ST_IDLE;
			endcase
		end
	end

endmodule

`default_nettype wire
