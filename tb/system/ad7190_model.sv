// Behavioral AD7190 for simulation (Icarus and xsim): register file, communications state machine,
// continuous conversion timed by MCLK and FS, SYNC, continuous read, status byte with parity,
// 40-ones reset, internal calibration (4 conversion periods, then idle), burnout, NOREF, internal short.
// `sample` is the two's complement CH0 result the TB wants the chip to return.
// The 500 us post-reset wait and the filter response are not modelled; results are exact.
`timescale 1ns / 1ps
module ad7190_model (
	input  wire                mclk,
	input  wire                sclk,
	input  wire                din,
	input  wire                cs_n,
	input  wire                sync_n,
	output wire                dout,
	input  wire signed [23:0] sample,
	input  wire                open_wire,
	input  wire                no_ref
);
	localparam COMMS = 0, WRITE = 1, READ = 2;

	reg   [23:0] mode, conf, offs, fsr, data, sh;
	reg   [31:0] rsh;
	reg   [7:0]  gpo, cmd;
	reg          rdy_n, err, noref, cread, out, reading_data;
	reg   [2:0]  chd;
	integer      st, nbit, nlen, rs, mcnt, settle, ones;

	task automatic restart;
		mcnt   = 0;
		settle = 4;
		rdy_n  = 1;
	endtask

	task automatic reset_all;
		mode  = 24'h080060;
		conf  = 24'h000117;
		offs  = 24'h800000;
		fsr   = 24'h5A0000;
		gpo   = 0;
		data  = 0;
		err   = 0;
		noref = 0;
		chd   = 0;
		cread = 0;
		st    = COMMS;
		nbit  = 0;
		cmd   = 0;
		out   = 1;
		reading_data = 0;
		restart();
	endtask

	initial begin
		reset_all();
		ones = 0;
	end

	function automatic [7:0] status;
		status = {rdy_n, err, noref, mode[13] & ^data, 1'b0, chd};
	endfunction

	function automatic integer size(input integer r);
		size = (r == 0 || r == 4 || r == 5) ? 8 : (r == 3 && mode[20]) ? 32 : 24;
	endfunction

	assign dout = cs_n ? 1'bz : (st == READ ? out : rdy_n);

	// DIN is sampled on the SCLK rising edge
	always @(posedge sclk) if (!cs_n) begin
		ones = din ? ones + 1 : 0;
		if (ones >= 40) begin
			reset_all();
			ones = 0;
		end else if (st == READ) begin
			if (cread) begin                              // DIN is monitored for the exit command
				cmd = {cmd[6:0], din};
				if (cmd == 8'h58) cread = 0;
			end
			nbit = nbit + 1;
			if (nbit == nlen) begin
				st   = COMMS;
				nbit = 0;
				if (reading_data) rdy_n = 1;
				reading_data = 0;
			end
		end else if (st == WRITE) begin
			sh   = {sh[22:0], din};
			nbit = nbit + 1;
			if (nbit == nlen) begin
				case (rs)
					1: begin mode = sh; restart(); end
					2: conf = sh;
					5: gpo  = sh[7:0];
					6: offs = sh;
					7: fsr  = sh;
					default: ;
				endcase
				st   = COMMS;
				nbit = 0;
			end
		end else if (!cread && !(nbit == 0 && din)) begin  // a leading 1 (WEN) is ignored
			cmd  = {cmd[6:0], din};
			nbit = nbit + 1;
			if (nbit == 8) begin
				nbit = 0;
				rs   = cmd[5:3];
				nlen = size(rs);
				if (!cmd[6]) begin
					if (rs != 0) begin st = WRITE; sh = 0; end
				end else if (rs == 3 && cmd[2]) begin
					cread = 1;
				end else begin
					case (rs)
						0: rsh = status();
						1: rsh = mode;
						2: rsh = conf;
						3: rsh = mode[20] ? {data, status()} : data;
						4: rsh = 8'h04;
						5: rsh = gpo;
						6: rsh = offs;
						default: rsh = fsr;
					endcase
					reading_data = rs == 3;
					st = READ;
				end
			end
		end
	end

	// DOUT shifts on the SCLK falling edge; in continuous read a falling edge after RDY starts a word
	always @(negedge sclk) if (!cs_n) begin
		if (st == COMMS && cread && !rdy_n) begin
			rsh  = mode[20] ? {data, status()} : data;
			nlen = mode[20] ? 32 : 24;
			nbit = 0;
			cmd  = 0;
			reading_data = 1;
			st = READ;
		end
		if (st == READ) out = rsh[nlen - 1 - nbit];
	end

	// conversions: fADC = MCLK / (1024 * FS), first result after 4 periods (sinc4 settling)
	always @(posedge mclk) begin
		if (!sync_n) restart();
		else if (mode[23:21] == 3'b000 || mode[23]) begin
			mcnt = mcnt + 1;
			if (mcnt >= 1024 * (mode[9:0] == 0 ? 1 : mode[9:0])) begin
				mcnt = 0;
				if (settle > 1) settle = settle - 1;
				else if (mode[23]) begin                  // calibration done, chip goes idle
					mode[23:21] = 3'b010;
					rdy_n = 0;
				end else if (!(st == READ && reading_data)) begin  // a word being read is not overwritten
					noref = no_ref && conf[6];
					chd   = conf[11] ? 3 : conf[10] ? 2 : 0;
					if (noref || (open_wire && conf[7] && chd == 0)) begin
						data = 24'hFF_FFFF;
						err  = 1;
					end else begin
						data = (chd == 3 ? 24'sd0 : chd == 2 ? 24'sd2000 : sample) ^ 24'h80_0000;
						err  = 0;
					end
					rdy_n = 0;
				end
			end
		end
	end
endmodule
