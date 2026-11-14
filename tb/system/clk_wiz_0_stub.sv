// Simulation stand-in for the clk_wiz_0 IP (same module name and ports). The MMCME2_ADV model toggles its
// 1 GHz VCO as a signal, which slows the system test; this stub makes ideal 20 MHz and 50 MHz clocks and
// raises locked 100 clk_in1 cycles (1 us) after resetn goes high.
// Like the MMCM, the outputs stay low while resetn is low. The xpm_cdc_async_rst synchronizers read
// "not in reset" during glbl.GSR (first 100 ns), so PL clocks must not run before that.
`timescale 1ns / 1ps
module clk_wiz_0 (
	output reg  clk_spi = 1'b0,
	output reg  clk_dsp = 1'b0,
	input  wire resetn,
	output wire locked,
	input  wire clk_in1
);
	always #25 clk_spi = ~clk_spi & resetn;         // 20 MHz
	always #10 clk_dsp = ~clk_dsp & resetn;         // 50 MHz

	reg [6:0] lock_cnt = 7'd0;
	always @(posedge clk_in1)
		if (!resetn)                lock_cnt <= 7'd0;
		else if (lock_cnt != 7'd100) lock_cnt <= lock_cnt + 7'd1;
	assign locked = (lock_cnt == 7'd100);
endmodule
