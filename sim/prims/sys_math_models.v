// Simulation models for the MiSTer sys library math units (sys_umul, sys_udiv),
// which are provided by the shared MiSTer/sys tree at Quartus build time.
// Behavioral: result valid one cycle after load; run pulses high during that cycle.
`timescale 1ns / 1ps

module sys_umul #(parameter PREC1 = 32, parameter PREC2 = 32) (
    input clk,
    input load,
    output reg run,
    input  [PREC1-1:0] a,
    input  [PREC2-1:0] b,
    output reg [PREC1+PREC2-1:0] result
);
    always @(posedge clk) begin
        if (load) begin
            run    <= 1'b1;
            result <= a * b;
        end else begin
            run <= 1'b0;
        end
    end
endmodule

module sys_udiv #(parameter PREC1 = 32, parameter PREC2 = 32) (
    input clk,
    input load,
    output reg run,
    input  [PREC1-1:0] a,
    input  [PREC2-1:0] b,
    output reg [PREC1-1:0] result
);
    always @(posedge clk) begin
        if (load) begin
            run    <= 1'b1;
            result <= (b != 0) ? a / b : {PREC1{1'b0}};
        end else begin
            run <= 1'b0;
        end
    end
endmodule
