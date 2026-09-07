derive_pll_clocks
derive_clock_uncertainty

set clk_sys {*|pll|pll_inst|altera_pll_i|*[0].*|divclk}
set clk_56m {*|pll|pll_inst|altera_pll_i|*[1].*|divclk}

set_multicycle_path -from [get_clocks $clk_56m] -to [get_clocks $clk_sys] -setup 2
set_multicycle_path -from [get_clocks $clk_56m] -to [get_clocks $clk_sys] -hold 1

# Effective clock is only half of the system clock, so allow 2 clock cycles for the paths in the T80 cpu
set_multicycle_path -from {emu|cpu|*} -setup 2
set_multicycle_path -from {emu|cpu|*} -hold 1

set_multicycle_path -to   {emu|cpu|*} -setup 2
set_multicycle_path -to   {emu|cpu|*} -hold 1

# The CE is only active in every 2 clocks, so allow 2 clock cycles
set_multicycle_path -from {emu|tape|*} -setup 2
set_multicycle_path -from {emu|tape|*} -hold 1

set_multicycle_path -from {emu|wd1793|sbuf|*} -setup 2
set_multicycle_path -from {emu|wd1793|sbuf|*} -hold 1
set_multicycle_path -from {emu|wd1793|edsk_rtl_0|*} -setup 2
set_multicycle_path -from {emu|wd1793|edsk_rtl_0|*} -hold 1
set_multicycle_path -from {emu|wd1793|layout_r*} -setup 2
set_multicycle_path -from {emu|wd1793|layout_r*} -hold 1
set_multicycle_path -from {emu|wd1793|disk_track*} -setup 2
set_multicycle_path -from {emu|wd1793|disk_track*} -hold 1
set_multicycle_path -from {emu|wd1793|edsk_addr*} -setup 2
set_multicycle_path -from {emu|wd1793|edsk_addr*} -hold 1
set_multicycle_path -to   {emu|wd1793|state[*]} -setup 2
set_multicycle_path -to   {emu|wd1793|state[*]} -hold 1
set_multicycle_path -to   {emu|wd1793|wait_time[*]} -setup 2
set_multicycle_path -to   {emu|wd1793|wait_time[*]} -hold 1

set_false_path -to {emu|wd1793|s_seekerr}

set_multicycle_path -from {emu|u765|sbuf|*} -setup 2
set_multicycle_path -from {emu|u765|sbuf|*} -hold 1
set_multicycle_path -from {emu|u765|image_track_offsets_rtl_0|*} -setup 2
set_multicycle_path -from {emu|u765|image_track_offsets_rtl_0|*} -hold 1
set_multicycle_path -to   {emu|u765|i_*} -setup 2
set_multicycle_path -to   {emu|u765|i_*} -hold 1
set_multicycle_path -to   {emu|u765|i_*[*]} -setup 2
set_multicycle_path -to   {emu|u765|i_*[*]} -hold 1
set_multicycle_path -to   {emu|u765|pcn[*]} -setup 2
set_multicycle_path -to   {emu|u765|pcn[*]} -hold 1
set_multicycle_path -to   {emu|u765|ncn[*]} -setup 2
set_multicycle_path -to   {emu|u765|ncn[*]} -hold 1
set_multicycle_path -to   {emu|u765|state[*]} -setup 2
set_multicycle_path -to   {emu|u765|state[*]} -hold 1
set_multicycle_path -to   {emu|u765|status[*]} -setup 2
set_multicycle_path -to   {emu|u765|status[*]} -hold 1
set_multicycle_path -to   {emu|u765|i_rpm_time[*][*][*]} -setup 8
set_multicycle_path -to   {emu|u765|i_rpm_time[*][*][*]} -hold 7

set_multicycle_path -from {emu|load} -setup 2
set_multicycle_path -from {emu|load} -hold 1

set_multicycle_path -to   {emu|turbosound|*} -setup 2
set_multicycle_path -to   {emu|turbosound|*} -hold 1
set_multicycle_path -to   {emu|saa1099|*} -setup 2
set_multicycle_path -to   {emu|saa1099|*} -hold 1

set_false_path -from {emu|init_reset}
set_false_path -from {emu|hps_io|cfg*}
set_false_path -from {emu|hps_io|status*}
set_false_path -from {emu|arch_reset}
set_false_path -from {emu|snap_loader|snap_reset}
set_false_path -from {emu|kbd|Fn*}
set_false_path -from {emu|kbd|mod*}
set_false_path -from {emu|plus3}
set_false_path -from {emu|zx48}
set_false_path -from {emu|p1024}
set_false_path -from {emu|pf1024}
set_false_path -from {emu|hps_io|status[*]}

# ---- rtl/ddr_cdc.sv: clk_sys <-> clk_aud (= clk_56m above) handshake ----
# req and ack are the two single-bit control signals of a four-phase
# request/acknowledge handshake (see rtl/ddr_cdc.sv), each landing on its own
# dedicated two-flop synchroniser (req_sync, ack_sync) in the receiving
# domain. The register driving each synchroniser chain is false-pathed
# exactly like the other slowly-changing control signals above
# (emu|snap_loader|snap_reset, emu|arch_reset, ...): metastability is
# resolved inside the synchroniser, and req/ack are each held for many
# cycles of both clocks, so no numeric setup/hold relationship into the
# first sync flop matters or should be enforced.
set_false_path -from {emu|ddr_cdc|req}
set_false_path -from {emu|ddr_cdc|ack}

# r_addr/r_din/r_we/r_rd are captured in clk_sys (client side) and read
# directly - with no synchroniser - by clk_aud (memory side) into
# m_addr/m_din/m_we/m_rd; d_lat is the mirror image, captured in clk_aud and
# read directly into clk_sys's `dout`. None of these six paths is safe
# because of timing: they are safe ONLY because the req/ack handshake above
# holds the source registers stable from well before req rises until after
# ack falls (ddr_cdc.sv notes 3-4), so the destination register always
# samples a value that has been stable for many cycles by the time it is
# read. False-path them so the fitter does not spend effort - or worse, skew
# individual bus bits onto different cycles - chasing a single-cycle bus
# relationship that provides no real protection and was never the actual
# safety mechanism.
set_false_path -from {emu|ddr_cdc|r_addr[*]} -to {emu|ddr_cdc|m_addr[*]}
set_false_path -from {emu|ddr_cdc|r_din[*]}  -to {emu|ddr_cdc|m_din[*]}
set_false_path -from {emu|ddr_cdc|r_we}      -to {emu|ddr_cdc|m_we}
set_false_path -from {emu|ddr_cdc|r_rd}      -to {emu|ddr_cdc|m_rd}
set_false_path -from {emu|ddr_cdc|d_lat[*]}  -to {emu|ddr_cdc|dout[*]}

# ---- rtl/sdram.sv `data` -> rtl/ss_writer.sv `rd_data` ----
# rtl/sdram.sv registers its read byte and `ready` together on the same edge
# (`{ready, data} <= {1'b1, SDRAM_DQ}`) and exposes it through the
# combinational byte mux `dout`. ss_writer used to latch rd_data <= ram_dout
# on the very cycle it first saw ram_ready high, putting the sdram `data`
# register, the mux, and the ss_writer `rd_data` register in a single
# clk_sys period - which stopped closing once savestate logic grew enough to
# separate them in placement. ss_writer now spends one extra idle cycle
# (ST_RDCAP) before registering rd_data, which it can afford for free
# because sdram.sv holds `data`/`dout` stable - and ss_writer does not
# re-issue ram_rd - until the next read is requested, several cycles later.
# The path is therefore genuinely two clk_sys cycles wide; tell TimeQuest so.
# NOTE: these patterns are SDC *instance-path* patterns - hierarchy segments
# separated by '|', each segment the instance label only (`ram`, `savestate`,
# `writer`), matching the -from {emu|cpu|*} etc. style used throughout this
# file. They are NOT TimeQuest's "report" naming (`entity:instance` per
# level, e.g. `sdram:ram`, `ss_writer:writer`), which is what this exception
# originally used. Report-format text silently matches zero nodes, and
# set_multicycle_path drops the whole exception with an easy-to-miss
# "Warning (332049): ... is not an object ID" instead of failing loudly - the
# path was quietly timed over one clk_sys period instead of two until this
# was caught with a TimeQuest path query. To make a future naming mistake
# fail loudly instead of silently, the endpoints are routed through
# get_registers, which errors out on an empty match instead of being ignored.
set_multicycle_path -from [get_registers {emu|ram|data[*]}] -to [get_registers {emu|savestate|writer|rd_data[*]}] -setup 2
set_multicycle_path -from [get_registers {emu|ram|data[*]}] -to [get_registers {emu|savestate|writer|rd_data[*]}] -hold 1

# `data` is only half of that path. rtl/sdram.sv:89 is
#   assign dout = save_addr[0] ? data[15:8] : data[7:0];
# so save_addr[0] is the SELECT of the mux sitting in the middle of the same
# register -> mux -> register path, and it is updated on the very same edge as
# `data` (rtl/sdram.sv:200-207). Without this pair TimeQuest timed the
# save_addr -> rd_data half over one clk_sys period while the design gives it
# two, so half the exception was doing nothing. Same instance-path naming and
# same get_registers wrapper as above, for the same reasons.
set_multicycle_path -from [get_registers {emu|ram|save_addr[*]}] -to [get_registers {emu|savestate|writer|rd_data[*]}] -setup 2
set_multicycle_path -from [get_registers {emu|ram|save_addr[*]}] -to [get_registers {emu|savestate|writer|rd_data[*]}] -hold 1
