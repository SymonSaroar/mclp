// System test of mclp_top for xsim. The PS block design, the MMCM and the CIC and FIR cores are replaced
// by the *_stub.sv models in this folder; 8 AD7190 models run at the nominal 4.9152 MHz MCLK (4800 SPS).
// About 180 ms of simulated time.
// Scenarios: init list and ID; raw capture at tap 0 (bit-exact); gain and trim at tap 3 (bit-exact);
// static weight, stability and the result interrupt; overload; loopback BIST with ERR injection;
// AD7190 self-test (open wire with burnout currents, missing reference); FIR coefficient reload.
`timescale 1ns / 1ps
module mclp_top_tb;
	localparam [11:0] CTRL = 12'h004, STATUS = 12'h008, IRQ_ST = 12'h00C, IRQ_EN = 12'h010,
		RESULT = 12'h020, RESULT_SEQ = 12'h024, STAB_COUNT = 12'h038, DECIM = 12'h048, LB_CFG = 12'h054,
		FAULT = 12'h060, GAIN = 12'h100, TRIM = 12'h140, FIRMEM = 12'h200, SEQMEM = 12'h400, SEQRESP = 12'h800;
	localparam [31:0] EN = 1, LB = 2, RELOAD = 4, SEQ_START = 8, RAW_EN = 64, FAULT_CLR = 256;
	localparam [31:0] UNITY = 32'h4000_0000, LB_PERIOD = 32'd4166 << 16;

	wire        sclk, din, cs_n, sync_n;
	tri1 [7:0]  dout;
	reg         mclk = 1'b0;
	always #101.725 mclk = ~mclk;                     // 4.9152 MHz
	reg signed [23:0] sample [0:7];
	reg   [7:0] open_wire = 0;
	reg   [7:0] no_ref    = 0;
	reg   [31:0] init_list [0:23];
	integer     errors = 0;

	mclp_top dut (.adc_sclk(sclk), .adc_din(din), .adc_cs_n(cs_n), .adc_sync_n(sync_n), .adc_dout(dout));

	for (genvar k = 0; k < 8; k++) begin : g_adc
		ad7190_model u_adc (
			.mclk, .sclk, .din, .cs_n, .sync_n, .dout(dout[k]), .sample(sample[k]),
			.open_wire(open_wire[k]), .no_ref(no_ref[k])
		);
	end

	task automatic wr(input [11:0] a, input [31:0] d);
		dut.zynq_ps_wrapper_0.write32({20'h43C00, a}, d);
	endtask

	task automatic rd(input [11:0] a, output [31:0] d);
		dut.zynq_ps_wrapper_0.read32({20'h43C00, a}, d);
	endtask

	task automatic check(input bit ok, input string what);
		if (ok) $display("[%0t] ok   %s", $time, what);
		else begin
			errors++;
			$error("%s", what);
		end
	endtask

	task automatic ms(input integer n);
		#(n * 1_000_000);
	endtask

	function automatic longint sum_x();
		sum_x = 0;
		for (int k = 0; k < 8; k++) sum_x += sample[k];
	endfunction

	function automatic longint scale(input longint x, input longint k);   // ch_scale with offset 0
		longint y;
		y = (x * k) >>> 30;
		return y > 64'sd2147483647 ? 64'sd2147483647 : y < -64'sd2147483648 ? -64'sd2147483648 : y;
	endfunction

	// index of the header of the first complete record whose words start at or after `from`
	function automatic integer record_after(input integer from);
		for (int i = from + 4; i < dut.zynq_ps_wrapper_0.raw_n; i++)
			if (dut.zynq_ps_wrapper_0.raw_last[i]) return i - 4;
		return -1;
	endfunction

	function automatic signed [31:0] rec_sample(input integer hdr, input integer ch);
		reg [63:0] w;
		w = dut.zynq_ps_wrapper_0.raw_data[hdr + 1 + ch / 2];
		return ch[0] ? w[63:32] : w[31:0];
	endfunction

	task automatic wait_records(input integer from, input integer n);   // n records take n x 208 us
		for (int t = 0; dut.zynq_ps_wrapper_0.raw_n < from + 5 * n + 5; t++) begin
			if (t == 100) $fatal(1, "no raw records after 10 ms");
			#100_000;
		end
	endtask

	reg   [31:0] prog [0:9];
	task automatic run_prog(input integer n, input [31:0] ctrl);   // loads prog[0:n-1], restarts the list
		for (int i = 0; i < n; i++) wr(SEQMEM + 4 * i, prog[i]);
		wr(CTRL, ctrl | SEQ_START);
	endtask

	initial begin : watchdog
		ms(600);
		$fatal(1, "watchdog: test did not finish");
	end

	initial begin : test
		reg   [31:0] v, seq0, r0, r;
		integer      n0, h, h2, d;
		longint      expect_w;
		reg   [31:0] g [0:7];
		reg   [31:0] t [0:7];

		$readmemh("seq_init.mem", init_list);
		for (int k = 0; k < 8; k++) sample[k] = 400_000 + 20_000 * k;

		// ---- init list, ID: reset 0.6 ms, zero-scale calibration 4 conversions (0.83 ms), then streaming
		ms(3);
		rd(12'h000, v);
		check(v == 32'h4D4C_0108, "ID register");
		rd(STATUS, v);
		check(v[0] && !v[1], "MMCM locked, init list finished");
		for (int k = 0; k < 8; k++) begin
			rd(SEQRESP + 4 * k, v);
			check(v[3:0] == 4'h4, $sformatf("AD7190 %0d ID", k));
		end
		if (errors != 0) $fatal(1, "front end did not come up; every later scenario depends on it");
		wr(STAB_COUNT, 10);

		// ---- raw capture, tap 0: AFE words, timestamps 4166.7 clk_spi ticks apart
		n0 = dut.zynq_ps_wrapper_0.raw_n;
		wr(CTRL, EN | RAW_EN);
		wait_records(n0, 3);
		wr(CTRL, EN);
		h = record_after(n0);
		h2 = h + 5;
		check(dut.zynq_ps_wrapper_0.raw_data[h][15:14] == 2'd0, "tap 0 in the header");
		for (int k = 0; k < 8; k++)
			check(rec_sample(h, k) == sample[k], $sformatf("tap 0 channel %0d = %0d", k, sample[k]));
		d = dut.zynq_ps_wrapper_0.raw_data[h2][63:16] - dut.zynq_ps_wrapper_0.raw_data[h][63:16];
		check(d >= 4165 && d <= 4168, $sformatf("frame period %0d clk_spi ticks", d));

		// ---- gain and trim, tap 3: trim(gain(256 x)), 256 = CIC gain 512 with the LSB dropped
		for (int k = 0; k < 8; k++) begin g[k] = UNITY; t[k] = UNITY; end
		g[0] = 32'h2000_0000;                         // 0.5
		t[3] = 32'h6000_0000;                         // 1.5
		wr(GAIN + 0, g[0]);
		wr(TRIM + 12, t[3]);
		ms(1);
		n0 = dut.zynq_ps_wrapper_0.raw_n;
		wr(CTRL, EN | RAW_EN | (3 << 4));
		wait_records(n0, 2);
		wr(CTRL, EN);
		h = record_after(n0) + 5;
		check(dut.zynq_ps_wrapper_0.raw_data[h][15:14] == 2'd3, "tap 3 in the header");
		for (int k = 0; k < 8; k++)
			check(rec_sample(h, k) == scale(scale(256 * longint'(sample[k]), g[k]), t[k]),
			      $sformatf("tap 3 channel %0d", k));
		wr(GAIN + 0, UNITY);
		wr(TRIM + 12, UNITY);

		// ---- static weight: FIR settles (64 x 1.67 ms), then stable after 10 samples
		wr(IRQ_EN, 1);
		ms(130);
		expect_w = 256 * sum_x();
		rd(RESULT, v);
		check($signed(v) == expect_w, $sformatf("RESULT %0d, expected %0d", $signed(v), expect_w));
		rd(STATUS, v);
		check(v[4], "STATUS.stable");
		check(dut.irq, "result interrupt");
		wr(IRQ_ST, 1);
		wr(IRQ_EN, 0);

		// ---- overload: gain ~2.0 on a large input clips channel 1
		wr(GAIN + 4, 32'h7FFF_FFFF);
		sample[1] = 5_000_000;
		ms(4);
		rd(STATUS, v);
		check(v[3], "STATUS.overload");
		wr(GAIN + 4, UNITY);
		sample[1] = 420_000;
		ms(4);
		rd(STATUS, v);
		check(!v[3], "overload clears");

		// ---- loopback BIST: STREAM only, emulator data, then ERR injected on channel 4
		prog[0] = 32'h5000_0000;                     // STREAM
		prog[1] = 32'h0;
		run_prog(2, EN | LB);
		ms(1);
		wr(CTRL, EN | LB | FAULT_CLR);
		ms(2);
		for (int k = 0; k < 8; k++) begin
			rd(FAULT + 4 * k, v);
			check(v == 0, $sformatf("loopback channel %0d fault-free", k));
		end
		wr(IRQ_ST, 32'hFF);
		wr(LB_CFG, LB_PERIOD | (4 << 4) | 2);
		ms(1);
		rd(FAULT + 16, v);
		check(v[0], "injected ERR on channel 4");
		rd(IRQ_ST, v);
		check(v[4], "fault interrupt status");
		wr(LB_CFG, LB_PERIOD);
		for (int i = 0; i < 2; i++) prog[i] = init_list[i];
		run_prog(2, EN);                             // restores the init list, which reruns
		ms(3);

		// ---- AD7190 self-test: burnout currents on, open wire on channel 6, no reference on channel 1
		open_wire[6] = 1;
		no_ref[1]    = 1;
		prog[0] = 32'h4000_0000; prog[1] = 32'h0;            // WAIT_RDY
		prog[2] = 32'h1220_0000; prog[3] = 32'h5800_0000;    // exit continuous read
		prog[4] = 32'h1800_0000; prog[5] = 32'h1000_01D7;    // config with BURN
		prog[6] = 32'h1200_0000; prog[7] = 32'h5C00_0000;    // enter continuous read
		prog[8] = 32'h5000_0000; prog[9] = 32'h0;            // STREAM
		run_prog(10, EN);
		ms(2);
		wr(CTRL, EN | FAULT_CLR);
		ms(2);
		rd(FAULT + 24, v);
		check(v[0], "open wire on channel 6 reads ERR");
		rd(FAULT + 4, v);
		check(v[1:0] == 2'b11, "missing reference on channel 1: NOREF and ERR");
		rd(FAULT + 0, v);
		check(v == 0, "channel 0 fault-free");
		open_wire = 0;
		no_ref    = 0;
		for (int i = 0; i < 10; i++) prog[i] = init_list[i];
		run_prog(10, EN);
		ms(3);

		// ---- FIR reload: one tap of 2^16 at RAM word 0, so the weight is X/16 delayed by the position
		// that word 0 takes in the filter. mclp_fir reloads in coefficient order, so word 0 must act
		// on the newest sample; a load step shows the delay in FIR outputs.
		for (int i = 0; i < 64; i++) wr(FIRMEM + 4 * i, i == 0 ? 32'd65536 : 32'd0);
		wr(DECIM, 1);
		wr(CTRL, EN | RELOAD);
		#1000;                                       // reload_busy crosses back to clk_axi
		do rd(STATUS, v); while (v[2]);
		ms(5);
		rd(RESULT, r0);
		check($signed(r0) == 16 * sum_x(), $sformatf("single-tap FIR gives X/16 (%0d)", $signed(r0)));
		rd(RESULT_SEQ, seq0);
		for (int k = 0; k < 8; k++) sample[k] += 100_000;
		d = -1;
		for (int i = 0; i < 1000 && d < 0; i++) begin
			#200_000;
			rd(RESULT, r);
			if (r != r0) begin
				rd(RESULT_SEQ, v);
				d = v - seq0;
			end
		end
		$display("FIR reload: RAM word 0 acts %0d outputs after the step (CIC adds about 2)", d);
		check(d >= 0 && d <= 6, "RAM word 0 is FIR coefficient 0");
		ms(10);
		rd(RESULT, r);
		check($signed(r) == 16 * sum_x(), "single-tap FIR settles on the new load");

		$display("SYSTEM TEST %s, %0d errors", errors == 0 ? "PASSED" : "FAILED", errors);
		$finish;
	end
endmodule
