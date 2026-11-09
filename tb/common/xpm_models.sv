`timescale 1ns / 1ps

////////////////////////////////////////////////////////////////////////////////
// Behavioral stand-ins for the XPM macros used inside unit-tested RTL, for Icarus only.
// Port lists match the Vivado macros; behavior covers the parameters this design uses.
// Like the real macros, the synchronizer flops start at X unless INIT_SYNC_FF = 1.
// Vivado simulation and synthesis use the real macros (this folder is not in the project).
////////////////////////////////////////////////////////////////////////////////

module xpm_cdc_single #(
		parameter integer DEST_SYNC_FF   = 4,
		parameter integer INIT_SYNC_FF   = 0,
		parameter integer SIM_ASSERT_CHK = 0,
		parameter integer SRC_INPUT_REG  = 1
	) (
		input  wire src_clk,
		input  wire src_in,
		input  wire dest_clk,
		output wire dest_out
	);

	reg src_q = INIT_SYNC_FF ? 1'b0 : 1'bx;
	reg [DEST_SYNC_FF-1:0] sync = {DEST_SYNC_FF{INIT_SYNC_FF ? 1'b0 : 1'bx}};

	always @(posedge src_clk) src_q <= src_in;
	always @(posedge dest_clk) sync <= {sync[DEST_SYNC_FF-2:0], SRC_INPUT_REG ? src_q : src_in};
	assign dest_out = sync[DEST_SYNC_FF-1];

endmodule

module xpm_cdc_array_single #(
		parameter integer DEST_SYNC_FF   = 4,
		parameter integer INIT_SYNC_FF   = 0,
		parameter integer SIM_ASSERT_CHK = 0,
		parameter integer SRC_INPUT_REG  = 1,
		parameter integer WIDTH          = 2
	) (
		input  wire             src_clk,
		input  wire [WIDTH-1:0] src_in,
		input  wire             dest_clk,
		output wire [WIDTH-1:0] dest_out
	);

	reg [WIDTH-1:0] src_q = {WIDTH{INIT_SYNC_FF ? 1'b0 : 1'bx}};
	reg [WIDTH-1:0] sync [0:DEST_SYNC_FF-1];
	integer i;

	initial for (i = 0; i < DEST_SYNC_FF; i = i + 1) sync[i] = {WIDTH{INIT_SYNC_FF ? 1'b0 : 1'bx}};

	always @(posedge src_clk) src_q <= src_in;
	always @(posedge dest_clk) begin
		sync[0] <= SRC_INPUT_REG ? src_q : src_in;
		for (i = 1; i < DEST_SYNC_FF; i = i + 1) sync[i] <= sync[i-1];
	end
	assign dest_out = sync[DEST_SYNC_FF-1];

endmodule

module xpm_cdc_async_rst #(
		parameter integer DEST_SYNC_FF    = 4,
		parameter integer INIT_SYNC_FF    = 0,
		parameter integer RST_ACTIVE_HIGH = 0
	) (
		input  wire src_arst,
		input  wire dest_clk,
		output wire dest_arst
	);

	localparam [0:0] ASSERTED = RST_ACTIVE_HIGH ? 1'b1 : 1'b0;

	wire                   arst = RST_ACTIVE_HIGH ? src_arst : !src_arst;
	reg [DEST_SYNC_FF-1:0] sync = {DEST_SYNC_FF{~ASSERTED}};   // the macro declares it deasserted

	always @(posedge dest_clk or posedge arst)
		if (arst) sync <= {DEST_SYNC_FF{ASSERTED}};
		else      sync <= {sync[DEST_SYNC_FF-2:0], ~ASSERTED};
	assign dest_arst = sync[DEST_SYNC_FF-1];

endmodule

module xpm_cdc_pulse #(
		parameter integer DEST_SYNC_FF   = 4,
		parameter integer INIT_SYNC_FF   = 0,
		parameter integer REG_OUTPUT     = 0,
		parameter integer RST_USED       = 1,
		parameter integer SIM_ASSERT_CHK = 0
	) (
		input  wire src_clk,
		input  wire src_pulse,
		input  wire src_rst,
		input  wire dest_clk,
		input  wire dest_rst,
		output wire dest_pulse
	);

	reg toggle = 1'b0;
	reg [DEST_SYNC_FF:0] sync = {(DEST_SYNC_FF+1){INIT_SYNC_FF ? 1'b0 : 1'bx}};

	always @(posedge src_clk) if (src_pulse) toggle <= ~toggle;
	always @(posedge dest_clk) sync <= {sync[DEST_SYNC_FF-1:0], toggle};
	assign dest_pulse = sync[DEST_SYNC_FF] ^ sync[DEST_SYNC_FF-1];

endmodule

module xpm_cdc_handshake #(
		parameter integer DEST_EXT_HSK   = 1,
		parameter integer DEST_SYNC_FF   = 4,
		parameter integer INIT_SYNC_FF   = 0,
		parameter integer SIM_ASSERT_CHK = 0,
		parameter integer SRC_SYNC_FF    = 4,
		parameter integer WIDTH          = 1
	) (
		input  wire             src_clk,
		input  wire [WIDTH-1:0] src_in,
		input  wire             src_send,
		output wire             src_rcv,
		input  wire             dest_clk,
		output reg  [WIDTH-1:0] dest_out = {WIDTH{INIT_SYNC_FF ? 1'b0 : 1'bx}},
		output reg              dest_req = INIT_SYNC_FF ? 1'b0 : 1'bx,
		input  wire             dest_ack
	);

	reg                    src_q    = INIT_SYNC_FF ? 1'b0 : 1'bx;
	reg  [WIDTH-1:0]       src_data = {WIDTH{INIT_SYNC_FF ? 1'b0 : 1'bx}};
	reg  [DEST_SYNC_FF-1:0] req_sync = {DEST_SYNC_FF{INIT_SYNC_FF ? 1'b0 : 1'bx}};
	reg                    req_q    = INIT_SYNC_FF ? 1'b0 : 1'bx;
	reg  [SRC_SYNC_FF-1:0] ack_sync = {SRC_SYNC_FF{INIT_SYNC_FF ? 1'b0 : 1'bx}};
	wire                   req      = req_sync[DEST_SYNC_FF-1];

	always @(posedge src_clk) begin
		if (!src_q) src_data <= src_in;          // held while a transfer is in flight
		src_q    <= src_send;
		ack_sync <= {ack_sync[SRC_SYNC_FF-2:0], DEST_EXT_HSK ? dest_ack : req_q};
	end

	always @(posedge dest_clk) begin
		req_sync <= {req_sync[DEST_SYNC_FF-2:0], src_q};
		req_q    <= req;
		dest_req <= req && !req_q;
		if (req && !req_q) dest_out <= src_data;
	end

	assign src_rcv = ack_sync[SRC_SYNC_FF-1];

endmodule

module xpm_memory_tdpram #(
		parameter integer ADDR_WIDTH_A       = 6,
		parameter integer ADDR_WIDTH_B       = 6,
		parameter integer BYTE_WRITE_WIDTH_A = 32,
		parameter integer BYTE_WRITE_WIDTH_B = 32,
		parameter         CLOCKING_MODE      = "common_clock",
		parameter         MEMORY_INIT_FILE   = "none",
		parameter         MEMORY_INIT_PARAM  = "",
		parameter         MEMORY_PRIMITIVE   = "auto",
		parameter integer MEMORY_SIZE        = 2048,
		parameter integer READ_DATA_WIDTH_A  = 32,
		parameter integer READ_DATA_WIDTH_B  = 32,
		parameter integer READ_LATENCY_A     = 1,
		parameter integer READ_LATENCY_B     = 1,
		parameter integer USE_MEM_INIT       = 1,
		parameter integer WRITE_DATA_WIDTH_A = 32,
		parameter integer WRITE_DATA_WIDTH_B = 32,
		parameter         WRITE_MODE_A       = "no_change",
		parameter         WRITE_MODE_B       = "no_change"
	) (
		input  wire                                                sleep,
		input  wire                                                clka,
		input  wire                                                rsta,
		input  wire                                                ena,
		input  wire                                                regcea,
		input  wire [(WRITE_DATA_WIDTH_A/BYTE_WRITE_WIDTH_A)-1:0] wea,
		input  wire [ADDR_WIDTH_A-1:0]                             addra,
		input  wire [WRITE_DATA_WIDTH_A-1:0]                       dina,
		input  wire                                                injectsbiterra,
		input  wire                                                injectdbiterra,
		output reg  [READ_DATA_WIDTH_A-1:0]                        douta,
		output wire                                                sbiterra,
		output wire                                                dbiterra,
		input  wire                                                clkb,
		input  wire                                                rstb,
		input  wire                                                enb,
		input  wire                                                regceb,
		input  wire [(WRITE_DATA_WIDTH_B/BYTE_WRITE_WIDTH_B)-1:0] web,
		input  wire [ADDR_WIDTH_B-1:0]                             addrb,
		input  wire [WRITE_DATA_WIDTH_B-1:0]                       dinb,
		input  wire                                                injectsbiterrb,
		input  wire                                                injectdbiterrb,
		output reg  [READ_DATA_WIDTH_B-1:0]                        doutb,
		output wire                                                sbiterrb,
		output wire                                                dbiterrb
	);

	reg [WRITE_DATA_WIDTH_A-1:0] mem [0:MEMORY_SIZE/WRITE_DATA_WIDTH_A-1];
	integer i;

	initial begin
		for (i = 0; i < MEMORY_SIZE/WRITE_DATA_WIDTH_A; i = i + 1) mem[i] = 0;
		if (MEMORY_INIT_FILE != "none") $readmemh(MEMORY_INIT_FILE, mem);
	end

	always @(posedge clka) if (ena) begin
		if (wea[0]) mem[addra] <= dina;
		douta <= mem[addra];
	end
	always @(posedge clkb) if (enb) begin
		if (web[0]) mem[addrb] <= dinb;
		doutb <= mem[addrb];
	end
	assign {sbiterra, dbiterra, sbiterrb, dbiterrb} = 4'b0000;

endmodule

module xpm_fifo_axis #(
		parameter         CLOCKING_MODE       = "common_clock",
		parameter         FIFO_MEMORY_TYPE    = "auto",
		parameter         PACKET_FIFO         = "false",
		parameter integer FIFO_DEPTH          = 2048,
		parameter integer TDATA_WIDTH         = 32,
		parameter integer TID_WIDTH           = 1,
		parameter integer TDEST_WIDTH         = 1,
		parameter integer TUSER_WIDTH         = 1,
		parameter integer SIM_ASSERT_CHK      = 0,
		parameter integer CDC_SYNC_STAGES     = 2,
		parameter integer RELATED_CLOCKS      = 0,
		parameter         ECC_MODE            = "no_ecc",
		parameter         USE_ADV_FEATURES    = "1000",
		parameter integer WR_DATA_COUNT_WIDTH = 1,
		parameter integer RD_DATA_COUNT_WIDTH = 1,
		parameter integer PROG_FULL_THRESH    = 10,
		parameter integer PROG_EMPTY_THRESH   = 10
	) (
		input  wire                           s_aresetn,
		input  wire                           s_aclk,
		input  wire                           m_aclk,
		input  wire                           s_axis_tvalid,
		output wire                           s_axis_tready,
		input  wire [TDATA_WIDTH-1:0]         s_axis_tdata,
		input  wire [TDATA_WIDTH/8-1:0]       s_axis_tstrb,
		input  wire [TDATA_WIDTH/8-1:0]       s_axis_tkeep,
		input  wire                           s_axis_tlast,
		input  wire [TID_WIDTH-1:0]           s_axis_tid,
		input  wire [TDEST_WIDTH-1:0]         s_axis_tdest,
		input  wire [TUSER_WIDTH-1:0]         s_axis_tuser,
		output wire                           m_axis_tvalid,
		input  wire                           m_axis_tready,
		output wire [TDATA_WIDTH-1:0]         m_axis_tdata,
		output wire [TDATA_WIDTH/8-1:0]       m_axis_tstrb,
		output wire [TDATA_WIDTH/8-1:0]       m_axis_tkeep,
		output wire                           m_axis_tlast,
		output wire [TID_WIDTH-1:0]           m_axis_tid,
		output wire [TDEST_WIDTH-1:0]         m_axis_tdest,
		output wire [TUSER_WIDTH-1:0]         m_axis_tuser,
		output wire                           prog_full_axis,
		output wire [WR_DATA_COUNT_WIDTH-1:0] wr_data_count_axis,
		output wire                           almost_full_axis,
		output wire                           prog_empty_axis,
		output wire [RD_DATA_COUNT_WIDTH-1:0] rd_data_count_axis,
		output wire                           almost_empty_axis,
		input  wire                           injectsbiterr_axis,
		input  wire                           injectdbiterr_axis,
		output wire                           sbiterr_axis,
		output wire                           dbiterr_axis
	);

	reg [TDATA_WIDTH:0] q [0:FIFO_DEPTH-1];
	integer wp = 0, rp = 0;
	wire [31:0] level = wp - rp;

	assign s_axis_tready = s_aresetn && level < FIFO_DEPTH;
	assign m_axis_tvalid = wp != rp;
	assign {m_axis_tlast, m_axis_tdata} = q[rp % FIFO_DEPTH];
	assign prog_full_axis = level >= PROG_FULL_THRESH;
	assign {m_axis_tstrb, m_axis_tkeep, m_axis_tid, m_axis_tdest, m_axis_tuser} = 0;
	assign {wr_data_count_axis, almost_full_axis, prog_empty_axis, rd_data_count_axis, almost_empty_axis} = 0;
	assign {sbiterr_axis, dbiterr_axis} = 2'b00;

	always @(posedge s_aclk) begin
		if (!s_aresetn) wp <= rp;
		else if (s_axis_tvalid && s_axis_tready) begin
			q[wp % FIFO_DEPTH] <= {s_axis_tlast, s_axis_tdata};
			wp <= wp + 1;
		end
	end
	always @(posedge m_aclk) if (m_axis_tvalid && m_axis_tready) rp <= rp + 1;

endmodule
