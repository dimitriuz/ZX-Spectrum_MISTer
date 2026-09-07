//============================================================================
//  Clock-domain bridge for a byte-wide DDR client.
//
//  rtl/savestate.sv runs on clk_sys (112 MHz, pll_0002.v:25) while
//  rtl/ddram_arb.sv and rtl/ddram.sv run on clk_aud (56 MHz, pll_0002.v:28).
//  savestate raises we/rd for exactly ONE clk_sys cycle. Wired straight
//  across, roughly half of those strobes land entirely between two clk_aud
//  rising edges and are never sampled - and because savestate's ST_S_BYTE
//  advances wr_ptr and byte_cnt in the same cycle it raises ddr_we, a missed
//  strobe DROPS A PAYLOAD BYTE rather than stalling. The result is a
//  plausible-looking but wrong snapshot. Widening the pulse to two cycles
//  would paper over it only while the ratio stays exactly 2:1; this core's
//  PLL has been retuned before, so the fix must not depend on the ratio.
//
//  This is a classic four-phase (full) request/acknowledge handshake, which
//  is correct for ANY ratio and ANY phase relationship:
//
//      clk_in :  req  0->1                              req 1->0
//      clk_out:          req_a seen -> issue -> done -> ack 0->1  -> ack 1->0
//      clk_in :                                   ack_s seen ---^        |
//      clk_in :  ready released once ack_s has fallen again <------------+
//
//  Properties this buys, in the order they matter:
//
//  1. EXACTLY ONCE. `req` is a level, held until the far side acknowledges,
//     so it cannot be missed however the edges line up. The far side issues
//     on the M_IDLE -> M_WAIT transition, which can only be taken again
//     after `req` has been seen LOW again (the M_ACK state), so it cannot
//     issue twice for one request.
//  2. NO EARLY ADVANCE. `ready` is low from the cycle a request is captured
//     until the whole four-phase cycle has closed, so savestate physically
//     cannot start the next transaction (or advance wr_ptr) early.
//  3. READ DATA IS STABLE. d_lat is loaded in clk_out on the completion
//     cycle, strictly BEFORE `ack` rises. `ack` then costs two clk_in flops
//     to become visible, so d_lat has been stable for at least that long
//     when clk_in copies it into `dout`, and `dout` then holds until the
//     next transaction completes.
//  4. NO COMBINATIONAL PATH CROSSES. The two control signals - req and ack -
//     each go through a two-flop synchroniser. The address/data buses do NOT
//     (and deliberately must not: running a multi-bit bus through
//     synchronisers lets its bits resolve on different cycles, which is
//     exactly the corruption a handshake exists to prevent). They are
//     register-to-register - clk_in's r_* regs into clk_out's m_* regs - and
//     the protocol guarantees they are stable from before req rises until
//     after ack returns, which is the standard and correct discipline. The
//     boundary therefore carries no combinational logic at all.
//  5. savestate IS UNCHANGED. Its one-cycle we/rd pulse is captured by the
//     clk_in side, which is its own domain; its level-polled `ready` is
//     driven by the clk_in side too.
//
//  `m_ready` may be either ddram_arb's one-cycle completion pulse or
//  ddram.sv's own level `ready`: the M_WAIT bubble spends the cycle in which
//  the request is actually presented on the bus without looking at m_ready,
//  so a level that has not fallen yet cannot be mistaken for a completion.
//
//  No reset port, matching rtl/ddram_arb.sv: every register has a power-up
//  value, and an in-flight transaction completes on its own even if the
//  client is reset under it, so the handshake cannot be left half-open.
//============================================================================

module ddr_cdc
(
	// ---- client side, in the client's clock domain ----
	input             clk_in,
	input      [27:0] addr,
	input       [7:0] din,
	output reg  [7:0] dout = 0,
	input             we,
	input             rd,
	output            ready,

	// ---- memory side, in the memory's clock domain ----
	input             clk_out,
	// Initialised like every internal register in this file. Cyclone V powers
	// registers to 0 so hardware does not depend on it, but without it m_we
	// and m_rd are X on the first clk_out edge in simulation and that X
	// reaches ddram_arb's b_we/b_rd and, combinationally, ddram's we/rd.
	output reg [27:0] m_addr = 0,
	output reg  [7:0] m_din = 0,
	input       [7:0] m_dout,
	output reg        m_we = 0,
	output reg        m_rd = 0,
	input             m_ready
);

localparam S_IDLE = 2'd0, S_REQ = 2'd1, S_ACK = 2'd2;
localparam M_IDLE = 2'd0, M_WAIT = 2'd1, M_RUN = 2'd2, M_ACK = 2'd3;

reg        req = 0;
reg        ack = 0;
reg [27:0] r_addr = 0;
reg  [7:0] r_din  = 0;
reg        r_we = 0, r_rd = 0;
reg  [7:0] d_lat = 0;

// Two-flop synchronisers, one per control signal, each in the receiving
// domain. Control only - see note 4 above for why the buses are not here.
reg [1:0] req_sync = 0;      // req  : clk_in  -> clk_out
reg [1:0] ack_sync = 0;      // ack  : clk_out -> clk_in
always @(posedge clk_out) req_sync <= {req_sync[0], req};
always @(posedge clk_in)  ack_sync <= {ack_sync[0], ack};
wire req_a = req_sync[1];
wire ack_s = ack_sync[1];

// ---------------- client side (clk_in) ----------------
reg [1:0] s_state = S_IDLE;

// Held low for the whole handshake. It is deliberately still high during the
// client's own request cycle, exactly as rtl/ddram.sv's ready is: savestate
// guards that cycle itself with `!ddr_we` / `!ddr_rd` (see its ST_S_BYTE
// comment), and matching ddram.sv here keeps the two interchangeable.
assign ready = (s_state == S_IDLE);

always @(posedge clk_in) begin
	case (s_state)
		S_IDLE:
			if (we | rd) begin
				r_addr  <= addr;
				r_din   <= din;
				r_we    <= we;
				r_rd    <= rd;
				req     <= 1;
				s_state <= S_REQ;
			end

		S_REQ:
			if (ack_s) begin
				dout    <= d_lat;    // stable: written before ack rose
				req     <= 0;
				s_state <= S_ACK;
			end

		S_ACK:
			if (!ack_s) s_state <= S_IDLE;

		default: s_state <= S_IDLE;
	endcase
end

// ---------------- memory side (clk_out) ----------------
reg [1:0] m_state = M_IDLE;

always @(posedge clk_out) begin
	m_we <= 0;
	m_rd <= 0;

	case (m_state)
		M_IDLE:
			if (req_a) begin
				m_addr  <= r_addr;
				m_din   <= r_din;
				m_we    <= r_we;
				m_rd    <= r_rd;
				m_state <= M_WAIT;
			end

		// The cycle in which we/rd is actually on the bus. m_ready still
		// describes the state before this request, so it is ignored here.
		M_WAIT: m_state <= M_RUN;

		M_RUN:
			if (m_ready) begin
				d_lat   <= m_dout;
				ack     <= 1;
				m_state <= M_ACK;
			end

		M_ACK:
			if (!req_a) begin
				ack     <= 0;
				m_state <= M_IDLE;
			end
	endcase
end

endmodule
