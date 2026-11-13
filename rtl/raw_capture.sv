`default_nettype none

////////////////////////////////////////////////////////////////////////////////
// raw_capture
// Packs one frame of the selected tap (8 channels, 32-bit) into a 5-word record for the AXI DMA:
// {ts[47:0], tap[1:0], 6'd0, faults[7:0]}, then {s1,s0}, {s3,s2}, {s5,s4}, {s7,s6} with tlast.
// Modes: 0 continuous; 1 one-shot of `frames` records after sw_trigger; 2 like 1, but the capture starts
// at the first frame whose sum exceeds `threshold` after sw_trigger arms it.
// A record starts only at channel 0 and only if the FIFO is below its threshold (`full`), so the output
// needs no back-pressure; records that do not fit are skipped whole.
////////////////////////////////////////////////////////////////////////////////
module raw_capture (
	// Clock and reset
	input  wire               clk,
	input  wire               rst,

	// Configuration
	input  wire               enable,
	input  wire [1:0]         mode,
	input  wire [15:0]        frames,
	input  wire               sw_trigger,
	input  wire signed [31:0] threshold,
	input  wire [1:0]         tap,

	// Threshold trigger source
	input  wire               sum_valid,
	input  wire signed [35:0] sum,

	// Selected tap stream and header fields
	input  wire               s_valid,
	input  wire [2:0]         s_ch,
	input  wire [31:0]        s_data,
	input  wire [47:0]        ts,
	input  wire [7:0]         faults,

	// Records to the DMA FIFO
	input  wire               full,
	output reg                m_valid = 0,
	output reg  [63:0]        m_data = 0,
	output reg                m_last = 0,
	output wire               active
);

	reg         armed = 1'b0;
	reg         run   = 1'b0;
	reg         rec   = 1'b0;
	reg  [15:0] left  = 16'd0;
	reg  [31:0] even  = 32'd0;
	wire        start = enable && (mode == 2'd0 || (run && left != 0)) && !full;

	assign active = enable && (mode == 2'd0 || armed || run);

	always @(posedge clk) begin
		m_valid <= 1'b0;
		m_last  <= 1'b0;
		if (rst || !enable) begin
			armed <= 1'b0;
			run   <= 1'b0;
			rec   <= 1'b0;
		end else begin
			if (sw_trigger && mode != 2'd0) begin
				armed <= (mode == 2'd2);
				run   <= (mode == 2'd1);
				left  <= frames;
			end
			if (armed && sum_valid && sum > threshold) begin
				armed <= 1'b0;
				run   <= 1'b1;
			end
			if (s_valid) begin
				if (s_ch == 3'd0) begin
					rec  <= start;
					even <= s_data;
					if (start) begin
						m_valid <= 1'b1;
						m_data  <= {ts, tap, 6'd0, faults};
					end
				end else if (!s_ch[0]) begin
					even <= s_data;
				end else if (rec) begin
					m_valid <= 1'b1;
					m_data  <= {s_data, even};
					m_last  <= (s_ch == 3'd7);
					if (s_ch == 3'd7 && mode != 2'd0) begin
						left <= left - 1'b1;
						if (left == 16'd1)
							run <= 1'b0;
					end
				end
			end
		end
	end

endmodule

`default_nettype wire
