`default_nettype none

// mclp_nn with its three model memories as arrays loaded from nn_layers.mem, nn_bias.mem and nn_weights.mem in
// the run directory, read latency 1 as in mclp_registers. A pulse on reload loads the files again.
module nn_tb (
	input  wire               clk,
	input  wire               rst,
	input  wire               reload,
	input  wire               enable,
	input  wire               s_valid,
	input  wire signed [31:0] s_data,
	input  wire               wim_new,
	input  wire signed [63:0] wim_sum,
	input  wire [31:0]        wim_count,
	output wire               done,
	output wire signed [31:0] est,
	output wire signed [31:0] corr,
	output wire [31:0]        cycles,
	output wire               busy
);

	reg  [31:0] lay [0:63];
	reg  [31:0] bias [0:255];
	reg  [31:0] wt [0:4095];
	reg  [31:0] lay_q = 0, bias_q = 0, wt_q = 0;
	wire [5:0]  lay_addr;
	wire [7:0]  bias_addr;
	wire [11:0] wt_addr;

	task load;
		begin
			$readmemh("nn_layers.mem", lay);
			$readmemh("nn_bias.mem", bias);
			$readmemh("nn_weights.mem", wt);
		end
	endtask

	initial load;
	always @(posedge reload) load;

	always @(posedge clk) begin
		lay_q  <= lay[lay_addr];
		bias_q <= bias[bias_addr];
		wt_q   <= wt[wt_addr];
	end

	mclp_nn mclp_nn_0 (
		.clk(clk),
		.rst(rst),
		.enable(enable),
		.s_valid(s_valid),
		.s_data(s_data),
		.wim_new(wim_new),
		.wim_sum(wim_sum),
		.wim_count(wim_count),
		.lay_addr(lay_addr),
		.lay_q(lay_q),
		.bias_addr(bias_addr),
		.bias_q(bias_q),
		.wt_addr(wt_addr),
		.wt_q(wt_q),
		.done(done),
		.est(est),
		.corr(corr),
		.cycles(cycles),
		.busy(busy)
	);

endmodule

`default_nettype wire
