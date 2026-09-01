// Simulation stand-in for the VHDL tzxplayer (rtl/tzxplayer.vhd).
// TZX playback is out of scope for the current test set: no loop points,
// silent cassette output. tzx_req/tzx_ack are edge-handshaked by tape.sv.
module tzxplayer #(parameter TZX_MS = 3500) (
    input             clk,
    input             ce,
    input             tzx_req,
    input             tzx_ack,
    output            loop_start,
    output            loop_next,
    input             stop,
    input             stop48k,
    input             restart_tape,
    input             restart_block,
    input             skip_block,
    input             new_block,
    input      [7:0]  host_tap_in,
    output            cass_read,
    input             cass_motor
);
    assign loop_start = 1'b0;
    assign loop_next  = 1'b0;
    assign cass_read  = 1'b0;

endmodule
