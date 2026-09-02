// Simulation stand-in for the VHDL T80pa CPU (rtl/T80/).
// Behavioral fetch-loop Z80: 4-tick M1 cycles, PC increments, honors BUSRQ/BUSAK.
// No instruction execution, no interrupts — enough to exercise bus/SDRAM/memory-map
// logic in the Phase-1 tests. Replaced by a real CPU model for boot tests.
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
    input  HALT_n,
    output BUSAK_n,
    output [15:0] A,
    output [7:0] DO,
    input  [7:0] DI,
    output reg [211:0] REG,
    input  [211:0] DIR,
    input  DIRSet
);
    reg [15:0] pc = 0;
    reg [2:0] tick = 0;      // 4-tick instruction
    reg       halted = 0;
    reg       nmi_latch = 0; // NMI pending: vector to #0066 at the next M1

    always @(posedge CLK) begin
        if (!RESET_n) begin
            pc <= 16'h0000;
            tick <= 0;
            halted <= 0;
            nmi_latch <= 0;
        end else if (CEN_p) begin
            // NMI: latch while asserted. The core clears NMI on the vector M1 at
            // #0066, so a held key cannot re-arm before the vector is consumed.
            // (Set and clear below are mutually exclusive on tick==3.)
            if (!halted && !NMI_n && tick != 3) nmi_latch <= 1;
            if (!BUSRQ_n) begin
                // finish current tick group, then take the bus
                if (tick == 3) halted <= 1;
                else tick <= tick + 1;
            end else if (halted) begin
                if (BUSRQ_n) halted <= 0;   // release on deassert
            end else begin
                tick <= tick + 1;
                if (tick == 3) begin
                    pc <= nmi_latch ? 16'h0066 : pc + 1;
                    nmi_latch <= 0;         // consume the vector
                end
            end
        end
    end

    wire m1 = CEN_p & !halted & (tick == 0);

    assign M1_n   = ~m1;
    assign MREQ_n = ~(CEN_p & !halted);
    assign IORQ_n = 1'b1;
    assign RD_n   = m1;
    assign WR_n   = 1'b1;
    assign RFSH_n = 1'b1;
    assign BUSAK_n = ~halted;
    assign A      = pc;
    assign DO     = 8'h00;

endmodule
