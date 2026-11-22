`default_nettype none

////////////////////////////////////////////////////////////////////////////////
// mclp_nn
// Inference engine, clk domain clk_dsp. After each weigh-in-motion result it runs the model held in the layer,
// bias and weight memories on the last 256 of every 4th weight, ending at the load's exit sample, and returns a
// correction to the result and the corrected estimate.
//
// Input stage: ref = WIM_SUM / WIM_COUNT clamped to 1 .. 2^31-1, k = bit length of ref, R = 2^(k+21) / ref
// (one shared 64-cycle divider, twice); each weight x becomes q = sat8((d * R + 2^(k+10)) >>> (k+11)) with
// d = x - ref clamped to +-2^k, so q = (x / ref - 1) * 1024.
// Layers: convolutions over the valid positions (a dense layer is one with K = L), acc = bias + sum(w * a) in
// 48 bits, one multiply-accumulate per clock; hidden layers requantize to sat8((acc * M + 2^(s-1)) >>> s),
// clipped at 0 with ReLU. The last layer gives corr = sat32 of the same, Q0.20, and
// est = sat32(ref + ((ref * corr + 2^19) >>> 20)).
// Layer words (four per layer, from word 0 to the one marked last):
//   w0 [31] last [30] ReLU [29:26] stride [25:16] K [15:8] C [7:0] O    w1 [25:16] L [9:0] T
//   w2 [21:16] s [14:0] M                                                w3 [31:16] first bias [15:0] first weight byte
// Weights int8 in (O, C, K) order, four per word, first in [7:0]. A layer's C * L and O * T must fit 1024.
// A result that arrives while the engine is busy is not run. The ring keeps filling during a run; the window is
// in the activation buffer about 1200 clocks after the result, long before a fourth new sample could overwrite
// it. No sample may arrive between the load's exit sample and wim_new (wim_estimator's read-back is shorter
// than a sample period).
////////////////////////////////////////////////////////////////////////////////
module mclp_nn (
	// Clock and reset
	input  wire               clk,
	input  wire               rst,

	// Control (clk)
	input  wire               enable,              // run after each weigh-in-motion result

	// Weight stream and weigh-in-motion result
	input  wire               s_valid,
	input  wire signed [31:0] s_data,
	input  wire               wim_new,
	input  wire signed [63:0] wim_sum,
	input  wire [31:0]        wim_count,

	// Model memories (mclp_registers, read latency 1)
	output wire [5:0]         lay_addr,
	input  wire [31:0]        lay_q,
	output wire [7:0]         bias_addr,
	input  wire [31:0]        bias_q,
	output wire [11:0]        wt_addr,
	input  wire [31:0]        wt_q,

	// Result
	output reg                done   = 0,
	output reg  signed [31:0] est    = 0,
	output reg  signed [31:0] corr   = 0,
	output reg  [31:0]        cycles = 0,
	output wire               busy
);

	localparam [3:0] ST_IDLE = 4'd0;
	localparam [3:0] ST_DIV1 = 4'd1;                  // ref = WIM_SUM / WIM_COUNT
	localparam [3:0] ST_DIV2 = 4'd2;                  // R = 2^(k+21) / ref
	localparam [3:0] ST_IN   = 4'd3;                  // window to activation buffer A
	localparam [3:0] ST_LOAD = 4'd4;                  // layer words
	localparam [3:0] ST_PREP = 4'd5;
	localparam [3:0] ST_RUN  = 4'd6;
	localparam [3:0] ST_WAIT = 4'd7;                  // pipeline drains
	localparam [3:0] ST_OUT1 = 4'd8;
	localparam [3:0] ST_OUT2 = 4'd9;

	reg [3:0] state = ST_IDLE;
	assign busy = (state != ST_IDLE);

	function [5:0] bitlen(input [31:0] v);
		integer i;
		begin
			bitlen = 6'd0;
			for (i = 0; i < 32; i = i + 1)
				if (v[i]) bitlen = i + 1;
		end
	endfunction

	/////////////////////////////////////////////////////////////////////////////
	// Ring of the last 1024 weights; activation buffers A (0..1023) and B (1024..2047)
	/////////////////////////////////////////////////////////////////////////////
	reg  signed [31:0] ring [0:1023];
	reg  [9:0]         rp     = 10'd0;               // next write
	wire [9:0]         ring_ra;
	reg  signed [31:0] ring_q = 32'sd0;
	reg  signed [7:0]  act [0:2047];
	wire [10:0]        act_ra;
	reg  signed [7:0]  act_q  = 8'sd0;
	reg                act_we = 1'b0;
	reg  [10:0]        act_wa = 11'd0;
	reg  signed [7:0]  act_wd = 8'sd0;

	// Zero at configuration, as the block RAM powers up: a window in the first 1.7 s holds zeros before the weights
	integer ri;
	initial for (ri = 0; ri < 1024; ri = ri + 1) ring[ri] = 32'sd0;

	always @(posedge clk) begin
		if (s_valid) begin
			ring[rp] <= s_data;
			rp       <= rp + 1'b1;
		end
		ring_q <= ring[ring_ra];
		act_q  <= act[act_ra];
		if (act_we)
			act[act_wa] <= act_wd;
	end

	/////////////////////////////////////////////////////////////////////////////
	// Divider: 64-bit dividend / 32-bit divisor, one quotient bit per clock
	/////////////////////////////////////////////////////////////////////////////
	reg  [63:0] dv_q = 64'd0;                         // dividend, shifted out as the quotient shifts in
	reg  [31:0] dv_r = 32'd0;
	reg  [31:0] dv_d = 32'd0;
	reg  [6:0]  dv_n = 7'd0;
	wire [32:0] dv_t  = {dv_r, dv_q[63]};
	wire        dv_ge = dv_t >= {1'b0, dv_d};

	/////////////////////////////////////////////////////////////////////////////
	// Input stage and layer state
	/////////////////////////////////////////////////////////////////////////////
	reg  signed [32:0] ref_v = 33'sd1;                // ref, positive
	reg  [5:0]         k_ref = 6'd1;
	reg  [22:0]        r_inv = 23'd0;
	reg  [9:0]         rp_s  = 10'd0;
	reg  [8:0]         j     = 9'd0;                  // window sample
	reg  [1:0]         ph    = 2'd0;
	reg  signed [56:0] in_p  = 57'sd0;
	reg  [31:0]        cnt   = 32'd0;

	wire signed [33:0] in_d   = ring_q - ref_v;
	wire signed [33:0] in_lim = 34'sd1 <<< k_ref;
	wire signed [33:0] in_dc  = (in_d > in_lim) ? in_lim : (in_d < -in_lim) ? -in_lim : in_d;
	wire signed [56:0] in_sh  = (in_p + (57'sd1 <<< (k_ref + 10))) >>> (k_ref + 11);

	reg  [3:0]  li   = 4'd0;                          // layer
	reg  [2:0]  ld   = 3'd0;
	reg         l_last = 1'b0, l_relu = 1'b0;
	reg  [3:0]  l_s  = 4'd1;                          // stride
	reg  [9:0]  l_k  = 10'd1, l_l = 10'd1, l_t = 10'd1;
	reg  [7:0]  l_c  = 8'd1, l_o = 8'd1;
	reg  [5:0]  l_sh = 6'd1;
	reg  [14:0] l_m  = 15'd0;
	reg  [7:0]  l_b  = 8'd0;
	reg  [13:0] l_w  = 14'd0;
	reg  [17:0] l_ck = 18'd0;

	// Issue counters: o, t, c, k; weight byte pointer; activation row c * L + t * S
	reg  [7:0]  o = 8'd0, c = 8'd0;
	reg  [9:0]  t = 10'd0, k = 10'd0;
	reg  [10:0] ts = 11'd0, arow = 11'd0;
	reg  [13:0] wptr = 14'd0, wob = 14'd0;
	reg  [9:0]  dptr = 10'd0;
	reg  [3:0]  drain = 4'd0;

	wire        run   = (state == ST_RUN);
	wire        k_end = (k == l_k - 1'b1);
	wire        c_end = (c == l_c - 1'b1);
	wire        t_end = (t == l_t - 1'b1);
	wire        o_end = (o == l_o - 1'b1);

	assign lay_addr  = {li, ld[1:0]};
	assign bias_addr = l_b + o;
	assign wt_addr   = wptr[13:2];

	assign ring_ra = rp_s + 10'd3 + {j[7:0], 2'b00};  // oldest of the window is the newest - 1020
	assign act_ra  = {li[0], arow[9:0] + k};

	// MAC pipeline: stage 1 has the memory data, stage 2 the product
	reg         v1 = 1'b0, f1 = 1'b0, e1 = 1'b0;      // valid, first, end of an output
	reg  [1:0]  bs1 = 2'd0;
	reg         v2 = 1'b0, f2 = 1'b0, e2 = 1'b0;
	reg  signed [15:0] pr2 = 16'sd0;
	reg  signed [31:0] b2  = 32'sd0;
	reg  signed [47:0] acc = 48'sd0;
	reg         fv = 1'b0;                            // final accumulator ready
	reg  signed [47:0] fin = 48'sd0;
	reg         rv1 = 1'b0, rv2 = 1'b0;
	reg  signed [63:0] rq1 = 64'sd0, rq2 = 64'sd0;
	reg  signed [63:0] oe  = 64'sd0;

	wire signed [7:0]  w8    = wt_q[8*bs1 +: 8];
	wire signed [47:0] b2e   = b2;                    // sign-extended; a concatenation would make the sum unsigned
	wire signed [47:0] acc_n = (f2 ? b2e : acc) + pr2;
	wire signed [63:0] est_n = ref_v + ((oe + 64'sd524288) >>> 20);

	always @(posedge clk) begin
		done   <= 1'b0;
		act_we <= 1'b0;
		if (state != ST_IDLE)
			cnt <= cnt + 1'b1;

		// MAC and requantization pipeline
		v1  <= run;
		f1  <= (c == 8'd0) && (k == 10'd0);
		e1  <= c_end && k_end;
		bs1 <= wptr[1:0];
		v2  <= v1;
		f2  <= f1;
		e2  <= e1;
		pr2 <= w8 * act_q;
		b2  <= bias_q;
		fv  <= v2 && e2;
		if (v2) begin
			acc <= acc_n;
			fin <= acc_n;
		end
		rv1 <= fv;
		rq1 <= fin * $signed({1'b0, l_m});
		rv2 <= rv1;
		rq2 <= (rq1 + (64'sd1 <<< (l_sh - 1'b1))) >>> l_sh;
		if (rv2) begin
			if (l_last)
				corr <= (rq2 > 64'sd2147483647) ? 32'sh7FFF_FFFF : (rq2 < -64'sd2147483648) ? 32'sh8000_0000 : rq2[31:0];
			else begin
				act_we <= 1'b1;
				act_wa <= {~li[0], dptr};
				act_wd <= (rq2 > 64'sd127) ? 8'sd127 : (rq2 < (l_relu ? 64'sd0 : -64'sd128)) ? (l_relu ? 8'sd0 : -8'sd128) : rq2[7:0];
				dptr   <= dptr + 1'b1;
			end
		end

		if (rst) begin
			state <= ST_IDLE;
		end else begin
			case (state)
				ST_IDLE: begin
					if (wim_new && enable) begin
						rp_s <= rp;
						cnt  <= 32'd0;
						if (wim_sum <= 64'sd0) begin
							ref_v <= 33'sd1;
							k_ref <= 6'd1;
							dv_q  <= 64'd1 << 22;
							dv_d  <= 32'd1;
							dv_r  <= 32'd0;
							dv_n  <= 7'd0;
							state <= ST_DIV2;
						end else begin
							dv_q  <= wim_sum;
							dv_d  <= wim_count;
							dv_r  <= 32'd0;
							dv_n  <= 7'd0;
							state <= ST_DIV1;
						end
					end
				end
				ST_DIV1, ST_DIV2: begin
					dv_r <= dv_ge ? dv_t - {1'b0, dv_d} : dv_t[31:0];
					dv_q <= {dv_q[62:0], dv_ge};
					dv_n <= dv_n + 1'b1;
					if (dv_n == 7'd63) begin
						if (state == ST_DIV1) begin
							// the last quotient bit is dv_ge; ref = quotient clamped to 1 .. 2^31-1
							if (|dv_q[62:30] || (dv_q[29:0] == 30'd0 && !dv_ge)) begin
								ref_v <= (|dv_q[62:30]) ? 33'sd2147483647 : 33'sd1;
								k_ref <= (|dv_q[62:30]) ? 6'd31 : 6'd1;
								dv_q  <= 64'd1 << ((|dv_q[62:30]) ? 52 : 22);
								dv_d  <= (|dv_q[62:30]) ? 32'd2147483647 : 32'd1;
							end else begin
								ref_v <= {2'b00, dv_q[29:0], dv_ge};
								k_ref <= bitlen({dv_q[29:0], dv_ge});
								dv_q  <= 64'd1 << (bitlen({dv_q[29:0], dv_ge}) + 21);
								dv_d  <= {dv_q[29:0], dv_ge};
							end
							dv_r  <= 32'd0;
							dv_n  <= 7'd0;
							state <= ST_DIV2;
						end else begin
							r_inv <= {dv_q[21:0], dv_ge};
							j     <= 9'd0;
							ph    <= 2'd0;
							state <= ST_IN;
						end
					end
				end
				ST_IN: begin
					// ph 0: ring address out; 1: ring data; 2: product; 3: write
					ph <= ph + 1'b1;
					if (ph == 2'd2)
						in_p <= in_dc * $signed({1'b0, r_inv});
					if (ph == 2'd3) begin
						act_we <= 1'b1;
						act_wa <= {3'b000, j[7:0]};
						act_wd <= (in_sh > 57'sd127) ? 8'sd127 : (in_sh < -57'sd128) ? -8'sd128 : in_sh[7:0];
						j      <= j + 1'b1;
						if (j == 9'd255) begin
							li    <= 4'd0;
							ld    <= 3'd0;
							state <= ST_LOAD;
						end
					end
				end
				ST_LOAD: begin
					ld <= ld + 1'b1;
					case (ld)
						3'd1: {l_last, l_relu, l_s, l_k, l_c, l_o} <= lay_q;
						3'd2: {l_l, l_t} <= {lay_q[25:16], lay_q[9:0]};
						3'd3: {l_sh, l_m} <= {lay_q[21:16], lay_q[14:0]};
						3'd4: {l_b, l_w} <= {lay_q[23:16], lay_q[13:0]};
						default: ;
					endcase
					if (ld == 3'd4)
						state <= ST_PREP;
				end
				ST_PREP: begin
					l_ck  <= l_c * l_k;
					o     <= 8'd0;
					t     <= 10'd0;
					c     <= 8'd0;
					k     <= 10'd0;
					ts    <= 11'd0;
					arow  <= 11'd0;
					wptr  <= l_w;
					wob   <= l_w;
					dptr  <= 10'd0;
					state <= ST_RUN;
				end
				ST_RUN: begin
					if (!k_end) begin
						k    <= k + 1'b1;
						wptr <= wptr + 1'b1;
					end else begin
						k <= 10'd0;
						if (!c_end) begin
							c    <= c + 1'b1;
							arow <= arow + l_l;
							wptr <= wptr + 1'b1;
						end else begin
							c <= 8'd0;
							if (!t_end) begin
								t    <= t + 1'b1;
								ts   <= ts + l_s;
								arow <= ts + l_s;
								wptr <= wob;              // same output channel, same weights
							end else begin
								t    <= 10'd0;
								ts   <= 11'd0;
								arow <= 11'd0;
								wob  <= wob + l_ck[13:0];
								wptr <= wptr + 1'b1;      // the next channel's weights follow
								if (!o_end)
									o <= o + 1'b1;
								else begin
									drain <= 4'd0;
									state <= ST_WAIT;
								end
							end
						end
					end
				end
				ST_WAIT: begin
					drain <= drain + 1'b1;
					if (drain == 4'd7) begin
						if (l_last)
							state <= ST_OUT1;
						else begin
							li    <= li + 1'b1;
							ld    <= 3'd0;
							state <= ST_LOAD;
						end
					end
				end
				ST_OUT1: begin
					oe    <= ref_v * corr;
					state <= ST_OUT2;
				end
				ST_OUT2: begin
					est    <= (est_n > 64'sd2147483647) ? 32'sh7FFF_FFFF : (est_n < -64'sd2147483648) ? 32'sh8000_0000 : est_n[31:0];
					cycles <= cnt;
					done   <= 1'b1;
					state  <= ST_IDLE;
				end
				default: state <= ST_IDLE;
			endcase
		end
	end

endmodule

`default_nettype wire
