`default_nettype none

////////////////////////////////////////////////////////////////////////////////
// tdm_mux
// 8:1 mux: one AD7190 frame (8 lanes of {offset-binary data, status}) becomes 8 AXI-Stream beats
// {ts[47:0], flags[4:0], ch[2:0], data[23:0]} with data in two's complement and tlast on channel 7.
// flags: [0] ERR, [1] NOREF, [2] parity error, [3] RDY bit set (stale word), [4] loopback mismatch.
// A frame that arrives while the previous one is still draining is dropped; frames are
// 208 us apart and draining takes 8 cycles.
////////////////////////////////////////////////////////////////////////////////
module tdm_mux (
	// Clock and reset
	input  wire          clk,
	input  wire          rst,

	// Frame input
	input  wire          frame_valid,
	input  wire [255:0]  frame,
	input  wire [47:0]   frame_ts,
	input  wire [7:0]    mismatch,

	// Beat output
	output reg           m_valid = 0,
	input  wire          m_ready,
	output wire [79:0]   m_data,
	output wire          m_last
);

	reg  [255:0] f  = 256'd0;
	reg  [47:0]  ts = 48'd0;
	reg  [7:0]   mm = 8'd0;
	reg  [2:0]   ch = 3'd0;

	wire [31:0]  w     = f[32*ch +: 32];
	wire [4:0]   flags = {mm[ch], w[7], ^{w[31:8], w[4]}, w[5], w[6]};

	assign m_data = {ts, flags, ch, w[31:8] ^ 24'h80_0000};
	assign m_last = (ch == 3'd7);

	always @(posedge clk) begin
		if (rst) begin
			m_valid <= 1'b0;
		end else begin
			if (m_valid && m_ready) begin
				ch <= ch + 1'b1;
				if (ch == 3'd7)
					m_valid <= 1'b0;
			end
			if (frame_valid && !m_valid) begin
				f       <= frame;
				ts      <= frame_ts;
				mm      <= mismatch;
				ch      <= 3'd0;
				m_valid <= 1'b1;
			end
		end
	end

endmodule

`default_nettype wire
