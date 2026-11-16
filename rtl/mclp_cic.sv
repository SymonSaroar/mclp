`default_nettype none

////////////////////////////////////////////////////////////////////////////////
// mclp_cic
// CIC decimator (Hogenauer) for CH time-multiplexed channels: N integrators at the input rate, decimation
// by R, N combs with differential delay 1 at the output rate. Transfer function per channel
// H(z) = ((1 - z^-R) / (1 - z^-1))^N, DC gain R^N.
// Every stage is W = DW + ceil(log2(R^N)) bits, full precision. The integrators overflow and wrap; the
// combs subtract in the same modular arithmetic, so the wraps cancel and the output is exact as long as it
// fits in W bits, which R^N times the input always does. The output is the top OW bits of the last comb
// (truncation), gain R^N / 2^(W - OW). Same results as AMD's CIC Compiler v4.0 with decimation, M = 1,
// truncation, which also keeps full-width stages and quantizes only the output.
// Time-shared, as AMD's core is at low sample rates: one W-bit adder works through the stages of a beat,
// one stage per clock, and the 2 * N * CH stage registers live in one distributed RAM. An input beat takes
// N + 1 clocks, 2N + 1 when it ends a decimation period (s_axis_data_tready low meanwhile). After reset
// the core clears the RAM for 2^(ceil(log2(2N)) + ceil(log2(CH))) clocks before it takes input.
// One stage per clock caps the input at clk / (2N + 1) beats (7 M/s at 50 MHz, the design needs
// 38 k/s); pipeline the stages if a design ever needs one beat per clock.
// Channels 0..CH-1 in order with s_axis_data_tlast on the last. Outputs come on frames 0, R, 2R, ... after
// reset, the decimation phase of AMD's core: the first frame already gives an output, H[0] x[0]. A
// channel's output follows its input beat by 2N + 1 clocks, with the channel in m_axis_data_tuser.
////////////////////////////////////////////////////////////////////////////////
module mclp_cic #(
	parameter integer CH = 8,
	parameter integer R  = 8,
	parameter integer N  = 3,
	parameter integer DW = 24,
	parameter integer OW = 32
) (
	input  wire          aclk,
	input  wire          aresetn,

	// Input: CH channels per frame, tlast on the last one
	input  wire [DW-1:0] s_axis_data_tdata,
	input  wire          s_axis_data_tvalid,
	output wire          s_axis_data_tready,
	input  wire          s_axis_data_tlast,

	// Output: one beat per channel every R frames
	output reg  [OW-1:0] m_axis_data_tdata      = 0,
	output reg  [15:0]   m_axis_data_tuser      = 0,
	output reg           m_axis_data_tvalid     = 0,
	output reg           m_axis_data_tlast      = 0,
	output reg           event_tlast_unexpected = 0,
	output reg           event_tlast_missing    = 0
);

	localparam integer W  = DW + $clog2(R ** N);
	localparam integer CB = (CH > 1) ? $clog2(CH) : 1;
	localparam integer FB = (R > 1) ? $clog2(R) : 1;
	localparam integer SB = $clog2(2 * N);

	reg  [W-1:0]  mem [0:2**(SB+CB)-1];           // integrator n of channel c at {n, c}, comb delay n at {N + n, c}
	reg  [W-1:0]  acc   = 0;                      // the beat's value on its way down the stages
	reg  [SB-1:0] step  = 0;                      // stage: integrators 0..N-1, combs N..2N-1
	reg  [CB-1:0] cur   = 0;                      // channel of the beat being worked on
	reg  [CB-1:0] ch    = 0;                      // channel of the next input beat
	reg  [FB-1:0] frame = 0;                      // frame within the decimation period
	reg           go    = 1'b0;                   // the beat ends a decimation period: run the combs too
	reg           busy  = 1'b1;
	reg           clr   = 1'b1;                   // clearing the RAM after reset

	wire [SB+CB-1:0] addr = {step, cur};
	wire          comb = (step >= N);
	wire [W-1:0]  m    = mem[addr];
	wire [W-1:0]  res  = comb ? acc - m : acc + m;

	assign s_axis_data_tready = aresetn && !busy;

	// integrators store the new sum, comb delays the value that came in
	always @(posedge aclk)
		if (busy)
			mem[addr] <= clr ? {W{1'b0}} : comb ? acc : res;

	always @(posedge aclk) begin
		m_axis_data_tvalid     <= 1'b0;
		event_tlast_unexpected <= 1'b0;
		event_tlast_missing    <= 1'b0;
		if (!aresetn) begin
			busy  <= 1'b1;
			clr   <= 1'b1;
			step  <= 0;
			cur   <= 0;
			ch    <= 0;
			frame <= 0;
		end else if (clr) begin
			{step, cur} <= {step, cur} + 1'b1;      // the address sweeps every word
			if (&{step, cur}) begin
				clr  <= 1'b0;
				busy <= 1'b0;
			end
		end else if (!busy) begin
			if (s_axis_data_tvalid) begin
				busy <= 1'b1;
				acc  <= {{(W - DW){s_axis_data_tdata[DW-1]}}, s_axis_data_tdata};
				step <= 0;
				cur  <= ch;
				go   <= (frame == 0);
				event_tlast_unexpected <= s_axis_data_tlast && (ch != CH - 1);
				event_tlast_missing    <= !s_axis_data_tlast && (ch == CH - 1);
				ch <= s_axis_data_tlast ? 0 : ch + 1'b1;
				if (s_axis_data_tlast)
					frame <= (frame == R - 1) ? 0 : frame + 1'b1;
			end
		end else begin
			acc  <= res;
			step <= step + 1'b1;
			if ((step == N - 1 && !go) || step == 2 * N - 1)
				busy <= 1'b0;
			if (step == 2 * N - 1) begin
				m_axis_data_tvalid <= 1'b1;
				m_axis_data_tdata  <= res[W-1 -: OW];
				m_axis_data_tuser  <= cur;
				m_axis_data_tlast  <= (cur == CH - 1);
			end
		end
	end

endmodule

`default_nettype wire
