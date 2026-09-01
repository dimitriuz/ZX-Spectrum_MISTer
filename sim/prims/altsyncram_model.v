// Behavioral model of the altsyncram megafunction as configured by rtl/dpram.v:
// BIDIR_DUAL_PORT, both ports on clock0, unregistered outputs, no byte-enable granularity.
// Ports are declared wide; Verilog connection rules truncate to the actual widths.
module altsyncram (
    input  [31:0] address_a,
    input  [31:0] address_b,
    input         clock0,
    input  [63:0] data_a,
    input  [63:0] data_b,
    input         wren_a,
    input         wren_b,
    output reg [63:0] q_a,
    output reg [63:0] q_b,
    input         aclr0,
    input         aclr1,
    input         addressstall_a,
    input         addressstall_b,
    input  [7:0]  byteena_a,
    input  [7:0]  byteena_b,
    input         clock1,
    input         clocken0,
    input         clocken1,
    input         clocken2,
    input         clocken3,
    output reg [3:0] eccstatus,
    input         rden_a,
    input         rden_b
);
    // parameters set by defparam in rtl/dpram.v (accepted and ignored)
    parameter wrcontrol_wraddress_reg_b = "CLOCK0";
    parameter address_reg_b             = "CLOCK0";
    parameter indata_reg_b              = "CLOCK0";
    parameter numwords_a                = 256;
    parameter numwords_b                = 256;
    parameter widthad_a                 = 8;
    parameter widthad_b                 = 8;
    parameter width_a                   = 8;
    parameter width_b                   = 8;
    parameter width_byteena_a           = 1;
    parameter width_byteena_b           = 1;
    parameter init_file                 = "";
    parameter clock_enable_input_a      = "BYPASS";
    parameter clock_enable_input_b      = "BYPASS";
    parameter clock_enable_output_a     = "BYPASS";
    parameter clock_enable_output_b     = "BYPASS";
    parameter intended_device_family    = "";
    parameter lpm_type                  = "altsyncram";
    parameter operation_mode            = "BIDIR_DUAL_PORT";
    parameter outdata_aclr_a            = "NONE";
    parameter outdata_aclr_b            = "NONE";
    parameter outdata_reg_a             = "UNREGISTERED";
    parameter outdata_reg_b             = "UNREGISTERED";
    parameter power_up_uninitialized    = "FALSE";
    parameter read_during_write_mode_mixed_ports = "DONT_CARE";
    parameter read_during_write_mode_port_a      = "NEW_DATA_NO_NBE_READ";
    parameter read_during_write_mode_port_b      = "NEW_DATA_NO_NBE_READ";

    localparam DEPTH = 65536;   // covers ADDRWIDTH up to 16 (this design uses <= 15)

    reg [63:0] mem [0:DEPTH-1];

    integer i;
    initial begin
        for (i = 0; i < DEPTH; i++) mem[i] = 64'h0;
        eccstatus = 4'h0;
    end

    always @(posedge clock0) begin
        if (wren_a) mem[address_a[15:0]] <= data_a;
        if (wren_b) mem[address_b[15:0]] <= data_b;
    end

    // unregistered reads
    always @* begin
        q_a = mem[address_a[15:0]];
        q_b = mem[address_b[15:0]];
    end

endmodule
