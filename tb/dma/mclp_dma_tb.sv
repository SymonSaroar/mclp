// DMA path test for xsim: mclp_top with the real block design. The PS7 simulates as AMD's Zynq-7000 VIP
// (register access over M_AXI_GP0, DDR model behind S_AXI_HP0); the AXI DMA and both SmartConnects are
// the real IP. Only the MMCM is the stand-in from tb/system. 8 AD7190 models as in the system test.
// The test does what capture() in sw/common/mclp_ops.c does: reset the S2MM channel, build the cyclic
// descriptor ring in DDR, one-shot of N_REC records at tap 0, poll the descriptors' Cmplt bits; then it
// checks every record against the samples the models sent. DDR contents are read from what crossed the
// S_AXI_HP0 pins (see ddr below). About 8 ms of simulated time.
// Created by: vivado -mode batch -source tcl/mclp.tcl -tclargs --sim dma ...
`timescale 1ns / 1ps
`define PS dut.zynq_ps_wrapper_0.zynq_ps_i.processing_system7_0.inst
module mclp_dma_tb;
	localparam [31:0] REGS = 32'h43C0_0000, DMA = 32'h4040_0000;
	localparam [31:0] CTRL = REGS + 12'h004, IRQ_ST = REGS + 12'h00C, TRIG_CFG = REGS + 12'h04C,
		SEQRESP = REGS + 12'h800;
	localparam [31:0] DMACR = DMA + 8'h30, DMASR = DMA + 8'h34, CURDESC = DMA + 8'h38, TAILDESC = DMA + 8'h40;
	localparam [31:0] EN = 1, RAW_EN = 64, SW_TRIG = 128, CAPTURE_DONE = 64;
	localparam integer N_BD = 16, N_REC = 8;                  // ring of 16, one-shot of 8 (capture() keeps n < ring)
	localparam [31:0] RING = 32'h0100_0000;                   // above the OCM, in the VIP's DDR model
	localparam [31:0] FILL = 32'hA5A5_A5A5;                   // buffer bytes the DMA must not touch read this

	// PS clock and power-on resets for the VIP; the PS makes FCLK0 and the PL reset from them
	reg  ps_clk_r = 1'b0, ps_rstn_r = 1'b0;
	always #15 ps_clk_r = ~ps_clk_r;                          // 33.33 MHz
	wire ps_clk = ps_clk_r, ps_rstn = ps_rstn_r;

	wire        sclk, din, cs_n, sync_n;
	tri1 [7:0]  dout;
	reg         mclk = 1'b0;
	always #101.725 mclk = ~mclk;                             // 4.9152 MHz
	reg signed [23:0] sample [0:7];
	integer     errors = 0;

	mclp_top dut (
		.FIXED_IO_ps_clk(ps_clk), .FIXED_IO_ps_porb(ps_rstn), .FIXED_IO_ps_srstb(ps_rstn),
		.adc_sclk(sclk), .adc_din(din), .adc_cs_n(cs_n), .adc_sync_n(sync_n), .adc_dout(dout)
	);

	for (genvar k = 0; k < 8; k++) begin : g_adc
		ad7190_model u_adc (
			.mclk, .sclk, .din, .cs_n, .sync_n, .dout(dout[k]), .sample(sample[k]),
			.open_wire(1'b0), .no_ref(1'b0)
		);
	end

	task automatic check(input bit ok, input string what);
		if (ok) $display("[%0t] ok   %s", $time, what);
		else begin
			errors++;
			$error("%s", what);
		end
	endtask

	// GP0 register access through the VIP (bus cycles); DDR setup through its memory model (no bus cycles)
	task automatic wr(input [31:0] a, input [31:0] d);
		reg [1:0] resp;
		`PS.write_data(a, 4, d, resp);
		if (resp != 0) check(0, $sformatf("write 0x%08X: response %0d", a, resp));
	endtask

	task automatic rd(input [31:0] a, output [31:0] d);
		reg [1023:0] data;
		reg [1:0]    resp;
		`PS.read_data(a, 4, data, resp);
		d = data[31:0];
		if (resp != 0) check(0, $sformatf("read 0x%08X: response %0d", a, resp));
	endtask

	// DDR as written over S_AXI_HP0, taken from the port pins. The checks read this copy and not the VIP's
	// DDR model: the 2025.1 VIP answered OKAY to descriptor 7's status write (0x8C000028 to 0x010001DC, on
	// the pins) and never stored it. The DMA still fetches its descriptors from the VIP's model.
	localparam integer RING_BYTES = 2 * 64 * N_BD;           // descriptors, then buffers
	logic [7:0]  ddr [0:RING_BYTES-1];
	bit   [31:0] aw_q [$];
	bit   [2:0]  sz_q [$];
	int          beat = 0;
	always @(posedge `PS.S_AXI_HP0_ACLK) begin
		if (`PS.S_AXI_HP0_AWVALID && `PS.S_AXI_HP0_AWREADY) begin
			aw_q.push_back(`PS.S_AXI_HP0_AWADDR);
			sz_q.push_back(`PS.S_AXI_HP0_AWSIZE);
		end
		if (`PS.S_AXI_HP0_WVALID && `PS.S_AXI_HP0_WREADY) begin : w_beat
			bit [31:0] a, o;
			// W in AW order, INCR bursts; the AXI DMA and the SmartConnect issue nothing else
			if (aw_q.size() == 0) $fatal(1, "HP0: write data before its address, not handled");
			a = (aw_q[0] >> sz_q[0] << sz_q[0]) + (beat << sz_q[0]);
			for (int l = 0; l < 8; l++)
				if (`PS.S_AXI_HP0_WSTRB[l]) begin
					o = {a[31:3], 3'b000} + l - RING;
					if (o < RING_BYTES) ddr[o] = `PS.S_AXI_HP0_WDATA[8*l +: 8];
					else check(0, $sformatf("HP0 write outside the ring at 0x%08X", o + RING));
				end
			beat++;
			if (`PS.S_AXI_HP0_WLAST) begin
				void'(aw_q.pop_front());
				void'(sz_q.pop_front());
				beat = 0;
			end
		end
	end

	task automatic mem_wr(input [31:0] a, input [31:0] d);
		reg [1023:0] data;
		data = d;
		`PS.write_mem(data, a, 4);
		for (int i = 0; i < 4; i++) ddr[a - RING + i] = d[8*i +: 8];
	endtask

	task automatic mem_rd(input [31:0] a, output [31:0] d);
		for (int i = 0; i < 4; i++) d[8*i +: 8] = ddr[a - RING + i];
	endtask

	// layout of sw/common/mclp_ops.c: descriptor i at RING + 64 i, buffer i at RING + 64 (N_BD + i)
	function automatic [31:0] bd(input integer i);  return RING + 64 * i;          endfunction
	function automatic [31:0] buf_(input integer i); return RING + 64 * (N_BD + i); endfunction

	initial begin : watchdog
		#50_000_000;
		$fatal(1, "watchdog: test did not finish");
	end

	initial begin : test
		reg [31:0] v, st, w0, w1;
		reg [47:0] ts, ts_prev;
		integer    got, t;

		for (int k = 0; k < 8; k++) sample[k] = 400_000 + 20_000 * k;

		// ---- PS power-on, then the PL reset; the init list runs from the PL reset (3 ms)
		repeat (20) @(posedge ps_clk_r);
		ps_rstn_r = 1'b1;
		repeat (5) @(posedge ps_clk_r);
		`PS.fpga_soft_reset(32'h1);
		`PS.fpga_soft_reset(32'h0);
		#3_000_000;
		rd(REGS, v);
		check(v == 32'h4D4C_0108, "ID register over M_AXI_GP0");
		for (int k = 0; k < 8; k++) begin
			rd(SEQRESP + 4 * k, v);
			check(v[3:0] == 4'h4, $sformatf("AD7190 %0d ID", k));
		end
		if (errors != 0) $fatal(1, "front end did not come up");

		// ---- capture(): stop raw records, reset the S2MM channel
		wr(CTRL, EN);
		#2_000_000;
		wr(DMACR, 32'h4);
		t = 0;
		do begin rd(DMACR, v); t++; end while (v[2] && t < 1000);
		check(!v[2], "S2MM reset done");

		// ---- dma_arm(): cyclic ring, buffers prefilled so a stray or long write shows. The descriptor's
		// reserved and APP words are zeroed first: dma_arm() leaves them as they are, which is harmless in DDR,
		// but the VIP's DDR model reads unwritten bytes as X and the HP0 protocol checker stops on X data.
		for (int i = 0; i < N_BD; i++) begin
			for (int w = 0; w < 64; w += 4) mem_wr(bd(i) + w, 0);
			mem_wr(bd(i) + 0,  bd((i + 1) % N_BD));
			mem_wr(bd(i) + 4,  0);
			mem_wr(bd(i) + 8,  buf_(i));
			mem_wr(bd(i) + 12, 0);
			mem_wr(bd(i) + 24, 64);
			mem_wr(bd(i) + 28, 0);
			for (int b = 0; b < 64; b += 4) mem_wr(buf_(i) + b, FILL);
		end
		wr(CURDESC, bd(0));
		wr(DMACR, 32'h1 | 32'h10);                             // RS, cyclic
		wr(TAILDESC, bd(N_BD));                                // outside the chain: starts cyclic mode

		// ---- one-shot of N_REC records at tap 0, software trigger
		wr(TRIG_CFG, (N_REC << 16) | 1);
		wr(CTRL, EN | RAW_EN);
		wr(IRQ_ST, CAPTURE_DONE);
		wr(CTRL, EN | RAW_EN | SW_TRIG);

		// ---- poll the Cmplt bits, as capture() does (N_REC x 208 us)
		got = 0;
		for (t = 0; t < 100 && got < N_REC; t++) begin
			mem_rd(bd(got) + 28, st);
			while (got < N_REC && st[31]) begin
				got++;
				mem_rd(bd(got) + 28, st);
			end
			if (got < N_REC) #100_000;
		end
		check(got == N_REC, $sformatf("%0d of %0d descriptors complete", got, N_REC));
		wr(CTRL, EN);
		#1_000_000;

		// ---- descriptors: Cmplt, RXSOF, RXEOF, 40 bytes; nothing after the last record
		for (int i = 0; i < N_REC; i++) begin
			mem_rd(bd(i) + 28, st);
			check(st == 32'h8C00_0028, $sformatf("descriptor %0d status 0x%08X (Cmplt, SOF, EOF, 40 bytes)", i, st));
		end
		mem_rd(bd(N_REC) + 28, st);
		check(st == 0, "one-shot stopped: descriptor after the last record untouched");
		for (int i = 0; i <= N_REC; i++) begin                // information only: where the VIP's model differs
			reg [1023:0] d;
			`PS.read_mem(bd(i) + 28, 4, d);
			mem_rd(bd(i) + 28, st);
			if (d[31:0] !== st)
				$display("note: VIP DDR model holds 0x%08X for descriptor %0d's status, HP0 wrote 0x%08X", d[31:0], i, st);
		end

		// ---- records (record_get): {ts, tap, faults}, then s1:s0 .. s7:s6, little endian
		for (int i = 0; i < N_REC; i++) begin
			mem_rd(buf_(i), w0);
			mem_rd(buf_(i) + 4, w1);
			ts = {w1, w0[31:16]};
			check(w0[15:14] == 2'd0 && w0[7:0] == 0, $sformatf("record %0d header: tap 0, no faults", i));
			for (int k = 0; k < 8; k++) begin
				mem_rd(buf_(i) + 8 + 4 * k, v);
				check($signed(v) == sample[k], $sformatf("record %0d channel %0d = %0d", i, k, $signed(v)));
			end
			if (i > 0)
				check(ts - ts_prev >= 4165 && ts - ts_prev <= 4168,
				      $sformatf("record %0d timestamp step %0d clk_spi ticks", i, ts - ts_prev));
			ts_prev = ts;
			for (int b = 40; b < 64; b += 4) begin
				mem_rd(buf_(i) + b, v);
				if (v != FILL) check(0, $sformatf("record %0d: byte %0d written past the record", i, b));
			end
		end

		// ---- DMA and mclp status
		rd(DMASR, v);
		check(!v[0] && (v & 32'h770) == 0, $sformatf("DMASR 0x%08X: running, no errors", v));
		rd(IRQ_ST, v);
		check(v[6], "IRQ status: capture done");

		$display("DMA TEST %s, %0d errors", errors == 0 ? "PASSED" : "FAILED", errors);
		$finish;
	end
endmodule
