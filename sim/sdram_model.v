// Behavioral model of the MT48LC16M16A2 (16Mbit, 16-bit, 2 banks) for Icarus sim.
// Matches how rtl/sdram.sv drives it:
//   commands decoded from {nRAS,nCAS,nWE} exactly like the controller's `command` reg:
//     ACTIVE=011 (A[12:0]=row, BA=bank)  READ=101 (A[5:0]=col)  WRITE=100 (A[5:0]=col)
//     PRECHARGE=010 AUTO_REFRESH=001 LOAD_MODE=000 NOP=111
//   CAS: chip decodes A[5:0] only (A[10:6] ignored -> aliasing)
//   write: DQML/DQMH = A[12:11] byte masks, DQ latched on the WRITE edge (same edge)
//   read:  full 16-bit word driven on DQ and HELD until the next command (like the chip);
//          the controller latches it CAS_LATENCY+1 posedges after READ issue.
module sdram_model (
    inout  wire [15:0] SDRAM_DQ,
    input  wire [12:0] SDRAM_A,
    input  wire        SDRAM_DQML,
    input  wire        SDRAM_DQMH,
    input  wire [1:0]  SDRAM_BA,
    input  wire        SDRAM_nCS,
    input  wire        SDRAM_nWE,
    input  wire        SDRAM_nRAS,
    input  wire        SDRAM_nCAS,
    input  wire        SDRAM_CKE,
    input  wire        SDRAM_CLK
);
    localparam ROWS = 8192;   // A[12:0]
    localparam COLS = 64;     // A[5:0]

    // flattened 2D array (iverilog has no 3D unpacked arrays)
    reg [15:0] mem [0:1][0:ROWS*COLS-1];

    reg [12:0] row_l = 0;
    reg        bank_l = 0;
    reg [15:0] rd_data = 0;
    reg        rd_hold = 0;

    integer b, i;
    initial begin
        for (b = 0; b < 2; b++)
            for (i = 0; i < ROWS*COLS; i++)
                mem[b][i] = 16'h0000;
    end

    // command encoding matches the controller's `command` reg, which holds the
    // active-low pin values directly: {nRAS,nCAS,nWE}
    wire [2:0] cmd = {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE};
    always @(posedge SDRAM_CLK) begin
        if (cmd === 3'b011) begin                       // ACTIVE
            row_l  <= SDRAM_A[12:0];
            bank_l <= SDRAM_BA[0];
        end
        else if (cmd === 3'b101) begin                  // READ
            rd_data <= mem[bank_l][{row_l, SDRAM_A[5:0]}];
            rd_hold <= 1'b1;
        end
        else if (cmd === 3'b100) begin                  // WRITE
            // single-cycle command: the chip latches DQ on this same edge, while the
            // controller still drives DQ and A[12:11] still carries the byte masks.
            if (!SDRAM_DQMH) mem[bank_l][{row_l, SDRAM_A[5:0]}][15:8] <= SDRAM_DQ[15:8];
            if (!SDRAM_DQML) mem[bank_l][{row_l, SDRAM_A[5:0]}][7:0]  <= SDRAM_DQ[7:0];
        end
        // any command other than NOP/READ drops the held read data (like the chip)
        if (cmd !== 3'b111 && cmd !== 3'b101) rd_hold <= 1'b0;
    end

    assign SDRAM_DQ = rd_hold ? rd_data : 16'bz;

endmodule
