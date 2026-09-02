// Simulation stand-in for the VHDL T80pa CPU (rtl/T80/): a REAL Z80 core.
// Wraps TV80 (hutch31/tv80, Verilog port of the T80 design; see sim/cpu/tv80/)
// behind the exact T80pa port list so it drops into the same instance in
// ZX-Spectrum.sv for boot testing. Sim-only — never used in FPGA builds.
//
// Clocking: the ULA derives ce_cpu_sp/sn from the 3.5 MHz CPU clock (ula.sv):
//   ce_cpu_sp = rising edge of CPUClk, ce_cpu_sn = falling edge (one 7 MHz
//   cycle wide each). We reconstruct the original CPUClk waveform so TV80
//   sees one posedge per T-state. When cpu_en gates both enables (BUSRQ /
//   turbo switch), the reconstructed clock freezes — CPU stops, as intended.
//
// Snapshot save/restore is NOT supported in this variant: REG is tied to 0
// and DIR/DIRSet are ignored (the boot test never saves or restores state).
module T80pa (
    input  RESET_n,
    input  CLK,
    input  CEN_p,
    input  CEN_n,
    input  WAIT_n,
    input  INT_n,
    input  NMI_n,
    input  BUSRQ_n,
    output M1_n,
    output MREQ_n,
    output IORQ_n,
    output RD_n,
    output WR_n,
    output RFSH_n,
    input  HALT_n,   // tied to 1 by the DUT; TV80 has no external halt input
    output BUSAK_n,
    output [15:0] A,
    output [7:0] DO,
    input  [7:0] DI,
    output [211:0] REG,
    input  [211:0] DIR,
    input  DIRSet
);
    // Reconstruct the 3.5 MHz CPU clock from the phase enables.
    reg tv80_clk = 1'b0;
    always @(posedge CLK) begin
        if (CEN_p)      tv80_clk <= 1'b1;
        else if (CEN_n) tv80_clk <= 1'b0;
    end

    wire [7:0] dout;
    wire       halt_unused;

    tv80s #(.Mode(0), .T2Write(1), .IOWait(1)) i_cpu (
        .reset_n(RESET_n),
        .clk(tv80_clk),
        .wait_n(WAIT_n),
        .int_n(INT_n),
        .nmi_n(NMI_n),
        .busrq_n(BUSRQ_n),
        .m1_n(M1_n),
        .mreq_n(MREQ_n),
        .iorq_n(IORQ_n),
        .rd_n(RD_n),
        .wr_n(WR_n),
        .rfsh_n(RFSH_n),
        .halt_n(halt_unused),
        .busak_n(BUSAK_n),
        .A(A),
        .di(DI),
        .dout(dout)
    );

    assign DO  = dout;
    assign REG = 212'd0;   // snapshot save unsupported in sim variant

endmodule
