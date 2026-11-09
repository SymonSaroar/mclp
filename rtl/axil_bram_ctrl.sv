`default_nettype none

////////////////////////////////////////////////////////////////////////////////
// axil_bram_ctrl
// AXI4-Lite slave to a BRAM-style register port, one transaction at a time.
// A write takes AW and W together and drives bram_en_a with bram_we_a = WSTRB for one cycle.
// A read drives bram_en_a with bram_we_a = 0 for one cycle and takes bram_rddata_a one cycle later.
////////////////////////////////////////////////////////////////////////////////
module axil_bram_ctrl #(
		parameter integer C_S_AXI_ADDR_WIDTH = 12,
		parameter integer C_S_AXI_DATA_WIDTH = 32
	) (
		// AXI4-Lite Interface
		input  wire                              S_AXI_ACLK,
		input  wire                              S_AXI_ARESETN,
		// Write Address Channel
		input  wire [C_S_AXI_ADDR_WIDTH-1:0]     S_AXI_AWADDR,
		input  wire [2:0]                        S_AXI_AWPROT,
		input  wire                              S_AXI_AWVALID,
		output wire                              S_AXI_AWREADY,
		// Write Data Channel
		input  wire [C_S_AXI_DATA_WIDTH-1:0]     S_AXI_WDATA,
		input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0] S_AXI_WSTRB,
		input  wire                              S_AXI_WVALID,
		output wire                              S_AXI_WREADY,
		// Write Response Channel
		output wire [1:0]                        S_AXI_BRESP,
		output reg                               S_AXI_BVALID = 0,
		input  wire                              S_AXI_BREADY,
		// Read Address Channel
		input  wire [C_S_AXI_ADDR_WIDTH-1:0]     S_AXI_ARADDR,
		input  wire [2:0]                        S_AXI_ARPROT,
		input  wire                              S_AXI_ARVALID,
		output wire                              S_AXI_ARREADY,
		// Read Data Channel
		output reg  [C_S_AXI_DATA_WIDTH-1:0]     S_AXI_RDATA = 0,
		output wire [1:0]                        S_AXI_RRESP,
		output reg                               S_AXI_RVALID = 0,
		input  wire                              S_AXI_RREADY,

		// Register Interface (read latency 1)
		output reg                               bram_en_a = 0,
		output reg  [(C_S_AXI_DATA_WIDTH/8)-1:0] bram_we_a = 0,
		output reg  [C_S_AXI_ADDR_WIDTH-1:0]     bram_addr_a = 0,
		output reg  [C_S_AXI_DATA_WIDTH-1:0]     bram_wrdata_a = 0,
		input  wire [C_S_AXI_DATA_WIDTH-1:0]     bram_rddata_a
	);

	localparam [1:0] ST_IDLE  = 2'd0;
	localparam [1:0] ST_WRESP = 2'd1;
	localparam [1:0] ST_RWAIT = 2'd2;
	localparam [1:0] ST_RRESP = 2'd3;

	reg [1:0] state = ST_IDLE;
	reg       rd_capture = 1'b0;

	// AXI Output Assignments
	assign S_AXI_AWREADY = (state == ST_IDLE) && S_AXI_AWVALID && S_AXI_WVALID;
	assign S_AXI_WREADY  = S_AXI_AWREADY;
	assign S_AXI_ARREADY = (state == ST_IDLE) && S_AXI_ARVALID && !(S_AXI_AWVALID && S_AXI_WVALID);
	assign S_AXI_BRESP   = 2'b00;
	assign S_AXI_RRESP   = 2'b00;

	// Transaction state machine
	always @(posedge S_AXI_ACLK) begin
		bram_en_a  <= 1'b0;
		bram_we_a  <= 0;
		rd_capture <= 1'b0;
		if (!S_AXI_ARESETN) begin
			state        <= ST_IDLE;
			S_AXI_BVALID <= 1'b0;
			S_AXI_RVALID <= 1'b0;
		end else begin
			case (state)
				ST_IDLE: begin
					if (S_AXI_AWREADY) begin
						bram_en_a     <= 1'b1;
						bram_we_a     <= S_AXI_WSTRB;
						bram_addr_a   <= S_AXI_AWADDR;
						bram_wrdata_a <= S_AXI_WDATA;
						S_AXI_BVALID  <= 1'b1;
						state         <= ST_WRESP;
					end else if (S_AXI_ARREADY) begin
						bram_en_a     <= 1'b1;
						bram_addr_a   <= S_AXI_ARADDR;
						rd_capture    <= 1'b1;
						state         <= ST_RWAIT;
					end
				end
				ST_WRESP: begin
					if (S_AXI_BREADY) begin
						S_AXI_BVALID <= 1'b0;
						state        <= ST_IDLE;
					end
				end
				ST_RWAIT: begin
					// The register port presents read data one cycle after bram_en_a
					if (!rd_capture) begin
						S_AXI_RDATA  <= bram_rddata_a;
						S_AXI_RVALID <= 1'b1;
						state        <= ST_RRESP;
					end
				end
				ST_RRESP: begin
					if (S_AXI_RREADY) begin
						S_AXI_RVALID <= 1'b0;
						state        <= ST_IDLE;
					end
				end
			endcase
		end
	end

endmodule

`default_nettype wire
