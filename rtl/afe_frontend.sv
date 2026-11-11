`default_nettype none

////////////////////////////////////////////////////////////////////////////////
// afe_frontend
// AD7190 front end, clk domain clk_spi: pin synchronizer (XPM), SPI master, sequencer, BIST loopback
// and the 8:1 mux into the sample stream. The loopback enters ahead of the synchronizer and sees the
// same timing as the pins.
////////////////////////////////////////////////////////////////////////////////
module afe_frontend (
	// Clock and reset
	input  wire          clk,
	input  wire          rst,

	// Control (clk)
	input  wire          enable,
	input  wire          loopback,
	input  wire          seq_start,
	input  wire [31:0]   loopback_cfg,
	input  wire [23:0]   loopback_value,

	// Sequencer RAM and status
	output wire [7:0]    seq_addr,
	input  wire [31:0]   seq_q,
	output wire          seq_busy,
	output wire [255:0]  seq_resp,

	// AD7190 pins
	output wire          adc_sclk,
	output wire          adc_din,
	output wire          adc_cs_n,
	output wire          adc_sync_n,
	input  wire [7:0]    adc_dout,

	// Sample stream {ts, flags, ch, data}
	output wire          m_valid,
	input  wire          m_ready,
	output wire [79:0]   m_data,
	output wire          m_last
);

	wire [7:0]   emu_dout;
	wire [255:0] emu_words;
	wire [7:0]   dout_pin = loopback ? emu_dout : adc_dout;
	wire [7:0]   dout_sync;
	wire         spi_start, spi_busy, spi_done, frame_valid;
	wire [5:0]   ntx, nrx;
	wire [31:0]  tx;
	wire [255:0] rx;
	wire [47:0]  frame_ts;
	reg  [7:0]   mismatch;
	integer      k;

	assign adc_cs_n = !enable;

	// Loopback checker: received word against the emulator's word, per lane
	always @(*) begin
		for (k = 0; k < 8; k = k + 1)
			mismatch[k] = loopback && (rx[32*k +: 32] != emu_words[32*k +: 32]);
	end

	// DOUT pins are asynchronous to clk; afe_spi samples them two cycles after the synchronizer input
	xpm_cdc_array_single #(
		.DEST_SYNC_FF(2),    // DECIMAL; range: 2-10
		.INIT_SYNC_FF(1),    // DECIMAL; 0=disable simulation init values, 1=enable simulation init values
		.SIM_ASSERT_CHK(0),  // DECIMAL; 0=disable simulation messages, 1=enable simulation messages
		.SRC_INPUT_REG(0),   // DECIMAL; 0=do not register input, 1=register input
		.WIDTH(8)            // DECIMAL; range: 1-1024
	) xpm_cdc_dout_inst (
		.dest_out(dout_sync),
		.dest_clk(clk),
		.src_clk(1'b0),
		.src_in(dout_pin)
	);

	afe_spi afe_spi_0 (
		.clk(clk),
		.rst(rst),
		.start(spi_start),
		.ntx(ntx),
		.nrx(nrx),
		.tx(tx),
		.busy(spi_busy),
		.done(spi_done),
		.rx(rx),
		.sclk(adc_sclk),
		.din(adc_din),
		.dout(dout_sync)
	);

	afe_sequencer #(
		.CLK_MHZ(20)
	) afe_sequencer_0 (
		.clk(clk),
		.rst(rst),
		.enable(enable),
		.start(seq_start),
		.busy(seq_busy),
		.addr(seq_addr),
		.q(seq_q),
		.spi_start(spi_start),
		.ntx(ntx),
		.nrx(nrx),
		.tx(tx),
		.spi_busy(spi_busy),
		.spi_done(spi_done),
		.rx(rx),
		.rdy_n(dout_sync[0]),
		.sync_n(adc_sync_n),
		.resp(seq_resp),
		.frame_valid(frame_valid),
		.frame_ts(frame_ts)
	);

	afe_loopback afe_loopback_0 (
		.clk(clk),
		.rst(rst),
		.cfg(loopback_cfg),
		.value(loopback_value),
		.sclk(adc_sclk),
		.dout(emu_dout),
		.words(emu_words)
	);

	tdm_mux tdm_mux_0 (
		.clk(clk),
		.rst(rst),
		.frame_valid(frame_valid),
		.frame(rx),
		.frame_ts(frame_ts),
		.mismatch(mismatch),
		.m_valid(m_valid),
		.m_ready(m_ready),
		.m_data(m_data),
		.m_last(m_last)
	);

endmodule

`default_nettype wire
