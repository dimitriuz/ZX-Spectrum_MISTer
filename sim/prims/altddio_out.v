// Behavioral model of the altddio_out primitive (used by rtl/sdram.sv to generate SDRAM_CLK).
// DDR output: datain_h on posedge outclock, datain_l on negedge.
module altddio_out #(
    parameter extend_oe_disable = "OFF",
    parameter intended_device_family = "",
    parameter invert_output = "OFF",
    parameter lpm_hint = "UNUSED",
    parameter lpm_type = "altddio_out",
    parameter oe_reg = "UNREGISTERED",
    parameter power_up_high = "OFF",
    parameter width = 1
) (
    input  datain_h,
    input  datain_l,
    input  outclock,
    output reg dataout,
    input  aclr,
    input  aset,
    input  oe,
    input  outclocken,
    input  sclr,
    input  sset
);
    initial dataout = 0;

    always @(posedge outclock) if (oe) dataout <= datain_h;
    always @(negedge outclock) if (oe) dataout <= datain_l;

endmodule
