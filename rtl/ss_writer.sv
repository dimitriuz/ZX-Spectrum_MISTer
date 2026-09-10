//============================================================================
//  Savestate writer: emits an uncompressed .z80 v3 image as a byte stream.
//
//  The field layout is the inverse of the parser in rtl/snap_loader.sv:414-480
//  - that file is the spec. Three invariants the parser depends on:
//
//    * bytes 6-7 must be zero, or snap_loader reads the file as v1 (:433)
//    * byte 12 must never be 0xFF, which it special-cases as border 0 (:429)
//    * byte 30-31 must be 55 so the #1FFD byte at offset 86 is in range
//
//  num_banks == 0 emits the header alone, which is what the header testbench
//  exercises.
//============================================================================

module ss_writer
(
	input             clk,
	// Abandons the stream and returns every output to its idle value. Driven
	// from rtl/savestate.sv by `reset | wdog_fire`, i.e. by BOTH of the ways
	// savestate can walk away from a save in progress. Without it the writer
	// kept streaming after an abort with out_valid still high, and the next
	// save wrote the TAIL of the abandoned snapshot into the slot and then
	// reported INFO_SAVED - destroying whatever good state the slot held.
	input             reset,
	// One-cycle pulse; inputs stable on this cycle. Honoured from ANY state,
	// not just ST_IDLE: this is the second line of defence for the abort case
	// above, so a future abort path that forgets to pulse `reset` still
	// re-initialises the FSM instead of resuming a stale stream.
	input             start,
	output reg        active = 0,

	input     [211:0] cpu_reg,
	input       [7:0] port_7ffd,
	input       [7:0] port_1ffd,
	input       [2:0] border,
	input       [7:0] hw_mode,
	input       [5:0] num_banks,
	input             banks48,

	// AY register file shadow (ZX-Spectrum.sv snoops turbosound's write
	// port so no changes to turbosound.sv/ym2149.sv are needed). ay_regs
	// packs the 16 registers 8 bits each, reg0 at bits [7:0]; ay_sel is
	// the currently-selected register (last OUT to #FFFD).
	input     [127:0] ay_regs,
	input       [3:0] ay_sel,

	output reg [24:0] ram_addr = 0,
	output reg        ram_rd = 0,
	input       [7:0] ram_dout,
	input             ram_ready,

	// out_byte and out_last are COMBINATIONAL. Registering out_byte while
	// hdr_idx advances on the beat presents every value a cycle late and
	// emits byte 0 twice.
	output      [7:0] out_byte,
	// Power-on value, like rtl/ddr_cdc.sv's and rtl/ddram_arb.sv's registers:
	// Cyclone V powers registers to 0 so hardware does not depend on it, but
	// without it out_valid is X on the first edge and savestate.sv's ST_S_BYTE
	// would treat that X as a valid byte in simulation.
	output reg        out_valid = 0,
	input             out_ready,
	output            out_last
);

// NOTE: state was widened from [2:0] (8 codes, exactly full at ST_IDLE..
// ST_RDCAP) to [3:0] to make room for ST_RDPOLL below - see the same-word
// hit fix in ST_RDWAIT/ST_RDPOLL further down.
localparam ST_IDLE   = 4'd0;
localparam ST_HEADER = 4'd1;
localparam ST_BLKHDR = 4'd2;
localparam ST_RDREQ  = 4'd3;
localparam ST_RDWAIT = 4'd4;
localparam ST_RDPOLL = 4'd5;
localparam ST_RDCAP  = 4'd6;
localparam ST_DATA   = 4'd7;
localparam ST_DONE   = 4'd8;

reg  [3:0] state = ST_IDLE;
reg  [6:0] hdr_idx;

// Latched at start so the stream is coherent even if the machine moves on.
reg [211:0] r_cpu;
reg   [7:0] r_7ffd, r_1ffd, r_hw;
reg   [2:0] r_border;
reg   [5:0] r_banks;
reg         r_banks48;
reg [127:0] r_ay_regs;
reg   [3:0] r_ay_sel;

reg  [5:0] blk;          // which block we are on, 0..r_banks-1
reg  [1:0] blk_hdr_idx;  // 0,1 = FF FF, 2 = page number
reg [13:0] blk_off;
reg  [7:0] rd_data;

// 48K stores three pages in a fixed order; everything else is page = bank + 3.
// Both mappings mirror snap_loader.sv:545-553.
wire [7:0] cur_page = r_banks48 ? (blk == 0 ? 8'd4 : blk == 1 ? 8'd5 : 8'd8)
                                : ({2'b00, blk} + 8'd3);
wire [5:0] cur_bank = r_banks48 ? (blk == 0 ? 6'd2 : blk == 1 ? 6'd0 : 6'd5)
                                : blk;
reg  [7:0] blk_hdr_val;
always_comb begin
	case (blk_hdr_idx)
		0: blk_hdr_val = 8'hFF;      // length lo: FFFF means 16384 uncompressed
		1: blk_hdr_val = 8'hFF;      // length hi
		default: blk_hdr_val = cur_page;
	endcase
end

reg   [7:0] hdr_val;

always_comb begin
	case (hdr_idx)
		 0: hdr_val = r_cpu[7:0];              // A
		 1: hdr_val = r_cpu[15:8];             // F
		 2: hdr_val = r_cpu[87:80];            // C
		 3: hdr_val = r_cpu[95:88];            // B
		 4: hdr_val = r_cpu[119:112];          // L
		 5: hdr_val = r_cpu[127:120];          // H
		 6: hdr_val = 8'd0;                    // PC here must be 0 for v2/v3
		 7: hdr_val = 8'd0;
		 8: hdr_val = r_cpu[55:48];            // SPL
		 9: hdr_val = r_cpu[63:56];            // SPH
		10: hdr_val = r_cpu[39:32];            // I
		11: hdr_val = r_cpu[47:40];            // R
		// bit0 = R bit 7, bits 3:1 = border, bit4 SamRom = 0, bit5 compressed = 0
		12: hdr_val = {2'b00, 1'b0, 1'b0, r_border, r_cpu[47]};
		13: hdr_val = r_cpu[103:96];           // E
		14: hdr_val = r_cpu[111:104];          // D
		15: hdr_val = r_cpu[151:144];          // C'
		16: hdr_val = r_cpu[159:152];          // B'
		17: hdr_val = r_cpu[167:160];          // E'
		18: hdr_val = r_cpu[175:168];          // D'
		19: hdr_val = r_cpu[183:176];          // L'
		20: hdr_val = r_cpu[191:184];          // H'
		21: hdr_val = r_cpu[23:16];            // A'
		22: hdr_val = r_cpu[31:24];            // F'
		23: hdr_val = r_cpu[199:192];          // IYL
		24: hdr_val = r_cpu[207:200];          // IYH
		25: hdr_val = r_cpu[135:128];          // IXL
		26: hdr_val = r_cpu[143:136];          // IXH
		27: hdr_val = {7'd0, r_cpu[210]};      // IFF1
		28: hdr_val = {7'd0, r_cpu[211]};      // IFF2
		29: hdr_val = {6'd0, r_cpu[209:208]};  // IM
		30: hdr_val = 8'd55;                   // additional header length
		31: hdr_val = 8'd0;
		32: hdr_val = r_cpu[71:64];            // PCL
		33: hdr_val = r_cpu[79:72];            // PCH
		34: hdr_val = r_hw;                    // hardware mode
		35: hdr_val = r_7ffd;                  // last OUT to #7FFD
		38: hdr_val = {4'd0, r_ay_sel};        // last OUT to #FFFD (selected AY register)
		// 39-54: the 16 AY registers, packed 8 bits each in r_ay_regs
		// (reg0 at bits [7:0]) - one constant part-select per byte, since
		// Icarus does not support an indexed (variable-base) part-select
		// inside an always_comb process.
		39: hdr_val = r_ay_regs[  7:  0];      // AY reg 0
		40: hdr_val = r_ay_regs[ 15:  8];      // AY reg 1
		41: hdr_val = r_ay_regs[ 23: 16];      // AY reg 2
		42: hdr_val = r_ay_regs[ 31: 24];      // AY reg 3
		43: hdr_val = r_ay_regs[ 39: 32];      // AY reg 4
		44: hdr_val = r_ay_regs[ 47: 40];      // AY reg 5
		45: hdr_val = r_ay_regs[ 55: 48];      // AY reg 6
		46: hdr_val = r_ay_regs[ 63: 56];      // AY reg 7
		47: hdr_val = r_ay_regs[ 71: 64];      // AY reg 8
		48: hdr_val = r_ay_regs[ 79: 72];      // AY reg 9
		49: hdr_val = r_ay_regs[ 87: 80];      // AY reg 10
		50: hdr_val = r_ay_regs[ 95: 88];      // AY reg 11
		51: hdr_val = r_ay_regs[103: 96];      // AY reg 12
		52: hdr_val = r_ay_regs[111:104];      // AY reg 13
		53: hdr_val = r_ay_regs[119:112];      // AY reg 14
		54: hdr_val = r_ay_regs[127:120];      // AY reg 15
		86: hdr_val = r_1ffd;                  // last OUT to #1FFD
		default: hdr_val = 8'd0;
	endcase
end

// Combinational so the byte on the wire always matches the current state.
reg [7:0] out_byte_c;
always_comb begin
	case (state)
		ST_BLKHDR: out_byte_c = blk_hdr_val;
		ST_DATA:   out_byte_c = rd_data;
		default:   out_byte_c = hdr_val;
	endcase
end
assign out_byte = out_byte_c;

assign out_last = ((state == ST_HEADER) && (hdr_idx == 7'd86) && (r_banks == 0))
               || ((state == ST_DATA)   && (blk_off == 14'h3FFF)
                                        && ((blk + 1'd1) == r_banks));

wire beat = out_valid & out_ready;

always @(posedge clk) begin
	// reset and start are both handled AHEAD of the case, so they take effect
	// from any state - see the port comments above.
	if (reset) begin
		state     <= ST_IDLE;
		out_valid <= 0;
		active    <= 0;
		ram_rd    <= 0;
	end
	else if (start) begin
		r_cpu     <= cpu_reg;
		r_7ffd    <= port_7ffd;
		r_1ffd    <= port_1ffd;
		r_hw      <= hw_mode;
		r_border  <= border;
		r_banks   <= num_banks;
		r_banks48 <= banks48;
		r_ay_regs <= ay_regs;
		r_ay_sel  <= ay_sel;
		hdr_idx   <= 0;
		active    <= 1;
		ram_rd    <= 0;
		out_valid <= 1;      // byte 0 is on the wire from the first cycle
		state     <= ST_HEADER;
	end
	else case (state)
		ST_IDLE: begin
			out_valid <= 0;
			active    <= 0;
			ram_rd    <= 0;
			ram_addr  <= 0;
		end

		ST_HEADER: begin
			if (beat) begin
				if (hdr_idx == 7'd86) begin
					if (r_banks == 0) begin
						out_valid <= 0;
						state     <= ST_DONE;
					end
					else begin
						blk         <= 0;
						blk_hdr_idx <= 0;
						state       <= ST_BLKHDR;
					end
				end
				else hdr_idx <= hdr_idx + 1'd1;
			end
		end

		ST_BLKHDR: begin
			if (beat) begin
				if (blk_hdr_idx == 2) begin
					out_valid <= 0;
					blk_off   <= 0;
					state     <= ST_RDREQ;
				end
				else blk_hdr_idx <= blk_hdr_idx + 1'd1;
			end
		end

		ST_RDREQ: begin
			out_valid <= 0;
			if (ram_ready) begin
				// 5+6+14 = 25 bits. {4'd0,...} would be 24 and silently
				// zero-extend, which happens to work and is still wrong.
				ram_addr  <= {5'd0, cur_bank, blk_off};
				ram_rd    <= 1;
				state     <= ST_RDWAIT;
			end
		end

		// One mandatory settling cycle after asserting ram_rd, before
		// ram_ready is sampled at all. rtl/sdram.sv:200-207 decides
		// hit-vs-miss and updates `ready`/`save_addr` with a NONBLOCKING
		// assignment triggered off the rising edge of `rd` - so in the
		// cycle immediately following that edge, ram_ready still shows
		// whatever it was BEFORE sdram.sv reacted (typically still high,
		// left over from the previous transfer). Sampling it in that
		// cycle would misread a genuine miss as a same-word hit and
		// capture garbage. Just let the edge land here; this is also
		// where the one-cycle ram_rd pulse gets deasserted again.
		ST_RDWAIT: begin
			ram_rd <= 0;
			state  <= ST_RDPOLL;
		end

		// By now ram_ready reflects sdram.sv's actual reaction to the
		// read we issued:
		//  - Same-word hit (rtl/sdram.sv:204-206, addr[24:1] matches the
		//    previous read): sdram.sv never drops `ready` at all, and the
		//    requested byte is already selected into `dout` via the
		//    save_addr[0] mux - both true from THIS cycle - so ram_ready
		//    reads high immediately and we can move straight on.
		//  - Genuine miss: sdram.sv dropped `ready` on the settling
		//    cycle above and it stays low for the CAS-latency access;
		//    wait here until it comes back up.
		// Either way, once ram_ready is high the data is valid, so both
		// paths converge on the same next state.
		ST_RDPOLL: begin
			if (ram_ready) begin
				// Don't capture yet - go round through ST_RDCAP instead.
				// rtl/sdram.sv registers its output byte (`data`, muxed
				// combinationally into `dout`) on the very same edge that
				// raises `ready`, so latching ram_dout into rd_data here
				// would put a register -> mux -> register path in one
				// clk_sys period, which does not close timing once place
				// and route has room to spread the two flops apart.
				// sdram.sv holds `data`/`dout` stable - and we do not
				// touch ram_rd again - until the next read is issued, and
				// this FSM will not issue one for several cycles, so the
				// extra idle cycle here costs nothing but gives the mux
				// output a full cycle to settle before ST_RDCAP registers
				// it. ZX-Spectrum.sdc has a matching multicycle (setup 2,
				// hold 1) for this now genuinely two-cycle path.
				state <= ST_RDCAP;
			end
		end

		ST_RDCAP: begin
			rd_data   <= ram_dout;
			out_valid <= 1;
			state     <= ST_DATA;
		end

		ST_DATA: begin
			if (beat) begin
				out_valid <= 0;
				if (blk_off == 14'h3FFF) begin
					if (blk + 1'd1 == r_banks) begin
						state <= ST_DONE;
					end
					else begin
						blk         <= blk + 1'd1;
						blk_hdr_idx <= 0;
						out_valid   <= 1;  // re-assert: the unconditional
						                   // out_valid<=0 above would otherwise
						                   // leave ST_BLKHDR waiting on a beat
						                   // that never comes (permanent hang).
						state       <= ST_BLKHDR;
					end
				end
				else begin
					blk_off <= blk_off + 1'd1;
					state   <= ST_RDREQ;
				end
			end
		end

		ST_DONE: begin
			out_valid <= 0;
			active    <= 0;
			state     <= ST_IDLE;
		end

		default: state <= ST_IDLE;
	endcase
end

endmodule
