//============================================================================
//  Two-client arbiter for rtl/ddram.sv
//
//  Client A (General Sound) has strict priority. Client B (savestate) only
//  gets the bus when A is not asking for it, and a transaction already in
//  flight is allowed to finish - the underlying ddram.sv cannot be preempted
//  mid-transaction without losing the result.
//
//  rtl/ddram.sv only starts a new operation on a 0->1 edge of we/rd, using a
//  SINGLE old_we/old_rd pair shared by whichever client is currently muxed
//  onto the bus (a level-sensitive model of that behaviour cannot exercise
//  this at all - see tb/tb_ddram_arb.sv, which drives the real ddram.sv).
//  Three hazards follow directly from that, and a fourth follows from
//  ddram.sv being freezable by DDRAM_BUSY without saying so; this arbiter
//  defends against all four:
//
//  1. Handover glitch. If the arbiter switched owners while we/rd stayed
//     asserted across the switch (the outgoing owner's tail overlapping the
//     incoming owner's head), ddram.sv would never see a falling edge: the
//     new request is silently dropped (a write is lost, a read returns
//     stale data) while its ready line comes back immediately as if nothing
//     were wrong.
//
//  2. A client that only pulses we/rd for a single cycle (rather than
//     holding it until it observes ready) can have its request outlast on
//     the bus for longer than it stays asserted at the client: A's strict
//     priority means B's request may sit for several cycles before this
//     arbiter can service it, and by then B may already have dropped we/rd.
//     Each client's address/data/op is therefore LATCHED the first cycle a
//     request is seen and driven from that latch - not from the client's
//     live signals - until the arbiter actually services it. Clients may
//     pulse or hold; either works. The latch stays synced to the live
//     request for as long as the client keeps asking (see the register
//     block below): an abandoned, never-serviced request followed by a
//     fresh one for a different address must have the new one win, not
//     silently rot behind the old one forever.
//
//  3. The same latch reintroduces a version of hazard 1 within a SINGLE
//     client's own back-to-back requests: a same-8-byte-block cache-hit
//     read completes with zero ddram.sv busy cycles, so the very next
//     request (even from the same client) can arrive the same cycle the
//     latch for the previous one clears, handing off live-to-live with the
//     shared we/rd line never seen low in between.
//
//  4. ddram.sv can be frozen mid-request by DDRAM_BUSY without saying so.
//     Its whole request-sampling block sits inside `if(!DDRAM_BUSY)`, but its
//     `busy` register keeps whatever it held - so a request ddram.sv has not
//     even looked at reads back as `ready`. Reporting that as completion does
//     not merely lose one byte: it releases `in_flight`, ddram.sv then samples
//     the still-asserted line a cycle later and starts a PHANTOM transaction
//     no client is waiting on, and the next client routed onto the bus is
//     handed the phantom's data. `ddr_seen` (below) is the proof that ddram.sv
//     actually had an opportunity to sample the edge: b_done and the
//     `in_flight` release always require it, a_done requires it while
//     savestate is involved (see b_active for why that one is conditional).
//     The same freeze also swallows the `handover` bubble itself - a bubble
//     that lands inside a DDRAM_BUSY stretch leaves old_we/old_rd set, so the
//     next request's rising edge is not an edge to ddram.sv at all and is
//     dropped with busy left at 0. `edge_wait` (below) holds the line low past
//     the single cycle until ddram.sv has been able to see it.
//
//  `handover` forces one idle (we=0, rd=0) cycle to guarantee a clean edge
//  whenever the routing is about to switch owners (hazard 1) or a fresh
//  request for the client already being routed is arriving right as its
//  predecessor clears (hazard 3) - either way, only if the line was left
//  asserted, since an idle line already gives ddram.sv the edge it needs.
//
//  `in_flight`/`in_flight_owner` pin bus ownership to whoever's request
//  ddram.sv is actually processing, latched the instant *we* generate a
//  fresh edge on m_we/m_rd (not inferred from m_ready, which lags the real
//  transaction start by one cycle - see the ddram.sv comment on old_we/
//  old_rd). This also stops a completing transaction's ready pulse from
//  being misrouted to a different client - never hand back data fetched for
//  someone else's address. `done` (and so `ready`) is additionally held off
//  on the exact cycle a fresh edge is first presented, because ddram.sv
//  cannot have reacted to it yet: invisible for an ordinary write/read
//  (busy asserts the following cycle regardless of who is watching), but
//  load-bearing for a cache hit, whose busy never asserts at all.
//
//  With B permanently idle, sel_b never changes and in_flight never becomes
//  B, so hazard 1 never applies, A's own latch always equals its live
//  signals, and hazard 4's two defences are both switched off (see b_active
//  below) - EXCEPT hazard 3 is A-vs-A, not A-vs-B, and still applies. Port A
//  pays exactly one cycle for it whenever A asserts its next request on the
//  cycle right after it saw a_ready, whatever the two operations are: the
//  bubble is what gives ddram.sv its falling edge, and A's own tail is still
//  on the shared line at that point. One idle cycle between A's transactions
//  removes the cost entirely. Measured against a client wired straight to its
//  own rtl/ddram.sv, same stimulus, same cycles (tb/tb_ddram_arb.sv test 7,
//  which prints the whole table): back-to-back write, write-to-same-block,
//  read-after-own-write, two different same-block cache-hit reads, and a
//  cache-miss read all cost +1; with one idle cycle in between every one of
//  them is bit-identical. Those numbers are unchanged by the hazard-4 work -
//  the same table, op for op, comes out of the arbiter as it stood before it.
//  This is the one place this arbiter is not a pure wire to machines 0-4; it
//  is the price of hazard 2's latch existing at all, and it is called out here
//  rather than left silent.
//============================================================================

module ddram_arb
(
	input             clk,

	// Real DDR-side busy from the physical controller (fed straight through
	// from the top level's DDRAM_BUSY - see the Task-busyfix comment on
	// ddr_seen below for why this arbiter needs to see it directly).
	input             DDRAM_BUSY,

	input      [27:0] a_addr,
	input       [7:0] a_din,
	output      [7:0] a_dout,
	input             a_we,
	input             a_rd,
	output            a_ready,

	input      [27:0] b_addr,
	input       [7:0] b_din,
	output      [7:0] b_dout,
	input             b_we,
	input             b_rd,
	output            b_ready,

	output     [27:0] m_addr,
	output      [7:0] m_din,
	input       [7:0] m_dout,
	output            m_we,
	output            m_rd,
	input             m_ready
);

localparam OWNER_A = 1'b0;
localparam OWNER_B = 1'b1;

// Latched per-client request: captured the first cycle a client asks, held
// until the arbiter actually services it, regardless of whether the client
// itself keeps asking that whole time.
reg        a_pending = 0, b_pending = 0;
reg [27:0] a_ladr,        b_ladr;
reg  [7:0] a_ldin,        b_ldin;
reg        a_lwe = 0,     b_lwe = 0;
reg        a_lrd = 0,     b_lrd = 0;

wire a_new_req = a_we | a_rd;
wire b_new_req = b_we | b_rd;

// What each client is actually asking for right now: the fresh request on
// its very first cycle (before the latch has caught up), the latch after.
wire [27:0] a_qaddr = a_pending ? a_ladr : a_addr;
wire  [7:0] a_qdin  = a_pending ? a_ldin : a_din;
wire        a_qwe   = a_pending ? a_lwe  : a_we;
wire        a_qrd   = a_pending ? a_lrd  : a_rd;

wire [27:0] b_qaddr = b_pending ? b_ladr : b_addr;
wire  [7:0] b_qdin  = b_pending ? b_ldin : b_din;
wire        b_qwe   = b_pending ? b_lwe  : b_we;
wire        b_qrd   = b_pending ? b_lrd  : b_rd;

wire a_req = a_pending | a_new_req;
wire b_req = b_pending | b_new_req;

reg  in_flight       = 0;        // ddram.sv is processing a transaction we started
reg  in_flight_owner = OWNER_A;  // who that transaction belongs to
reg  prev_sel_b      = 0;        // who was actually routed last cycle
reg  prev_we = 0, prev_rd = 0;   // what we actually drove onto m_we/m_rd last cycle

// Who wants the bus this cycle: pinned to the in-flight owner until its
// transaction completes, otherwise strict A priority.
wire want_b = in_flight ? (in_flight_owner == OWNER_B) : (~a_req & b_req);
wire sel_b  = want_b;

// Is the client we are about to route a BRAND NEW request this exact cycle
// (its own first cycle, not yet latched)? A completed transaction whose
// done pulse landed with a fresh request already waiting is the same
// glitch as an ownership handover, just without sel_b changing: a same-
// block cache-hit read finishes with zero busy cycles, so the very next
// request can arrive the same cycle the latch for the previous one clears,
// handing off live-to-live with the line never seen low in between.
wire a_fresh = !a_pending & a_new_req;
wire b_fresh = !b_pending & b_new_req;
wire routed_fresh = sel_b ? b_fresh : a_fresh;

// Task-E13: "savestate is involved". Both of this module's defences against
// hazard 4 have a cost that machines 0-4 must not pay while savestate is idle
// (see below and the a_done comment), so both are conditional on this - and it
// is derived entirely from port B's own signals in this module's own clock
// domain, because ss_busy/ss_loading live in clk_sys and importing them would
// need a synchroniser and a top-level port this module does not have.
//
// `b_req` alone is too brief a condition: B can raise a request in the middle
// of a port A transaction that started while the rule was relaxed, and that
// transaction has to be held to the strict rule from that moment on. (It can
// be - the proof below is tracked whether or not it is being used, so it is
// already accumulating.) So the condition latches on B's first request and
// persists until the bus is genuinely quiescent: nobody asking, nothing in
// flight, and the shared we/rd line low for a full cycle. `b_req` is ORed in
// live as well as latched, so the rule tightens on the very cycle B asks
// rather than one cycle later - which is exactly the cycle an early a_done
// would otherwise fire on.
reg  b_involved = 0;
wire bus_quiet  = ~a_req & ~b_req & ~in_flight & ~prev_we & ~prev_rd;
wire b_active   = b_req | b_involved;

always @(posedge clk) begin
	if (b_req)
		b_involved <= 1;
	else if (bus_quiet)
		b_involved <= 0;
end

// Task-E13: has ddram.sv had an opportunity to CLEAR its old_we/old_rd since
// the last thing we presented? The one-cycle bubble below is what gives
// ddram.sv its falling edge, but ddram.sv only looks at the line at all on a
// cycle where DDRAM_BUSY reads low - so a bubble that lands entirely inside a
// DDRAM_BUSY stretch is invisible, old_we/old_rd stay set from the previous
// request, and the NEXT request's rising edge is then not an edge as far as
// ddram.sv is concerned: it is dropped outright, with busy left at 0 so
// m_ready reports it complete immediately. Measured on the real ddram.sv with
// a General-Sound-shaped client A running against a save: a savestate read of
// a slot byte handed back A's previous byte, word0 assembling as ff00ffff.
// Note the same is true of an idle line that was never bubbled at all - a gap
// between two requests is only as good as ddram.sv's chance to observe it -
// which is why this is tracked from "nothing presented" rather than from
// `handover`.
//
// Caveat kept deliberately: ddram.sv also freezes old_we/old_rd while it is
// mid-read (state == 1, its edge detection being in the `else` of
// `if(state)`), which this cannot see. That window is unreachable here because
// in_flight pins the bus to the owner until m_ready, and state == 1 implies
// busy, i.e. ~m_ready; the only way in is a client that abandons a request it
// is already having serviced and presents a different one, which neither
// rtl/gs.v nor rtl/savestate.sv does (both hold until they see ready).
reg edge_ready = 0;

always @(posedge clk) begin
	if (m_we | m_rd)
		edge_ready <= 0;
	else if (!DDRAM_BUSY)
		edge_ready <= 1;
end

// What we would put on the bus this cycle if nothing held us back, and whether
// that would be a fresh 0->1 edge on the shared line (i.e. exactly the thing
// ddram.sv must be in a position to see).
wire present_we = sel_b ? b_qwe : a_qwe;
wire present_rd = sel_b ? b_qrd : a_qrd;
wire fresh_edge = (present_we & ~prev_we) | (present_rd & ~prev_rd);

// Force a bubble instead of presenting a request when either the routing
// is switching to a different client than last cycle, or a fresh request
// for the SAME client is arriving right as its predecessor's slot clears -
// in both cases the line just left behind was still asserted, and without
// the bubble ddram.sv would never see the edge.
//
// `edge_wait` extends that for hazard 4: keep holding the line low, past the
// single cycle, until ddram.sv has actually had a low-DDRAM_BUSY cycle in
// which to observe it. It only ever delays a fresh edge; a request already on
// the bus is not pulled back off it, because fresh_edge stays 0 for as long as
// the client keeps asking for the same operation, which is what both real
// clients do. Conditional on b_active because with B idle it would add cycles
// on top of the one hazard 3 already costs port A on every back-to-back
// request, and machines 0-4 must be bit-identical then.
wire edge_wait = b_active & ~edge_ready & fresh_edge;

wire handover = ((((sel_b != prev_sel_b) || routed_fresh)) && (prev_we | prev_rd))
              | edge_wait;

assign m_addr = sel_b ? b_qaddr : a_qaddr;
assign m_din  = sel_b ? b_qdin  : a_qdin;
assign m_we   = handover ? 1'b0 : (sel_b ? b_qwe : a_qwe);
assign m_rd   = handover ? 1'b0 : (sel_b ? b_qrd : a_qrd);

assign a_dout = m_dout;
assign b_dout = m_dout;

// A transaction starts exactly when we ourselves present a fresh edge to
// ddram.sv - computed from what we actually drove, not from m_ready, so
// ownership latches on time every time.
wire starting = (m_we & ~prev_we) | (m_rd & ~prev_rd);

// ddram.sv cannot have reacted yet to an edge we are presenting THIS cycle
// (its own old_we/old_rd compare against the PREVIOUS cycle's line, per
// nonblocking-assignment scheduling) - so m_ready, on the very cycle
// `starting` fires, still describes whatever was true before this request
// existed. That is invisible for an ordinary busy write/read (busy asserts
// the following cycle regardless), but a same-block CACHE-HIT read never
// asserts busy at all, so m_ready would stay high straight through and this
// arbiter would report done before ddram.sv has even seen the request -
// handing back whatever dout held previously, not this client's own data.
// Gating done/ready off on the starting cycle costs A nothing when B is
// idle: sel_b never changes there, so `starting` only ever coincides with
// the first cycle of A's own request, which is exactly when a direct wire
// to ddram.sv would also not yet show ready (ordinary busy transactions
// need that cycle regardless; a cache hit gets it back on the very next
// cycle, one cycle sooner than falling in "busy" ever would explicitly
// signal).
//
// Task-busyfix: rtl/ddram.sv line 82 wraps its ENTIRE request-sampling block
// - old_rd/old_we edge detection included - in `if(!DDRAM_BUSY)`. DDRAM_BUSY
// is the real DDR-side controller's own busy line, unrelated to anything
// this arbiter drives, and can be asserted for arbitrary stretches for
// reasons outside this module's knowledge. `starting` (above) only proves
// ddram.sv HAS NOT YET reacted on the one cycle we first present an edge; it
// says nothing about the cycles after that. If DDRAM_BUSY is high on every
// cycle from `starting` onward, ddram.sv's old_we/old_rd never update and it
// never sees our request at all - yet its `busy` register just holds
// whatever it held before (0, if the bus was idle), so m_ready reads high
// throughout as if the transaction were already done. A plain "wait for
// busy to rise" cannot distinguish that from a genuine cache-hit read, which
// legitimately never raises busy either (see the file-header comment on
// hazard 3) - so what is tracked here is not busy, but whether ddram.sv has
// had an actual opportunity to sample the edge: at least one clk_aud cycle,
// at or after the first live (non-starting, non-handover) cycle of our
// request, on which DDRAM_BUSY read low. ddr_seen goes high the cycle after
// that opportunity - lining up exactly with when ddram.sv's own nonblocking
// updates (busy, or ram_q for a hit) land - so m_ready is only trusted once
// it is actually describing post-edge state.
//
// Task-E13: tracked for WHICHEVER port is routed, not just for B, and the
// in_flight release now needs the same proof. An earlier version scoped this
// to port B on the theory that port A's only exposure was an occasional stale
// byte, inaudible to General Sound. That was wrong, and the reason it was
// wrong is worth keeping: an early a_done also clears `in_flight`, which is
// the only thing pinning bus ownership. ddram.sv then samples A's
// still-asserted line one cycle later (the latch clear is a nonblocking
// update) and starts a transaction nobody is waiting on; the arbiter, now
// believing the bus idle, routes B and presents B's edge - which ddram.sv
// cannot see, because its edge detection sits in the `else` of `if(state)`.
// A's phantom read then completes and its data is handed to B. Measured with
// the real ddram.sv: a savestate arming read assembling word0 as 00ffffff
// instead of ffffffff, and a savestate write being dropped outright.
//
// The TRACKING here is unconditional - it is cheap and always correct - but
// the GATING of a_done is conditional on b_active, because it is not free:
// for a same-block cache-hit read ddram.sv never asserts busy at all, so
// m_ready is already high on the first live cycle and a_done fires there, one
// cycle before any "seen" proof can exist. Gating port A unconditionally would
// therefore cost machines 0-4 a cycle on every cache hit, and the invariant is
// that they are untouched while savestate is idle. Inside a save window a
// cycle either way is immaterial: the Z80 is halted there.
//
// The in_flight release needs no such exemption. With B uninvolved, b_req is 0
// and in_flight_owner can only ever be A, so want_b - the only consumer of
// either - is 0 whatever in_flight holds; holding it longer is invisible on
// port A. Releasing it exactly when we report completion (a_done | b_done) is
// also what keeps the relaxed rule deadlock-free: an early a_done taken while
// the rule was relaxed still releases ownership, instead of stranding
// in_flight on a transaction whose proof can never arrive because its line has
// already been dropped.
reg ddr_seen = 0;

// The routed request is on the bus and ddram.sv is free to look at it - see
// above for why `starting` and `handover` cycles do not count.
wire req_live = (m_we | m_rd) & ~handover & ~starting;

always @(posedge clk) begin
	if (starting)
		ddr_seen <= 0;
	else if (req_live && !DDRAM_BUSY)
		ddr_seen <= 1;
end

// `~in_flight` keeps a_ready's idle level: with nothing of A's in flight there
// is no transaction to report early, and a_ready is a "ready to accept" level,
// not just a completion pulse. It cannot weaken the gate - in_flight is set on
// the edge after `starting`, so every cycle an early a_done could fire on has
// in_flight high, and in_flight is only ever released by a_done/b_done itself.
wire a_done = m_ready & ~sel_b & ~handover & ~starting & (ddr_seen | ~in_flight | ~b_active);
wire b_done = m_ready &  sel_b & ~handover & ~starting &  ddr_seen;

assign a_ready = a_done;
assign b_ready = b_done;

always @(posedge clk) begin
	prev_sel_b <= sel_b;
	prev_we    <= m_we;
	prev_rd    <= m_rd;

	if (starting) begin
		in_flight       <= 1;
		in_flight_owner <= sel_b;
	end
	else if (in_flight && (a_done | b_done)) begin
		in_flight <= 0;
	end

	// Keep the latch synced to the live request for as long as the client is
	// asking for anything - not just its first cycle. A client that abandons
	// an unserviced request and raises a different one (the only way that
	// happens here is tb's `disable b_flood` cutting a flood iteration off
	// mid-wait) must have the new address win, not sit silently behind the
	// old one forever: a_pending would otherwise never see the `!a_pending`
	// window needed to latch it, since only a_done - which requires this
	// client to actually be serviced - ever clears it. Only once the client
	// stops asking (a_new_req low) does the completed transaction's clear
	// take effect.
	if (a_new_req) begin
		a_pending <= 1;
		a_ladr <= a_addr; a_ldin <= a_din; a_lwe <= a_we; a_lrd <= a_rd;
	end
	else if (a_done) begin
		a_pending <= 0;
		a_lwe <= 0; a_lrd <= 0;
	end

	if (b_new_req) begin
		b_pending <= 1;
		b_ladr <= b_addr; b_ldin <= b_din; b_lwe <= b_we; b_lrd <= b_rd;
	end
	else if (b_done) begin
		b_pending <= 0;
		b_lwe <= 0; b_lrd <= 0;
	end
end

endmodule
