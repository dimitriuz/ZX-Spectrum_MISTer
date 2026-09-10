`timescale 1ns/1ps

// Faithful-enough DDR-side model for rtl/ddram.sv: 64-bit words, byte enables,
// read data returned after a short latency. DDRAM_BUSY is driven by the
// testbench (see busy_mode below) rather than by this model, so that the two
// chains instantiated here see the same DDR-side stall pattern.
//
// This replaces an earlier level-sensitive ddram_stub. That stub could never
// have caught the handover hazard below: rtl/ddram.sv is edge-triggered on
// we/rd via a single shared old_we/old_rd pair, and a stub that accepts
// a request whenever "not busy" cannot exercise that edge detector at all.
// Testing against the real ddram.sv is what makes this suite trustworthy.
//
// The read response is PRESENTED and HELD until a cycle on which DDRAM_BUSY
// reads low, rather than pulsed for one cycle regardless. rtl/ddram.sv wraps
// its entire body - the `if(state) if(DDRAM_DOUT_READY)` completion arm
// included - in `if(!DDRAM_BUSY)`, so a one-cycle DDRAM_DOUT_READY that happens
// to land on a busy cycle would be lost outright and ddram.sv would sit in
// state = 1 with busy = 1 forever. That is a model artifact, not a core bug:
// this testbench's DDRAM_BUSY is unrelated to the model's own response timing,
// whereas the real f2h bridge ddram.sv is written against holds read data until
// the master takes it. (Same reasoning, same fix, as tb/tb_savestate_e2e.sv.)
module ddr_side
(
	input             clk,
	input             DDRAM_BUSY,
	input       [7:0] DDRAM_BURSTCNT,
	input      [28:0] DDRAM_ADDR,
	output reg [63:0] DDRAM_DOUT,
	output            DDRAM_DOUT_READY,
	input             DDRAM_RD,
	input      [63:0] DDRAM_DIN,
	input       [7:0] DDRAM_BE,
	input             DDRAM_WE
);
	reg [63:0] m [0:4095];
	integer i;
	initial begin
		for (i = 0; i < 4096; i = i + 1) m[i] = 64'h0;
		DDRAM_DOUT = 0;
	end
	reg [1:0] lat = 0;
	reg [11:0] radr;
	reg dout_pend = 0;
	assign DDRAM_DOUT_READY = dout_pend & ~DDRAM_BUSY;
	always @(posedge clk) begin
		if (DDRAM_WE) begin
			for (i = 0; i < 8; i = i + 1)
				if (DDRAM_BE[i]) m[DDRAM_ADDR[11:0]][i*8 +: 8] <= DDRAM_DIN[i*8 +: 8];
		end
		if (DDRAM_RD) begin radr <= DDRAM_ADDR[11:0]; lat <= 2; end
		else if (lat) begin
			lat <= lat - 1'd1;
			if (lat == 1) begin DDRAM_DOUT <= m[radr]; dout_pend <= 1; end
		end
		if (DDRAM_DOUT_READY) dout_pend <= 0;
	end

	// Index by a[14:3] so peek/poke match the DDRAM_ADDR[11:0] the write path
	// uses (the model discards addr[27:15]).
	function [7:0] peek(input [27:0] a);
		peek = m[a[14:3]][{a[2:0], 3'b000} +: 8];
	endfunction
	task poke(input [27:0] a, input [7:0] d);
		m[a[14:3]][{a[2:0], 3'b000} +: 8] = d;
	endtask
endmodule

module tb_ddram_arb;
	reg clk = 0;
	always #5 clk = ~clk;
	reg reset = 1;

	// --- DDRAM_BUSY generation ------------------------------------------
	// 0 = tied low, as this testbench originally had it. Tests 1-6 and the
	//     port-A baseline comparison (test 7) run in this mode: the baseline
	//     has to be deterministic, and both chains have to see the same DDR
	//     stalls on the same cycles for a cycle-count comparison to mean
	//     anything.
	// 1 = free-running 7-bit Fibonacci LFSR (taps 6/5, period 127, fixed
	//     seed). rtl/ddram.sv gates its ENTIRE request-sampling block on
	//     `if(!DDRAM_BUSY)`, so a tied-low DDRAM_BUSY cannot exercise any of
	//     hazard 4 at all. The period shares no factor with this file's
	//     request cadences, so it drifts through every phase over a run.
	// 2 = driven cycle-by-cycle from busy_man, for the directed sweeps that
	//     have to place a stall on one exact cycle of one exact transaction.
	integer busy_mode = 0;
	reg     busy_man  = 0;
	reg [6:0] busy_lfsr = 7'h55;
	wire      busy_fb = busy_lfsr[6] ^ busy_lfsr[5];
	always @(posedge clk) busy_lfsr <= {busy_lfsr[5:0], busy_fb};
	wire DDRAM_BUSY = (busy_mode == 0) ? 1'b0 :
	                  (busy_mode == 1) ? busy_lfsr[0] : busy_man;

	reg  [27:0] a_addr = 0, b_addr = 0;
	reg   [7:0] a_din  = 0, b_din  = 0;
	reg         a_we = 0, a_rd = 0, b_we = 0, b_rd = 0;
	wire  [7:0] a_dout, b_dout;
	wire        a_ready, b_ready;

	wire [27:0] m_addr;
	wire  [7:0] m_din, m_dout;
	wire        m_we, m_rd, m_ready;

	ddram_arb dut
	(
		.clk(clk), .DDRAM_BUSY(DDRAM_BUSY),
		.a_addr(a_addr), .a_din(a_din), .a_dout(a_dout),
		.a_we(a_we), .a_rd(a_rd), .a_ready(a_ready),
		.b_addr(b_addr), .b_din(b_din), .b_dout(b_dout),
		.b_we(b_we), .b_rd(b_rd), .b_ready(b_ready),
		.m_addr(m_addr), .m_din(m_din), .m_dout(m_dout),
		.m_we(m_we), .m_rd(m_rd), .m_ready(m_ready)
	);

	wire        DDRAM_DOUT_READY, DDRAM_RD, DDRAM_WE;
	wire  [7:0] DDRAM_BURSTCNT, DDRAM_BE;
	wire [28:0] DDRAM_ADDR;
	wire [63:0] DDRAM_DOUT, DDRAM_DIN;

	ddram mem (.reset(reset), .DDRAM_CLK(clk), .DDRAM_BUSY(DDRAM_BUSY),
		.DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT),
		.DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN),
		.DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
		.addr(m_addr), .dout(m_dout), .din(m_din), .we(m_we), .rd(m_rd), .ready(m_ready));

	ddr_side side (.clk(clk), .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT),
		.DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY),
		.DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE));

	// --- the P2 baseline: a second, identical chain with NO arbiter -------
	// A client wired straight to its own rtl/ddram.sv + DDR-side model, fed
	// the identical stimulus on the identical cycles, sharing DDRAM_BUSY.
	// "Machines 0-4 are unaffected while savestate is idle" is a claim about
	// port A's cycle-level timing, and this is what it is measured against.
	reg  [27:0] d_addr = 0;
	reg   [7:0] d_din  = 0;
	reg         d_we = 0, d_rd = 0;
	wire  [7:0] d_dout;
	wire        d_ready;

	wire        DDRAM_DOUT_READY_D, DDRAM_RD_D, DDRAM_WE_D;
	wire  [7:0] DDRAM_BURSTCNT_D, DDRAM_BE_D;
	wire [28:0] DDRAM_ADDR_D;
	wire [63:0] DDRAM_DOUT_D, DDRAM_DIN_D;

	ddram memd (.reset(reset), .DDRAM_CLK(clk), .DDRAM_BUSY(DDRAM_BUSY),
		.DDRAM_BURSTCNT(DDRAM_BURSTCNT_D), .DDRAM_ADDR(DDRAM_ADDR_D), .DDRAM_DOUT(DDRAM_DOUT_D),
		.DDRAM_DOUT_READY(DDRAM_DOUT_READY_D), .DDRAM_RD(DDRAM_RD_D), .DDRAM_DIN(DDRAM_DIN_D),
		.DDRAM_BE(DDRAM_BE_D), .DDRAM_WE(DDRAM_WE_D),
		.addr(d_addr), .dout(d_dout), .din(d_din), .we(d_we), .rd(d_rd), .ready(d_ready));

	ddr_side sided (.clk(clk), .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT_D),
		.DDRAM_ADDR(DDRAM_ADDR_D), .DDRAM_DOUT(DDRAM_DOUT_D), .DDRAM_DOUT_READY(DDRAM_DOUT_READY_D),
		.DDRAM_RD(DDRAM_RD_D), .DDRAM_DIN(DDRAM_DIN_D), .DDRAM_BE(DDRAM_BE_D), .DDRAM_WE(DDRAM_WE_D));

	task automatic fail(input string msg);
		begin $fatal(1, "FAIL: %s", msg); end
	endtask

	// NOTE the `#1` before every ready-poll. @(posedge clk) resumes in the active
	// region, BEFORE the memory's nonblocking `busy <= ...` has landed, so polling
	// x_ready immediately reads the PRE-edge value: the loop exits before the
	// transfer has been accepted and the next access collides with it.
	// Without the delay this suite fails at test 1 with `got xx` - and fails
	// identically with the arbiter removed and A wired straight to the stub,
	// which is how the bug was localised to the testbench rather than the RTL.
	// Do not remove the delay to "simplify"; it is load-bearing.

	// Write one byte as client A, waiting for the handshake.
	task automatic a_write(input [27:0] ad, input [7:0] d);
		begin
			@(posedge clk); a_addr <= ad; a_din <= d; a_we <= 1;
			@(posedge clk); a_we <= 0;
			#1; while (!a_ready) @(posedge clk);
		end
	endtask

	task automatic b_write(input [27:0] ad, input [7:0] d);
		begin
			@(posedge clk); b_addr <= ad; b_din <= d; b_we <= 1;
			@(posedge clk); b_we <= 0;
			#1; while (!b_ready) @(posedge clk);
		end
	endtask

	task automatic a_read(input [27:0] ad, output [7:0] d);
		begin
			@(posedge clk); a_addr <= ad; a_rd <= 1;
			@(posedge clk); a_rd <= 0;
			#1; while (!a_ready) @(posedge clk);
			d = a_dout;
		end
	endtask

	task automatic b_read(input [27:0] ad, output [7:0] d);
		begin
			@(posedge clk); b_addr <= ad; b_rd <= 1;
			@(posedge clk); b_rd <= 0;
			#1; while (!b_ready) @(posedge clk);
			d = b_dout;
		end
	endtask

	// =====================================================================
	// Test 7 helper: one operation issued to BOTH chains on the same cycle,
	// returning each chain's own ready latency and read data. Both clients
	// pulse for one cycle, which is all rtl/ddram.sv's edge detector needs,
	// and the caller's next dual_op() asserts the following request on the
	// cycle right after ready - so consecutive calls are the back-to-back,
	// no-gap pattern that hazard 3 lives in.
	integer lat_arb, lat_dir;
	reg [7:0] got_arb, got_dir;

	task automatic dual_op(input bit is_wr, input [27:0] ad, input [7:0] d,
	                       input integer gap);
		integer n;
		reg da, dd;
		begin
			lat_arb = -1; lat_dir = -1;
			got_arb = 8'hxx; got_dir = 8'hxx;
			da = 0; dd = 0;
			repeat (gap) @(posedge clk);
			@(posedge clk);
			a_addr <= ad; a_din <= d; a_we <= is_wr; a_rd <= ~is_wr;
			d_addr <= ad; d_din <= d; d_we <= is_wr; d_rd <= ~is_wr;
			@(posedge clk);
			a_we <= 0; a_rd <= 0; d_we <= 0; d_rd <= 0;
			for (n = 1; n < 100; n = n + 1) begin
				#1;
				if (!da && a_ready) begin da = 1; lat_arb = n; got_arb = a_dout; end
				if (!dd && d_ready) begin dd = 1; lat_dir = n; got_dir = d_dout; end
				if (da && dd) n = 1000;
				else @(posedge clk);
			end
			if (!da || !dd)
				fail($sformatf("dual_op(%0d, %07x): no ready (arb %0d, direct %0d)",
				               is_wr, ad, lat_arb, lat_dir));
		end
	endtask

	// Op list for test 7. Ops 0-11 run BACK TO BACK with no gap - the next
	// request is asserted on the cycle right after ready - and cover a write,
	// a write to the same block, a read of the address just written (a
	// same-block hit fed from ram_cache), two different same-block cache-hit
	// reads in a row, a cache MISS read, and a read of an address A itself
	// wrote. Ops 12-17 repeat the same shapes with ONE idle cycle in between.
	//
	// The `exp` column is not a guess: it is what the arbiter as it stood
	// BEFORE this fix measured, op for op, against the same direct-wire
	// baseline. It is 1 for every back-to-back op and 0 for every gapped one,
	// which is hazard 3 in rtl/ddram_arb.sv's header - the request latch
	// forces one bubble cycle whenever a fresh request arrives while the
	// shared line is still asserted from its predecessor, and an idle cycle
	// in between removes the need for it. (The header used to say the cost
	// applied only to two same-block cache-hit reads back to back; it applies
	// to any back-to-back pair, and the header now says so.)
	localparam integer NOPS = 18;
	reg         op_wr  [0:NOPS-1];
	reg  [27:0] op_ad  [0:NOPS-1];
	reg   [7:0] op_d   [0:NOPS-1];
	integer     op_gap [0:NOPS-1];   // idle cycles before the request
	integer     op_la  [0:NOPS-1];   // measured arbiter-side ready latency
	integer     op_ld  [0:NOPS-1];   // measured direct-wire ready latency
	integer     op_dlt [0:NOPS-1];   // measured lat_arb - lat_dir
	integer     op_exp [0:NOPS-1];   // allowed difference

	task automatic setops;
		begin
			// idx  wr  address       data          gap  allowed diff
			op_wr[0]=1;  op_ad[0]=28'h0000800; op_d[0]=8'h11; op_gap[0]=0; op_exp[0]=0;
			op_wr[1]=1;  op_ad[1]=28'h0000801; op_d[1]=8'h22; op_gap[1]=0; op_exp[1]=1;
			op_wr[2]=0;  op_ad[2]=28'h0000800; op_d[2]=8'h00; op_gap[2]=0; op_exp[2]=1;
			op_wr[3]=0;  op_ad[3]=28'h0000801; op_d[3]=8'h00; op_gap[3]=0; op_exp[3]=1;
			op_wr[4]=0;  op_ad[4]=28'h0000900; op_d[4]=8'h00; op_gap[4]=0; op_exp[4]=1;
			op_wr[5]=0;  op_ad[5]=28'h0000901; op_d[5]=8'h00; op_gap[5]=0; op_exp[5]=1;
			op_wr[6]=0;  op_ad[6]=28'h0000902; op_d[6]=8'h00; op_gap[6]=0; op_exp[6]=1;
			op_wr[7]=1;  op_ad[7]=28'h0000903; op_d[7]=8'h33; op_gap[7]=0; op_exp[7]=1;
			op_wr[8]=0;  op_ad[8]=28'h0000903; op_d[8]=8'h00; op_gap[8]=0; op_exp[8]=1;
			op_wr[9]=0;  op_ad[9]=28'h0000a00; op_d[9]=8'h00; op_gap[9]=0; op_exp[9]=1;
			op_wr[10]=1; op_ad[10]=28'h0000a01; op_d[10]=8'h44; op_gap[10]=0; op_exp[10]=1;
			op_wr[11]=0; op_ad[11]=28'h0000a01; op_d[11]=8'h00; op_gap[11]=0; op_exp[11]=1;

			op_wr[12]=1; op_ad[12]=28'h0000b00; op_d[12]=8'h55; op_gap[12]=1; op_exp[12]=0;
			op_wr[13]=1; op_ad[13]=28'h0000b01; op_d[13]=8'h66; op_gap[13]=1; op_exp[13]=0;
			op_wr[14]=0; op_ad[14]=28'h0000b00; op_d[14]=8'h00; op_gap[14]=1; op_exp[14]=0;
			op_wr[15]=0; op_ad[15]=28'h0000b01; op_d[15]=8'h00; op_gap[15]=1; op_exp[15]=0;
			op_wr[16]=0; op_ad[16]=28'h0000c00; op_d[16]=8'h00; op_gap[16]=1; op_exp[16]=0;
			op_wr[17]=0; op_ad[17]=28'h0000c01; op_d[17]=8'h00; op_gap[17]=1; op_exp[17]=0;
		end
	endtask

	// =====================================================================
	// Test 8 helper: one directed hazard-4 case.
	//
	// Both clients raise a request; A wins on strict priority and B is
	// serviced after it. DDRAM_BUSY is forced high for `w` cycles starting
	// `p` cycles after the request, and every alignment is walked by the
	// caller - so no assumption about which cycle is "the" dangerous one is
	// baked into this test. Both clients' data is checked strictly: with B
	// requesting from the start, `b_active` inside the arbiter is high for
	// the whole case, so port A is held to the same standard as port B.
	//
	// a_pulse chooses A's shape: 0 = hold we/rd until a_ready is observed
	// (what rtl/gs.v does - its Z80 is stalled by CEN_p(CE & ~MEM_WAIT) with
	// MEM_WAIT = ~a_ready), 1 = pulse for exactly one cycle and let the
	// arbiter's latch carry it. The two fail differently, so both are walked.
	// a_delay slides A's request later than B's, which is how a port A
	// request arrives while a port B transaction is already in flight.
	task automatic hz4_case
	(
		input integer p, input integer w, input bit a_pulse, input integer a_delay,
		input bit is_wr, input [27:0] ada, input [27:0] adb,
		input [7:0] va, input [7:0] vb
	);
		integer n;
		reg da, db;
		reg [7:0] ga, gb;
		begin
			// Quiescent, DDRAM_BUSY low, so ddram.sv has certainly seen the
			// shared line idle before the case starts.
			busy_mode = 2; busy_man = 0;
			repeat (8) @(posedge clk);

			if (!is_wr) begin
				side.poke(ada, va);
				side.poke(adb, vb);
			end

			da = 0; db = 0; ga = 8'hxx; gb = 8'hxx;

			@(posedge clk);
			busy_man <= (0 >= p) && (0 < p + w);
			b_addr <= adb; b_din <= vb; b_we <= is_wr; b_rd <= ~is_wr;
			if (a_delay == 0) begin
				a_addr <= ada; a_din <= va; a_we <= is_wr; a_rd <= ~is_wr;
			end

			// Iteration n samples cycle n-1 (the `#1` lands just after the
			// edge that ended it, once the nonblocking updates have settled)
			// and then drives cycle n. A's ready is only believed from the
			// cycle its request was raised on: before that the bus may be
			// idle, and a_ready is an idle-high "ready to accept" level, not
			// a completion pulse.
			for (n = 1; n < 300; n = n + 1) begin
				#1;
				if (!da && (n - 1) >= a_delay && a_ready) begin da = 1; ga = a_dout; end
				if (!db && b_ready) begin db = 1; gb = b_dout; end
				@(posedge clk);
				busy_man <= (n >= p) && (n < p + w);
				if (n == a_delay) begin
					a_addr <= ada; a_din <= va; a_we <= is_wr; a_rd <= ~is_wr;
				end
				// A drops its request one cycle later if it pulses, or when it
				// has seen a_ready if it holds. B always holds (savestate does).
				if (a_pulse) begin
					if (n == a_delay + 1) begin a_we <= 0; a_rd <= 0; end
				end
				else if (da) begin a_we <= 0; a_rd <= 0; end
				if (db) begin b_we <= 0; b_rd <= 0; end
				if (da && db) n = 1000;
			end

			busy_man <= 0;
			a_we <= 0; a_rd <= 0; b_we <= 0; b_rd <= 0;
			repeat (8) @(posedge clk);

			if (!da || !db)
				fail($sformatf("hz4(p=%0d w=%0d pulse=%0d dly=%0d wr=%0d): no ready - A %0d B %0d (deadlock or lockout)",
				               p, w, a_pulse, a_delay, is_wr, da, db));
			if (is_wr) begin
				if (side.peek(ada) !== va)
					fail($sformatf("hz4(p=%0d w=%0d pulse=%0d dly=%0d wr): A's write to %07x was dropped - DDR has %02x, expected %02x",
					               p, w, a_pulse, a_delay, ada, side.peek(ada), va));
				if (side.peek(adb) !== vb)
					fail($sformatf("hz4(p=%0d w=%0d pulse=%0d dly=%0d wr): B's write to %07x was dropped - DDR has %02x, expected %02x",
					               p, w, a_pulse, a_delay, adb, side.peek(adb), vb));
			end
			else begin
				if (ga !== va)
					fail($sformatf("hz4(p=%0d w=%0d pulse=%0d dly=%0d rd): A read %07x and got %02x, expected %02x",
					               p, w, a_pulse, a_delay, ada, ga, va));
				if (gb !== vb)
					fail($sformatf("hz4(p=%0d w=%0d pulse=%0d dly=%0d rd): B read %07x and got %02x, expected %02x",
					               p, w, a_pulse, a_delay, adb, gb, vb));
			end
		end
	endtask

	integer i;
	integer j;
	integer ia, ib;
	reg [7:0] got, got_a, got_b;
	integer a_grants;
	integer hz4_cases;
	integer nz;

	initial begin
		busy_mode = 0;
		repeat (4) @(posedge clk); reset <= 0; repeat (4) @(posedge clk);

		// 1. A alone works and reads back what it wrote.
		a_write(28'h0000010, 8'hA5);
		a_read (28'h0000010, got);
		if (got !== 8'hA5) fail($sformatf("A readback got %02x expected A5", got));

		// 2. B alone works and does not disturb A's data.
		b_write(28'h0000020, 8'h5A);
		a_read (28'h0000020, got);
		if (got !== 8'h5A) fail($sformatf("B write not visible, got %02x", got));

		// 3. Idle B must leave A's ready alone - this is the
		//    "no behaviour change to machines 0-4" property.
		b_we = 0; b_rd = 0;
		@(posedge clk);
		if (!a_ready) fail("a_ready low while both clients idle");

		// 4. Under contention A must never be starved: hold B requesting
		//    continuously and check A still completes every transaction.
		a_grants = 0;
		fork
			begin : b_flood
				for (i = 0; i < 200; i = i + 1) b_write(28'h0000100 + i[27:0], i[7:0]);
			end
			begin : a_traffic
				for (i = 0; i < 20; i = i + 1) begin
					a_write(28'h0000200 + i[27:0], i[7:0] ^ 8'hFF);
					a_grants = a_grants + 1;
				end
			end
		join_any
		disable b_flood;

		if (a_grants !== 20)
			fail($sformatf("A completed only %0d of 20 writes under contention", a_grants));

		// 5. A's data survived the contention.
		for (i = 0; i < 20; i = i + 1) begin
			a_read(28'h0000200 + i[27:0], got);
			if (got !== (i[7:0] ^ 8'hFF))
				fail($sformatf("A data corrupted at %0d: got %02x expected %02x",
				               i, got, i[7:0] ^ 8'hFF));
		end

		// 6. Handover regression: B's request appears the very cycle A's own
		//    drops. rtl/ddram.sv only starts a new operation on a 0->1 edge of
		//    a SHARED old_we/old_rd pair; if the arbiter let the shared we
		//    line stay asserted straight through the ownership change, that
		//    edge would never appear and B's write would be silently dropped
		//    while b_ready still came back immediately. This is the exact
		//    scenario that was reported and reproduced against the real
		//    ddram.sv before this test existed.
		@(posedge clk); a_addr <= 28'h0000300; a_din <= 8'h11; a_we <= 1;
		@(posedge clk); a_we <= 0; b_addr <= 28'h0000400; b_din <= 8'h22; b_we <= 1;
		@(posedge clk); b_we <= 0;
		repeat (20) @(posedge clk);

		a_read(28'h0000300, got);
		if (got !== 8'h11)
			fail($sformatf("handover: A's write corrupted, got %02x expected 11", got));
		b_read(28'h0000400, got);
		if (got !== 8'h22)
			fail($sformatf("handover: B's write was lost, got %02x expected 22", got));

		// 7. P2: port A through the arbiter, cycle for cycle, against a
		//    client wired STRAIGHT to its own rtl/ddram.sv - B held idle
		//    throughout, DDRAM_BUSY tied low so the comparison is
		//    deterministic. The arbiter is allowed to cost port A exactly the
		//    one pre-existing cycle documented in rtl/ddram_arb.sv's header
		//    (hazard 3, A's own back-to-back same-block cache-hit reads) and
		//    nothing more.
		b_addr = 0; b_din = 0; b_we = 0; b_rd = 0;
		busy_mode = 0;
		setops;
		repeat (8) @(posedge clk);
		for (i = 0; i < NOPS; i = i + 1) begin
			dual_op(op_wr[i], op_ad[i], op_d[i], op_gap[i]);
			op_la[i]  = lat_arb;
			op_ld[i]  = lat_dir;
			op_dlt[i] = lat_arb - lat_dir;
			if (!op_wr[i] && got_arb !== got_dir)
				fail($sformatf("P2 op %0d (read %07x): arbiter returned %02x, direct wire returned %02x",
				               i, op_ad[i], got_arb, got_dir));
		end
		nz = 0;
		for (i = 0; i < NOPS; i = i + 1) begin
			$display("  P2 op %0d %s %07x gap %0d: arb %0d cyc, direct %0d cyc, diff %0d (pre-fix %0d)",
			         i, op_wr[i] ? "wr" : "rd", op_ad[i], op_gap[i],
			         op_la[i], op_ld[i], op_dlt[i], op_exp[i]);
			if (op_dlt[i] !== op_exp[i])
				fail($sformatf("P2 op %0d %s %07x gap %0d: port A took %0d cycles through the arbiter vs %0d on a direct wire (diff %0d) - the arbiter as it stood before this fix measured %0d, so port A's timing with B idle is NOT bit-identical any more",
				               i, op_wr[i] ? "wr" : "rd", op_ad[i], op_gap[i],
				               op_la[i], op_ld[i], op_dlt[i], op_exp[i]));
			if (op_dlt[i] != 0) nz = nz + 1;
		end
		$display("  P2: %0d of %0d ops differ from the direct wire, every one of them by the same amount as before this fix (hazard 3)",
		         nz, NOPS);

		// 8. Hazard 4, the phantom-transaction regression. rtl/ddram.sv's
		//    request sampling is wrapped in `if(!DDRAM_BUSY)` while its `busy`
		//    register is not, so a request it never looked at reads back as
		//    ready. Every alignment of a DDRAM_BUSY stretch against a pair of
		//    A/B transactions is walked, for both of client A's shapes, for
		//    reads and for writes.
		//
		//    Addresses: case n puts A at 0x2000 + 16n and B at 8 bytes above
		//    it, so every case gets its own pair of 8-byte blocks (A's block
		//    2n+0x400, B's block 2n+0x401) - each read is therefore a genuine
		//    ddram.sv cache miss, A and B can never alias each other's block,
		//    and 768 cases fit inside blocks 0x400-0x9FF without touching the
		//    ranges tests 1-6, test 7 or test 9 use. The whole map is checked
		//    by script, not by eye: ddr_side indexes its array by addr[14:3],
		//    so it aliases every 0x8000 and two addresses that could never
		//    collide in the real 28-bit space can collide in the model.
		hz4_cases = 0;
		for (i = 0; i < 16; i = i + 1)
			for (j = 1; j <= 3; j = j + 1)
				for (ia = 0; ia < 2; ia = ia + 1)
					for (ib = 0; ib < 4; ib = ib + 1) begin
						hz4_case(i, j, ia[0], ib, 1'b0,
						         28'h0002000 + hz4_cases[27:0] * 28'd16,
						         28'h0002008 + hz4_cases[27:0] * 28'd16,
						         8'hA0 + i[7:0], 8'h50 + j[7:0]);
						hz4_cases = hz4_cases + 1;
					end
		for (i = 0; i < 16; i = i + 1)
			for (j = 1; j <= 3; j = j + 1)
				for (ia = 0; ia < 2; ia = ia + 1)
					for (ib = 0; ib < 4; ib = ib + 1) begin
						hz4_case(i, j, ia[0], ib, 1'b1,
						         28'h0002000 + hz4_cases[27:0] * 28'd16,
						         28'h0002008 + hz4_cases[27:0] * 28'd16,
						         8'hC0 + i[7:0], 8'h70 + j[7:0]);
						hz4_cases = hz4_cases + 1;
					end
		$display("  hazard 4: %0d directed cases (busy offsets 0-15 x widths 1-3 x both client-A shapes x A-delay 0-3 x read/write)",
		         hz4_cases);

		// 9. Contention stress with a realistic DDRAM_BUSY. Port B's data is
		//    checked strictly - that is the savestate path, and it must never
		//    take another client's byte. Port A is checked for progress only:
		//    with savestate idle the arbiter deliberately keeps port A's
		//    pre-existing relaxed completion rule (see rtl/ddram_arb.sv on
		//    b_active and P2), so an A read that lands in a DDRAM_BUSY freeze
		//    while B happens to be quiescent may legitimately take a stale
		//    byte - exactly as it did before this arbiter existed.
		//
		//    A's traffic has a gap between transactions ON PURPOSE. Port A has
		//    STRICT priority with no fairness counter, so a client A that
		//    re-asserts on the cycle after every ready never leaves a_req low
		//    and starves port B outright - measured: 400 A pairs completed and
		//    B got the bus zero times. That is the arbiter's documented
		//    priority rule, not a defect, and rtl/gs.v's Z80 has instruction
		//    cycles between its memory accesses regardless.
		busy_mode = 1;
		a_we = 0; a_rd = 0; b_we = 0; b_rd = 0;
		repeat (8) @(posedge clk);
		a_grants = 0;
		ia = 0;
		fork
			begin : sb
				for (ib = 0; ib < 60; ib = ib + 1) begin
					b_write(28'h0005000 + ib[27:0] * 28'd8, 8'h80 + ib[7:0]);
					b_read (28'h0005000 + ib[27:0] * 28'd8, got_b);
					if (got_b !== (8'h80 + ib[7:0]))
						fail($sformatf("stress: B read back %02x at %07x, expected %02x",
						               got_b, 28'h0005000 + ib[27:0] * 28'd8, 8'h80 + ib[7:0]));
				end
			end
			begin : sa
				forever begin
					a_write(28'h0005800 + ia[27:0] * 28'd8, 8'h10 + ia[7:0]);
					a_read (28'h0005800 + ia[27:0] * 28'd8, got_a);
					ia = (ia + 1) & 32'h1ff;
					a_grants = a_grants + 1;
					repeat (6) @(posedge clk);
				end
			end
		join_any
		disable sa;
		if (ib !== 60)
			fail($sformatf("stress: B completed only %0d of 60 write/read pairs", ib));
		if (a_grants < 20)
			fail($sformatf("stress: A completed only %0d write/read transactions - port A is being starved", a_grants));
		$display("  stress: B did 60 verified write/read pairs against %0d concurrent A pairs, DDRAM_BUSY on the LFSR model",
		         a_grants);

		$display("RESULT: PASS");
		$finish;
	end

	// Watchdog: a deadlocked arbiter must fail, not hang the suite.
	initial begin
		#5000000;
		$fatal(1, "FAIL: timeout - arbiter deadlocked");
	end
endmodule
