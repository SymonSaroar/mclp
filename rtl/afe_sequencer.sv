`default_nettype none

////////////////////////////////////////////////////////////////////////////////
// afe_sequencer
// Runs AD7190 command lists from the sequencer RAM, then streams conversion frames.
// A command is two words: w0 = {op[3:0], ntx[5:0], nrx[5:0], arg[15:0]}, w1 = tx data, MSB first.
//   0 END       stop, sequencer idle
//   1 XFER      shift ntx bits of w1 out, then read nrx bits on all lanes into resp
//   2 SYNC      SYNC low for 32 clk cycles (1.6 us at 20 MHz; the AD7190 needs 4 MCLK = 0.8 us)
//   3 WAIT_US   wait arg microseconds
//   4 WAIT_RDY  wait for DOUT/RDY low on lane 0 with the SPI engine idle
//   5 STREAM    on every DOUT/RDY falling edge read 32 bits (data + status) from all lanes
// The list runs from address 0 on start and on the rising edge of enable (including power-up).
// Lane 0 alone signals RDY; all chips share MCLK and SYNC, so they convert together.
////////////////////////////////////////////////////////////////////////////////
module afe_sequencer #(
	parameter integer CLK_MHZ = 20,
	parameter integer N_CH    = 8
) (
	// Clock and reset
	input  wire          clk,
	input  wire          rst,

	// Control
	input  wire          enable,
	input  wire          start,
	output wire          busy,           // running a list (idle and streaming are not busy)

	// Sequencer RAM (read latency 1)
	output reg  [7:0]    addr = 0,
	input  wire [31:0]   q,

	// SPI engine
	output reg           spi_start = 0,
	output reg  [5:0]    ntx = 0,
	output reg  [5:0]    nrx = 0,
	output reg  [31:0]   tx = 0,
	input  wire          spi_busy,
	input  wire          spi_done,
	input  wire [32*N_CH-1:0] rx,

	// AD7190 lines
	input  wire          rdy_n,
	output reg           sync_n = 1'b1,

	// Results
	output reg  [32*N_CH-1:0] resp = 0,      // lanes of the last XFER with nrx > 0
	output reg           frame_valid = 0,    // one-cycle pulse, frame in rx
	output reg  [47:0]   frame_ts = 0        // clk count at the DOUT/RDY falling edge of the frame
);

	localparam [3:0] ST_IDLE      = 4'd0;
	localparam [3:0] ST_F0        = 4'd1;
	localparam [3:0] ST_F1        = 4'd2;
	localparam [3:0] ST_F2        = 4'd3;
	localparam [3:0] ST_EXEC      = 4'd4;
	localparam [3:0] ST_XFER_WAIT = 4'd5;
	localparam [3:0] ST_PAUSE     = 4'd6;
	localparam [3:0] ST_RDY_WAIT  = 4'd7;
	localparam [3:0] ST_S_HIGH    = 4'd8;
	localparam [3:0] ST_S_LOW     = 4'd9;
	localparam [3:0] ST_S_READ    = 4'd10;

	localparam [3:0] OP_XFER     = 4'd1;
	localparam [3:0] OP_SYNC     = 4'd2;
	localparam [3:0] OP_WAIT_US  = 4'd3;
	localparam [3:0] OP_WAIT_RDY = 4'd4;
	localparam [3:0] OP_STREAM   = 4'd5;

	reg  [3:0]  state    = ST_IDLE;
	reg  [31:0] w0       = 32'd0;
	reg  [23:0] cnt      = 24'd0;
	reg  [47:0] ts       = 48'd0;
	reg         enable_q = 1'b0;
	wire [3:0]  op       = w0[31:28];

	assign busy = !(state == ST_IDLE || state == ST_S_HIGH || state == ST_S_LOW || state == ST_S_READ);

	always @(posedge clk) begin
		spi_start   <= 1'b0;
		frame_valid <= 1'b0;
		enable_q    <= enable;
		ts          <= ts + 1'b1;
		case (state)
			ST_IDLE: ;
			// RAM reads take one cycle: the RAM sees pc in F0 and pc + 1 in F1
			ST_F0: begin
				addr  <= addr + 1'b1;
				state <= ST_F1;
			end
			ST_F1: begin
				w0    <= q;
				state <= ST_F2;
			end
			ST_F2: begin
				tx    <= q;
				addr  <= addr + 1'b1;
				state <= ST_EXEC;
			end
			ST_EXEC: begin
				case (op)
					OP_XFER: begin
						if (!spi_busy) begin
							ntx       <= w0[27:22];
							nrx       <= w0[21:16];
							spi_start <= 1'b1;
							state     <= ST_XFER_WAIT;
						end
					end
					OP_SYNC: begin
						sync_n <= 1'b0;
						cnt    <= 24'd32;
						state  <= ST_PAUSE;
					end
					OP_WAIT_US: begin
						cnt   <= w0[15:0] * CLK_MHZ;
						state <= ST_PAUSE;
					end
					OP_WAIT_RDY: state <= ST_RDY_WAIT;
					OP_STREAM:   state <= ST_S_LOW;          // a pending word is read at once
					default:     state <= ST_IDLE;
				endcase
			end
			ST_XFER_WAIT: begin
				if (spi_done) begin
					if (nrx != 0)
						resp <= rx;
					state <= ST_F0;
				end
			end
			ST_PAUSE: begin
				if (cnt == 0) begin
					sync_n <= 1'b1;
					state  <= ST_F0;
				end else
					cnt <= cnt - 1'b1;
			end
			ST_RDY_WAIT: begin
				if (!rdy_n && !spi_busy)                 // DOUT carries data while busy
					state <= ST_F0;
			end
			ST_S_HIGH: begin
				if (rdy_n)
					state <= ST_S_LOW;
			end
			ST_S_LOW: begin
				if (!rdy_n && !spi_busy) begin
					frame_ts  <= ts;
					ntx       <= 6'd0;
					nrx       <= 6'd32;
					spi_start <= 1'b1;
					state     <= ST_S_READ;
				end
			end
			ST_S_READ: begin
				if (spi_done) begin
					frame_valid <= 1'b1;
					state       <= ST_S_HIGH;
				end
			end
			default: state <= ST_IDLE;
		endcase
		if (start || (enable && !enable_q)) begin
			addr   <= 8'd0;
			sync_n <= 1'b1;
			state  <= ST_F0;
		end
		if (!enable) begin
			sync_n <= 1'b1;
			state  <= ST_IDLE;
		end
		if (rst) begin
			state    <= ST_IDLE;
			sync_n   <= 1'b1;
			enable_q <= 1'b0;
			ts       <= 48'd0;
			addr     <= 8'd0;
		end
	end

endmodule

`default_nettype wire
