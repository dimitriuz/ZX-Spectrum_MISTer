// Simulation model for rtl/pll.v (Altera PLL: 50MHz ref -> clk_sys 112MHz, clk_56 56MHz).
// Absolute frequencies are irrelevant in sim; what matters is that outclk_0/outclk_1 are
// free-running and phase-stable with outclk_1 = outclk_0 / 2 (CLK_VIDEO domain).
//
// Driven from refclk (no free-running `always #delay` loops: iverilog does not run them
// reliably, and un-initialized output regs invert X forever). Ratios in sim:
//   outclk_0 = refclk / 8, outclk_1 = refclk / 16.
module pll (
    input  refclk,
    input  rst,
    output outclk_0,
    output outclk_1,
    output locked
);
    reg [4:0] div = 5'd0;

    always @(posedge refclk) div <= div + 5'd1;

    assign outclk_0 = div[2];   // period 8 ref cycles  -> ref/8
    assign outclk_1 = div[3];   // period 16 ref cycles -> ref/16 = outclk_0/2

    assign locked = 1'b1;

endmodule
