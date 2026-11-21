// Harness for the afe_frontend unit test: front end, sequencer RAM, 8 AD7190 models.
`timescale 1ns / 1ps
module afe_tb (
	input  logic         clk,
	input  logic         rst,
	input  logic         mclk,
	input  logic         enable,
	input  logic         loopback,
	input  logic         seq_start,
	input  logic [31:0]  loopback_cfg,
	input  logic [23:0]  loopback_value,
	input  logic         ram_we,
	input  logic [7:0]   ram_waddr,
	input  logic [31:0]  ram_wdata,
	input  logic [191:0] samples,         // 8 x 24-bit two's complement
	input  logic [7:0]   open_wire,
	input  logic [7:0]   no_ref,
	output logic         seq_busy,
	output logic [255:0] seq_resp,
	output logic         m_valid,
	input  logic         m_ready,
	output logic [87:0]  m_data,
	output logic         m_last
);
	logic [31:0] ram [256];
	logic [7:0]  seq_addr;
	logic [31:0] seq_q;
	wire         sclk, din, cs_n, sync_n;
	tri1 [7:0]   dout;

	initial $readmemh("seq_init.mem", ram);
	always @(posedge clk) begin
		if (ram_we) ram[ram_waddr] <= ram_wdata;
		seq_q <= ram[seq_addr];
	end

	afe_frontend u_fe (
		.clk, .rst, .enable, .loopback, .seq_start, .loopback_cfg, .loopback_value, .seq_addr, .seq_q,
		.seq_busy, .seq_resp, .spi_sclk(sclk), .spi_sdo(din), .spi_cs_n(cs_n), .adc_sync_n(sync_n),
		.spi_sdi(dout), .m_valid, .m_ready, .m_data, .m_last
	);

	for (genvar k = 0; k < 8; k++) begin : g_adc
		ad7190_model u_adc (
			.mclk, .sclk, .din, .cs_n, .sync_n, .dout(dout[k]), .sample(samples[24*k +: 24]),
			.open_wire(open_wire[k]), .no_ref(no_ref[k])
		);
	end
endmodule
