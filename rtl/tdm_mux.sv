`default_nettype none

////////////////////////////////////////////////////////////////////////////////
// tdm_mux
// N_CH:1 mux: one AD7190 frame (N_CH lanes of {offset-binary data, status}) becomes N_CH AXI-Stream beats
// {5'd0, ts[47:0], flags[4:0], ch[5:0], data[23:0]} with data in two's complement and tlast on the last
// channel. flags: [0] ERR, [1] NOREF, [2] parity error, [3] RDY bit set (stale word), [4] loopback mismatch.
// A frame that arrives while the previous one is still draining is dropped; frames are
// 208 us apart and draining takes N_CH cycles plus back-pressure.
////////////////////////////////////////////////////////////////////////////////
module tdm_mux #(
	parameter integer N_CH = 8
) (
	// Clock and reset
	input  wire                 clk,
	input  wire                 rst,

	// Frame input
	input  wire                 frame_valid,
	input  wire [32*N_CH-1:0]   frame,
	input  wire [47:0]          frame_ts,
	input  wire [N_CH-1:0]      mismatch,

	// Beat output
	output reg                  m_valid = 0,
	input  wire                 m_ready,
	output wire [87:0]          m_data,
	output wire                 m_last
);

	localparam [5:0] LAST = N_CH - 1;

	reg  [32*N_CH-1:0] f  = 0;
	reg  [47:0]        ts = 48'd0;
	reg  [N_CH-1:0]    mm = 0;
	reg  [5:0]         ch = 6'd0;

	wire [31:0]  w     = f[32*ch +: 32];
	wire [4:0]   flags = {mm[ch], w[7], ^{w[31:8], w[4]}, w[5], w[6]};

	assign m_data = {5'd0, ts, flags, ch, w[31:8] ^ 24'h80_0000};
	assign m_last = (ch == LAST);

	always @(posedge clk) begin
		if (rst) begin
			m_valid <= 1'b0;
		end else begin
			if (m_valid && m_ready) begin
				ch <= ch + 1'b1;
				if (ch == LAST)
					m_valid <= 1'b0;
			end
			if (frame_valid && !m_valid) begin
				f       <= frame;
				ts      <= frame_ts;
				mm      <= mismatch;
				ch      <= 6'd0;
				m_valid <= 1'b1;
			end
		end
	end

endmodule

`default_nettype wire
