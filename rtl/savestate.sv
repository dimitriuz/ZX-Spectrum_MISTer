//============================================================================
//  MiSTer-native savestate for the ZX Spectrum core.
//
//  Save: pause the CPU at an instruction boundary, build an uncompressed .z80
//  v3 image with ss_writer, and stream it into a DDR slot. Main_MiSTer polls
//  the slot's counter word once a second and writes the .ss file
//  (user_io.cpp:2005-2028).
//
//  Slot layout, dictated by process_ss():
//      +0  uint32  counter   - the core bumps this to request a save
//      +4  uint32  payload size in dwords
//      +8  payload
//
//  The counter is written LAST. The HPS reads size and payload only after it
//  sees the counter change, so any other order lets it read a torn state.
//
//  Load: stream the payload back into rtl/snap_loader.sv on its ioctl inputs.
//============================================================================

module savestate
#(
	// Watchdog budget in clk_sys cycles - see the comment at wdog_run below.
	// Overridable only so tb_savestate_ddr.sv can shrink it to exercise the
	// timeout without simulating ~2^27 real cycles; hardware always gets the
	// default.
	parameter [26:0] WDOG_LIMIT = 27'h7FFFFFF  // 2^27-1 clk_sys cycles
)
(
	input             clk,
	input             reset,

	input             ss_save_req,
	input             ss_load_req,
	input       [1:0] ss_slot,
	// Right Shift + F3 cycles the slot. The hotkey writes the new value back
	// through hps_io's status_set/status_in (ZX-Spectrum.sv), so ss_slot above
	// only catches up after that HPS round trip - the new slot is therefore
	// passed in alongside the pulse rather than read back off ss_slot. The
	// message is emitted here, not at the top level, so info_req/info keeps
	// exactly one driver.
	input             ss_slot_chg,
	input       [1:0] ss_slot_new,
	input             ss_supported,
	output reg        ss_busy = 0,
	input             cpu_ack,      // CPU has released the bus (nBUSACK)

	input     [211:0] cpu_reg,
	input       [7:0] port_7ffd,
	input       [7:0] port_1ffd,
	input       [2:0] border,
	input       [7:0] hw_mode,
	input       [5:0] num_banks,
	input             banks48,

	// AY register file shadow, maintained in ZX-Spectrum.sv by snooping
	// turbosound's write port. Passed straight through to ss_writer for the
	// save side; see ay_replay_* below for the load side.
	input     [127:0] ay_shadow,
	input       [3:0] ay_sel,

	output     [24:0] ram_addr,
	output            ram_rd,
	input       [7:0] ram_dout,
	input             ram_ready,

	// Power-on values throughout, for the same reason rtl/ddr_cdc.sv and
	// rtl/ddram_arb.sv initialise theirs: Cyclone V powers registers to 0 so
	// hardware does not depend on it, but in simulation an X here propagates.
	// ss_busy above is the load-bearing one - it selects the ss_rd arm of
	// ZX-Spectrum.sv's ram_addr casex, and casex treats an X in the case
	// EXPRESSION as a wildcard, so an uninitialised ss_busy matches that arm
	// and hands the SDRAM savestate's address at time 0.
	output reg [27:0] ddr_addr = 0,
	output reg  [7:0] ddr_din = 0,
	input       [7:0] ddr_dout,
	output reg        ddr_we = 0,
	output reg        ddr_rd = 0,
	input             ddr_ready,

	output reg        ld_download = 0,
	output reg [24:0] ld_addr = 0,
	output reg  [7:0] ld_data = 0,
	output reg        ld_wr = 0,
	input             ld_wait,

	// Turbosound's actual reset (reset | psg_reset in ZX-Spectrum.sv): the
	// AY replay below must not fire until this releases, or it writes into
	// a chip that is about to be cleared - see the ST_L_AY_WAIT comment.
	input             aud_reset,

	// Drives ZX-Spectrum.sv's psg_we/BC/DI mux while a load's AY replay is
	// in progress; ay_replay_active is low the rest of the time, so the mux
	// is inert and the CPU's own signals pass straight through.
	output            ay_replay_active,
	output            ay_replay_bdir,
	output            ay_replay_bc,
	output      [7:0] ay_replay_data,

	output reg        info_req = 0,
	output reg  [7:0] info = 0
);

// The savestate region's offset inside ddram.sv's window, written as the
// subtraction it actually is rather than as a hand-reduced constant: a
// mistyped digit here fails SILENTLY - the HPS simply never sees the data and
// no .ss file ever appears - and the hand-reduced form is easy to get wrong
// (28'h0E00000, seven digits, is a different address 16x lower). Spelling it
// as physical-address minus window-base means both numbers can be checked by
// eye against CONF_STR's "SS3E000000" and against ddram.sv, with no reduction
// step to get wrong. 32-bit literals also keep Icarus from warning about
// extra digits in a 28-bit sized constant, so a REAL width warning elsewhere
// is not lost in the noise. Value: 0x0E000000.
localparam [27:0] SS_BASE  = 32'h3E000000 - 32'h30000000;
// One source of truth for the slot stride: SLOT_SHIFT is what the slot_base
// arithmetic below actually uses, and SLOT_SZ is derived from it rather than
// written out separately - a 512 KB stride and a 0x80000 size that disagreed
// would be a silent, data-destroying mismatch. Must match CONF_STR's
// "SS3E000000:80000" in ZX-Spectrum.sv.
localparam integer SLOT_SHIFT = 19;
localparam [27:0] SLOT_SZ  = 28'd1 << SLOT_SHIFT;   // 512 KB per slot

// Order must match the strings in CONF_STR's "I," section (ZX-Spectrum.sv):
// the HPS shows the info-th string from that list (user_io.cpp:2640-2658).
localparam INFO_SAVED     = 8'd1;
localparam INFO_LOADED    = 8'd2;
localparam INFO_EMPTY     = 8'd3;
localparam INFO_UNSUP     = 8'd4;
localparam INFO_NOTARMED  = 8'd5;
localparam INFO_TIMEOUT   = 8'd6;
localparam INFO_SLOT1     = 8'd7;   // 7..10 = "Slot 1/2/3/4 selected"

localparam ST_IDLE     = 4'd0;
localparam ST_S_BUS    = 4'd1;
localparam ST_S_START  = 4'd2;
localparam ST_S_BYTE   = 4'd3;
localparam ST_S_PAD    = 4'd4;
localparam ST_S_SIZE   = 4'd5;
localparam ST_S_CNT    = 4'd6;
localparam ST_S_END    = 4'd7;
localparam ST_INFO     = 4'd8;
localparam ST_L_SIZE   = 4'd9;
localparam ST_L_RDREQ  = 4'd10;
localparam ST_L_RDW    = 4'd11;
localparam ST_L_WR     = 4'd12;
localparam ST_L_END    = 4'd13;
localparam ST_S_ARM    = 4'd14;
localparam ST_S_ARMCHK = 4'd15;
// AY replay states: state was widened from [3:0] (16 codes, exactly full at
// ST_IDLE..ST_S_ARMCHK above) to [4:0] to make room for these. They run
// after ST_L_END, off the tail of a load, replaying the captured AY
// register file into turbosound; see ST_L_AY_WAIT/HI/LO further down.
localparam ST_L_AY_WAIT = 5'd16;
localparam ST_L_AY_HI   = 5'd17;
localparam ST_L_AY_LO   = 5'd18;
// Load-side arming check, the mirror of ST_S_ARM/ST_S_ARMCHK. 21 of the 32
// codes in state[4:0] are now used.
localparam ST_L_ARM     = 5'd19;
localparam ST_L_ARMCHK  = 5'd20;

reg  [4:0] state = ST_IDLE;
reg  [4:0] ret_state;

// Watchdog: ss_busy and ld_download both feed nBUSRQ in ZX-Spectrum.sv, so a
// stall in either direction holds the CPU off the bus - and unlike every
// other terminal path in this FSM, a stall never reaches ST_S_END/ST_L_END
// on its own. WDOG_LIMIT (above) is budgeted well above a legitimate save: the
// largest snapshot here is 8 banks plus header, about 131 KB, and the default
// gives roughly 2^27 clk_sys cycles (~1.2s at 112MHz). Counts only while ss_busy|ld_download is
// asserted, so it reads zero going into every new save/load - no separate
// "on entry" reset needed.
//
// (state != ST_IDLE) is in there because ss_busy and ld_download are BOTH low
// in ST_S_ARM, ST_L_ARM, ST_L_SIZE and the ST_L_RDW passes those use: if the
// arbiter's strict A priority kept ddr_cdc in M_RUN, savestate wedged there
// with no timeout and no message at all. state is ST_IDLE whenever the module
// is idle, so this still reads zero going into every new save/load.
reg  [26:0] wdog_cnt = 0;
wire        wdog_run  = ss_busy | ld_download | (state != ST_IDLE);
wire        wdog_fire = wdog_run & (wdog_cnt == WDOG_LIMIT);

reg [27:0] slot_base;
reg [27:0] wr_ptr;          // next payload byte address
reg [31:0] byte_cnt;        // payload bytes emitted
reg [31:0] counter = 0;
reg  [1:0] word_idx;        // which byte of a 32-bit word we are writing
reg [31:0] word_val;

// Sticky: the HPS has armed this core at least once. Deliberately GLOBAL, not
// per-slot, and deliberately outside the `if (reset)` block below - both
// properties are load-bearing and neither is an oversight:
//
//  - Outside reset, because a save leaves word0 holding `counter`, not the
//    0xFFFFFFFF arm marker (the marker is consumed by the first save to that
//    slot). If a reset cleared this, the next load would re-read word0, find
//    the counter, and refuse a slot that holds a perfectly good save. That is
//    also why adding arch_reset to ss_mod_reset (ZX-Spectrum.sv) is safe: it
//    resets the FSM without forgetting that arming happened.
//
//  - Global, because a per-slot version would buy nothing. Main_MiSTer arms
//    ALL FOUR slots in one pass - it mmaps each, ZEROES it, preloads any
//    existing .ss file, then stamps word0 = 0xFFFFFFFF (user_io.cpp:1948-1988)
//    - so tracking arming per slot could only ever re-confirm what the first
//    slot already proved. What actually protects a never-written slot is that
//    same zeroing: its word1 is 0, which ST_L_RDREQ rejects as INFO_EMPTY
//    before anything is streamed. The LD_MAX half of that check covers the
//    residual case where a slot holds stale non-zero DDR content instead of a
//    real size; worst case there is a plausible-looking garbage size streaming
//    junk into RAM banks, which a reset clears.
reg        armed_seen = 0;
reg [31:0] word_acc;

reg [31:0] ld_total;        // payload dwords, then bytes, to replay
// Largest payload that can physically be in a slot, in dwords. word1 is read
// straight out of DDR, and in an UNARMED slot it is whatever the DDR happens
// to hold - quite plausibly huge. Streaming that onto snap_loader's ioctl port
// makes it write 16 KB into a RAM bank for every stray page byte that lands in
// 3..18 - megabytes of garbage across the banks - so an implausible size is
// rejected up front as an empty slot.
localparam [31:0] LD_MAX = (SLOT_SZ - 28'd8) >> 2;
reg [31:0] ld_done;
reg [27:0] rd_ptr;
reg  [4:0] rd_ret;          // where ST_L_RDW returns to (5 bits: ST_L_ARM = 19)
reg        ddr_issued;      // DDR has acknowledged by dropping ddr_ready

// AY replay (load side). Captured while streaming bytes 38-54 past in
// ST_L_WR - snap_loader.sv is never touched, savestate just watches its own
// outgoing stream - then replayed into turbosound after the load's reset
// releases. Packing matches ss_writer.sv's ay_regs: reg0 at bits [7:0].
reg [127:0] ay_regs_cap;
reg   [3:0] ay_sel_cap;
reg   [5:0] ay_op;    // 0..31 = reg (ay_op[4:1]) select/data (ay_op[0]) pairs, 32 = final re-select
reg   [5:0] ay_hold;  // hold counter within the HI/LO half of the current op

// Minimum hold, in clk_sys cycles, for each half of a replayed AY write.
//
// The requirement is a CLOCK-DOMAIN one, not a ce_ym one. turbosound registers
// BDIR/BC/DI through a two-flop chain and edge-detects BDIR on raw CLK
// (= clk_aud) - rtl/turbosound.sv:48-105 - rtl/jt12/jt12_mmr.v:180 is
// explicitly annotated "this runs at clk speed, no clock gating here", and
// rtl/ym2149.sv:76-88 writes its register file on raw CLK too. CE/ce_ym gates
// sound GENERATION only. So each half must be held for about 3 clk_aud cycles
// (synchroniser plus edge detect) = about 6 clk_sys cycles, clk_aud being half
// clk_sys. 40 is kept as harmless margin.
//
// Worth knowing which way that cuts: because the requirement is on clk_aud and
// not on ce_ym, a load taken while the machine is PAUSED - F9 sets `pause`,
// which zeroes ce_ym in ZX-Spectrum.sv - still restores the AY correctly.
localparam [5:0] AY_HOLD = 6'd40;

wire        ay_final   = (ay_op == 6'd32);
wire  [3:0] ay_reg_idx = ay_op[4:1];
wire        ay_is_data = ay_op[0];
wire  [7:0] ay_op_val  = ay_final   ? {4'd0, ay_sel_cap} :
                          ay_is_data ? ay_regs_cap[8*ay_reg_idx +: 8] :
                                       {4'd0, ay_reg_idx};
// SEL (register-select) and the final re-select both assert BC=1 (#FFFD);
// the DATA half asserts BC=0 (#BFFD).
wire        ay_op_bc   = ay_final ? 1'b1 : ~ay_is_data;

assign ay_replay_active = (state == ST_L_AY_HI) | (state == ST_L_AY_LO);
assign ay_replay_bdir   = (state == ST_L_AY_HI);
assign ay_replay_bc     = ay_op_bc;
assign ay_replay_data   = ay_op_val;

// ss_writer byte stream
reg        w_start;
wire       w_active;
wire [7:0] w_byte;
wire       w_valid;
reg        w_ready;
wire       w_last;
reg        saw_last;

// The writer's reset takes BOTH abort paths: the module's own reset (OSD
// Reset, F10, ctrl+F11, buttons[1], mmc_reset, and now arch_reset - see
// ss_mod_reset in ZX-Spectrum.sv) and the watchdog. Neither used to reach it,
// so an abandoned save left the writer mid-stream with out_valid high and the
// NEXT save streamed the tail of the abandoned snapshot into the slot.
ss_writer writer
(
	.clk(clk),
	.reset(reset | wdog_fire),
	.start(w_start),
	.active(w_active),
	.cpu_reg(cpu_reg),
	.port_7ffd(port_7ffd),
	.port_1ffd(port_1ffd),
	.border(border),
	.hw_mode(hw_mode),
	.num_banks(num_banks),
	.banks48(banks48),
	.ay_regs(ay_shadow),
	.ay_sel(ay_sel),
	.ram_addr(ram_addr),
	.ram_rd(ram_rd),
	.ram_dout(ram_dout),
	.ram_ready(ram_ready),
	.out_byte(w_byte),
	.out_valid(w_valid),
	.out_ready(w_ready),
	.out_last(w_last)
);

always @(posedge clk) begin
	info_req <= 0;
	w_start  <= 0;
	ddr_we   <= 0;
	ddr_rd   <= 0;
	w_ready  <= 0;
	ld_wr    <= 0;

	if (reset) begin
		state       <= ST_IDLE;
		ss_busy     <= 0;
		ld_download <= 0;
		ld_wr       <= 0;
		wdog_cnt    <= 0;
	end
	else if (wdog_fire) begin
		// Timed out: abort rather than wedge the machine forever. Reported
		// the same way every other terminal state reports - via ST_INFO -
		// so the HPS sees info_req pulse exactly once, same as a real save.
		ss_busy     <= 0;
		ld_download <= 0;
		info        <= INFO_TIMEOUT;
		ret_state   <= ST_IDLE;
		state       <= ST_INFO;
		wdog_cnt    <= 0;
	end
	else begin
		wdog_cnt <= wdog_run ? (wdog_cnt + 27'd1) : 27'd0;
		case (state)
		// w_active is the interlock that keeps a save from starting on top of
		// a writer that is still streaming. With the writer's reset above it
		// can only be high while a save is actually in flight, and a user
		// reset clears it, so this cannot latch savestate off permanently.
		ST_IDLE: begin
			ss_busy <= 0;
			if (ss_save_req && !w_active) begin
				if (!ss_supported) begin
					info      <= INFO_UNSUP;
					ret_state <= ST_IDLE;
					state     <= ST_INFO;
				end
				else begin
					slot_base <= SS_BASE + ({26'd0, ss_slot} << SLOT_SHIFT);
					word_idx  <= 0;
					word_acc  <= 0;
					state     <= ST_S_ARM;
				end
			end
			else if (ss_load_req) begin
				// Via ST_L_ARM, not straight to ST_L_SIZE: an unarmed slot's
				// word1 is raw DDR content - see LD_MAX above.
				slot_base <= SS_BASE + ({26'd0, ss_slot} << SLOT_SHIFT);
				word_idx  <= 0;
				word_acc  <= 0;
				ld_total  <= 0;
				ld_done   <= 0;
				state     <= ST_L_ARM;
			end
			else if (ss_slot_chg) begin
				info      <= INFO_SLOT1 + {6'd0, ss_slot_new};
				ret_state <= ST_IDLE;
				state     <= ST_INFO;
			end
		end

		// Check arming before taking the bus - no need to halt the CPU to
		// discover we have nowhere to write.
		ST_S_ARM: begin
			if (armed_seen) begin
				ss_busy <= 1;
				state   <= ST_S_BUS;
			end
			else if (ddr_ready && !ddr_rd) begin
				ddr_addr   <= slot_base + {26'd0, word_idx};
				ddr_rd     <= 1;
				ddr_issued <= 0;
				rd_ret     <= ST_S_ARM;
				state      <= ST_L_RDW;
			end
		end

		ST_S_ARMCHK: begin
			// Main_MiSTer stamps word0 = 0xFFFFFFFF when it arms a slot
			// (user_io.cpp:1988). Anything else means no arming has happened.
			if (word_acc == 32'hFFFFFFFF) begin
				armed_seen <= 1;
				ss_busy    <= 1;
				state      <= ST_S_BUS;
			end
			else begin
				info      <= INFO_NOTARMED;
				ret_state <= ST_IDLE;
				state     <= ST_INFO;
			end
		end

		// Load-side arming check. Same shape as ST_S_ARM above, and the same
		// armed_seen SHORTCUT - not a gate: armed_seen is only ever set once a
		// real 0xFFFFFFFF has been seen (by either direction), so with it
		// clear the word0 read below still happens. That is what keeps the
		// normal workflow working - the HPS preloads a slot at core start and
		// the very first thing the user does is load it, with no save ever
		// having run - while an unarmed slot, whose word0 is raw DDR, is
		// refused instead of streaming garbage onto snap_loader.
		ST_L_ARM: begin
			if (armed_seen) begin
				word_idx <= 0;
				state    <= ST_L_SIZE;
			end
			else if (ddr_ready && !ddr_rd) begin
				ddr_addr   <= slot_base + {26'd0, word_idx};
				ddr_rd     <= 1;
				ddr_issued <= 0;
				rd_ret     <= ST_L_ARM;
				state      <= ST_L_RDW;
			end
		end

		ST_L_ARMCHK: begin
			if (word_acc == 32'hFFFFFFFF) begin
				armed_seen <= 1;
				word_idx   <= 0;
				state      <= ST_L_SIZE;
			end
			else begin
				info      <= INFO_NOTARMED;
				ret_state <= ST_IDLE;
				state     <= ST_INFO;
			end
		end

		// Wait for the CPU to release the bus. cpu_reg is only coherent at an
		// instruction boundary; sampling early gives a torn snapshot.
		ST_S_BUS: if (cpu_ack) state <= ST_S_START;

		ST_S_START: begin
			wr_ptr   <= slot_base + 28'd8;
			byte_cnt <= 0;
			saw_last <= 0;
			w_start  <= 1;
			state    <= ST_S_BYTE;
		end

		// ddr_ready alone is not enough to gate a new request: ddr_stub (and,
		// per the arbiter's own comments, ddram_arb) only marks itself busy
		// the cycle AFTER a write's "we" is sampled, so ready is still high
		// during the very cycle we first pulse ddr_we. Checking ddr_ready
		// without also requiring our own ddr_we to have already dropped
		// re-fires on that overlap cycle with the byte the writer has not
		// yet advanced past, both duplicating the address (the duplicate is
		// then silently swallowed by ddr_stub once busy does land, dropping
		// a real byte at the address after it) and handing ss_writer a
		// spurious second ack that skips it clean over the next byte. This
		// is the same class of hazard ss_writer's own ST_RDWAIT documents
		// for ram_ready ("wait to SEE it fall before trusting it rise") -
		// !ddr_we enforces the same one-cycle-late confirmation here.
		ST_S_BYTE: begin
			if (w_valid && ddr_ready && !ddr_we) begin
				ddr_addr <= wr_ptr;
				ddr_din  <= w_byte;
				ddr_we   <= 1;
				w_ready  <= 1;               // one-cycle handshake with the writer
				wr_ptr   <= wr_ptr + 28'd1;
				byte_cnt <= byte_cnt + 32'd1;
				if (w_last) saw_last <= 1;
			end
			else if (saw_last && !w_valid) begin
				state <= ST_S_PAD;
			end
		end

		// Pad to a dword boundary: the HPS writes (word1 + 2) * 4 bytes.
		ST_S_PAD: begin
			if (byte_cnt[1:0] != 2'b00) begin
				if (ddr_ready && !ddr_we) begin
					ddr_addr <= wr_ptr;
					ddr_din  <= 8'h00;
					ddr_we   <= 1;
					wr_ptr   <= wr_ptr + 28'd1;
					byte_cnt <= byte_cnt + 32'd1;
				end
			end
			else begin
				word_val <= byte_cnt >> 2;
				word_idx <= 0;
				state    <= ST_S_SIZE;
			end
		end

		ST_S_SIZE: begin
			if (ddr_ready && !ddr_we) begin
				ddr_addr <= slot_base + 28'd4 + {26'd0, word_idx};
				ddr_din  <= word_val[7:0];
				ddr_we   <= 1;
				word_val <= word_val >> 8;
				if (word_idx == 2'd3) begin
					word_val <= counter + 32'd1;
					word_idx <= 0;
					state    <= ST_S_CNT;
				end
				else word_idx <= word_idx + 2'd1;
			end
		end

		// Counter last: this is what the HPS polls.
		ST_S_CNT: begin
			if (ddr_ready && !ddr_we) begin
				ddr_addr <= slot_base + {26'd0, word_idx};
				ddr_din  <= word_val[7:0];
				ddr_we   <= 1;
				word_val <= word_val >> 8;
				if (word_idx == 2'd3) begin
					counter <= counter + 32'd1;
					state   <= ST_S_END;
				end
				else word_idx <= word_idx + 2'd1;
			end
		end

		ST_S_END: begin
			ss_busy   <= 0;
			info      <= INFO_SAVED;
			ret_state <= ST_IDLE;
			state     <= ST_INFO;
		end

		ST_INFO: begin
			info_req <= 1;
			state    <= ret_state;
		end

		// Read word1 a byte at a time; a zero size means the slot is empty.
		ST_L_SIZE: begin
			if (ddr_ready && !ddr_rd) begin
				ddr_addr   <= slot_base + 28'd4 + {26'd0, word_idx};
				ddr_rd     <= 1;
				ddr_issued <= 0;
				rd_ret     <= ST_L_SIZE;
				state      <= ST_L_RDW;
			end
		end

		// Same handshake discipline as ss_writer: see ddr_ready fall before
		// trusting it rise, or a fast controller hands back stale data.
		ST_L_RDW: begin
			if (!ddr_issued) begin
				if (!ddr_ready) ddr_issued <= 1;
			end
			else if (ddr_ready) begin
				if (rd_ret == ST_L_SIZE) begin
					ld_total <= ld_total | ({24'd0, ddr_dout} << (8 * word_idx));
					if (word_idx == 2'd3) begin
						word_idx <= 0;
						state    <= ST_L_RDREQ;
					end
					else begin
						word_idx <= word_idx + 2'd1;
						state    <= ST_L_SIZE;
					end
				end
				else if (rd_ret == ST_S_ARM || rd_ret == ST_L_ARM) begin
					word_acc <= word_acc | ({24'd0, ddr_dout} << (8 * word_idx));
					if (word_idx == 2'd3) begin
						word_idx <= 0;
						state    <= (rd_ret == ST_S_ARM) ? ST_S_ARMCHK : ST_L_ARMCHK;
					end
					else begin
						word_idx <= word_idx + 2'd1;
						state    <= rd_ret;
					end
				end
				else begin
					ld_data <= ddr_dout;
					state   <= ST_L_WR;
				end
			end
		end

		ST_L_RDREQ: begin
			// First pass, i.e. before ld_download rises: ld_total is still in
			// dwords, and this is the only place it can be size-checked in
			// those units. Zero means an empty slot; anything larger than a
			// slot can hold means word1 is not a real size at all (see LD_MAX)
			// - report both as "Slot is empty" rather than streaming it.
			if (!ld_download && ld_done == 0) begin
				if (ld_total == 0 || ld_total > LD_MAX) begin
					info      <= INFO_EMPTY;
					ret_state <= ST_IDLE;
					state     <= ST_INFO;
				end
				else begin
					ld_total    <= ld_total << 2;     // dwords -> bytes
					ld_addr     <= 0;
					ld_download <= 1;
					rd_ptr      <= slot_base + 28'd8;
				end
			end
			else if (ld_done == ld_total) begin
				state <= ST_L_END;
			end
			else if (!ld_wait && ddr_ready) begin
				// ld_addr must equal the index of the byte THIS read will
				// fetch, i.e. ld_done (the count of bytes already written).
				// Advancing it here - rather than alongside ld_wr in ST_L_WR
				// - matters: ld_wr and an ld_addr bump made in the same cycle
				// become visible together, so an observer sampling on ld_wr
				// would see the address already one ahead of the byte being
				// written. Bumping it a state earlier, while ld_wr is still
				// low, keeps ld_addr steady and correct for the whole pulse.
				ld_addr    <= ld_done[24:0];
				ddr_addr   <= rd_ptr;
				ddr_rd     <= 1;
				ddr_issued <= 0;
				rd_ret     <= ST_L_RDREQ;
				state      <= ST_L_RDW;
			end
		end

		ST_L_WR: begin
			if (!ld_wait) begin
				ld_wr   <= 1;
				rd_ptr  <= rd_ptr + 28'd1;
				ld_done <= ld_done + 32'd1;
				state   <= ST_L_RDREQ;

				// Snoop the AY fields as they stream past - ld_addr is the
				// byte offset THIS write targets (see the ld_addr comment
				// in ST_L_RDREQ). Byte 38 = last-selected AY register,
				// bytes 39-54 = the 16 AY registers; rtl/ss_writer.sv
				// emits the mirror of this on the save side. This is the
				// only place any of this module reads its own outgoing
				// load stream - snap_loader.sv itself is never touched.
				if (ld_addr == 25'd38)
					ay_sel_cap <= ld_data[3:0];
				else if (ld_addr >= 25'd39 && ld_addr <= 25'd54)
					ay_regs_cap[(ld_addr - 25'd39) * 4'd8 +: 8] <= ld_data;
			end
		end

		// The load itself is done, but turbosound is still held in reset:
		// aud_reset (= reset | psg_reset in ZX-Spectrum.sv) tracks
		// snap_reset, which stays asserted for the whole load and only
		// drops a cycle or two after ld_download falls here (see
		// rtl/snap_loader.sv:284-306, and longer still for a cross-machine
		// load that has to wait on hw_ack). Keep ss_busy asserted (holding
		// the CPU off the bus, and keeping the watchdog armed in case that
		// wait never resolves) until the replay below has actually run.
		ST_L_END: begin
			ld_download <= 0;
			ss_busy     <= 1;
			ay_op       <= 0;
			ay_hold     <= 0;
			state       <= ST_L_AY_WAIT;
		end

		// Wait for turbosound's own reset to release before writing into
		// it - see the ST_L_END comment above.
		ST_L_AY_WAIT: begin
			if (~aud_reset) begin
				ay_op   <= 0;
				ay_hold <= 0;
				state   <= ST_L_AY_HI;
			end
		end

		// Drive BDIR high with the current op's BC/data (ay_replay_* above)
		// for AY_HOLD clk_sys cycles - long enough for turbosound to
		// actually sample it (see AY_HOLD's comment).
		ST_L_AY_HI: begin
			if (ay_hold == AY_HOLD - 1'd1) begin
				ay_hold <= 0;
				state   <= ST_L_AY_LO;
			end
			else ay_hold <= ay_hold + 1'd1;
		end

		// Drop BDIR low for AY_HOLD cycles before the next op. turbosound's
		// BDIR latch (rtl/turbosound.sv) is edge-triggered on BDIR rising,
		// not level-sensitive - holding BDIR asserted continuously across
		// two different register operations would only ever latch the
		// first one, so this gap (mirroring the idle time a real Z80
		// leaves between two OUT instructions) is required, not cosmetic.
		// Register r's select-then-data pair is ay_op 2r and 2r+1; ay_op
		// 32 is the final re-select of the originally-selected register
		// (ay_sel_cap), done last per the design so a music player reading
		// the selection back afterwards sees the right value.
		ST_L_AY_LO: begin
			if (ay_hold == AY_HOLD - 1'd1) begin
				ay_hold <= 0;
				if (ay_final) begin
					ss_busy   <= 0;
					info      <= INFO_LOADED;
					ret_state <= ST_IDLE;
					state     <= ST_INFO;
				end
				else begin
					ay_op <= ay_op + 6'd1;
					state <= ST_L_AY_HI;
				end
			end
			else ay_hold <= ay_hold + 1'd1;
		end

		default: state <= ST_IDLE;
	endcase
	end
end

endmodule
