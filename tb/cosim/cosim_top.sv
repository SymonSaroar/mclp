// Co-simulation top: mclp_core in the block-design stand-in (tb/system) with eight AD7190 models at
// 4.9152 MHz MCLK. The PS stand-in's AXI4-Lite master and raw-record sink are driven from Python
// (tb/cosim/test_cosim.py), which serves mclp's register traffic over TCP. The Python side sets the ADC
// inputs below.
`timescale 1ns / 1ps
module cosim_top;
	wire          sclk, din, cs_n, sync_n;
	tri1 [7:0]    dout;
	reg           mclk      = 1'b0;
	reg  [191:0]  samples   = 192'd0;           // channel k: two's complement in [24k +: 24]
	reg  [7:0]    open_wire = 8'd0;
	reg  [7:0]    no_ref    = 8'd0;

	always #101.725 mclk = ~mclk;               // 4.9152 MHz

	initial
		if ($test$plusargs("waves")) begin
			$dumpfile("cosim.fst");
			$dumpvars(2, dut);
		end

	mclp_top_wrapper dut (
		.spi_sclk(sclk),
		.spi_sdo(din),
		.spi_cs_n(cs_n),
		.adc_sync_n(sync_n),
		.spi_sdi(dout)
	);

	genvar k;
	generate
		for (k = 0; k < 8; k = k + 1) begin : g_adc
			ad7190_model u_adc (
				.mclk(mclk),
				.sclk(sclk),
				.din(din),
				.cs_n(cs_n),
				.sync_n(sync_n),
				.dout(dout[k]),
				.sample(samples[24*k +: 24]),
				.open_wire(open_wire[k]),
				.no_ref(no_ref[k])
			);
		end
	endgenerate
endmodule
