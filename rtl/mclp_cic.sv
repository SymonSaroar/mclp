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
// One input beat per clock, channels 0..CH-1 in order with s_axis_data_tlast on the last. On every R-th
// frame a channel's output follows its input beat by two clocks (integrators, then combs), with the
// channel in m_axis_data_tuser.
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

	reg  [W-1:0]  integ [0:N*CH-1];               // integrator n of channel c at n*CH + c
	reg  [W-1:0]  delay [0:N*CH-1];               // comb delay n of channel c
	reg  [W-1:0]  a [0:N];                        // this beat's integrator chain (blocking)
	reg  [W-1:0]  d [0:N];                        // and its comb chain
	reg  [CB-1:0] ch    = 0;                      // channel of the next input beat
	reg  [FB-1:0] frame = 0;                      // frame within the decimation period
	reg           c_go  = 1'b0;                   // comb stage: a decimated sample of channel c_ch
	reg  [CB-1:0] c_ch  = 0;
	reg  [W-1:0]  c_in  = 0;
	integer       n;

	assign s_axis_data_tready = aresetn;

	// integrators, every input beat
	always @(posedge aclk) begin
		c_go                   <= 1'b0;
		event_tlast_unexpected <= 1'b0;
		event_tlast_missing    <= 1'b0;
		if (!aresetn) begin
			ch    <= 0;
			frame <= 0;
			for (n = 0; n < N * CH; n = n + 1)
				integ[n] <= 0;
		end else if (s_axis_data_tvalid) begin
			a[0] = {{(W - DW){s_axis_data_tdata[DW-1]}}, s_axis_data_tdata};
			for (n = 0; n < N; n = n + 1) begin
				a[n+1] = integ[n*CH + ch] + a[n];
				integ[n*CH + ch] <= a[n+1];
			end
			c_go <= (frame == R - 1);
			c_ch <= ch;
			c_in <= a[N];
			event_tlast_unexpected <= s_axis_data_tlast && (ch != CH - 1);
			event_tlast_missing    <= !s_axis_data_tlast && (ch == CH - 1);
			ch <= s_axis_data_tlast ? 0 : ch + 1'b1;
			if (s_axis_data_tlast)
				frame <= (frame == R - 1) ? 0 : frame + 1'b1;
		end
	end

	// combs, every R-th frame, one clock later
	always @(posedge aclk) begin
		m_axis_data_tvalid <= 1'b0;
		if (!aresetn) begin
			for (n = 0; n < N * CH; n = n + 1)
				delay[n] <= 0;
		end else if (c_go) begin
			d[0] = c_in;
			for (n = 0; n < N; n = n + 1) begin
				d[n+1] = d[n] - delay[n*CH + c_ch];
				delay[n*CH + c_ch] <= d[n];
			end
			m_axis_data_tvalid <= 1'b1;
			m_axis_data_tdata  <= d[N][W-1 -: OW];
			m_axis_data_tuser  <= c_ch;
			m_axis_data_tlast  <= (c_ch == CH - 1);
		end
	end

endmodule

`default_nettype wire
