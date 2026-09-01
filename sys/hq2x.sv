//
//
// Copyright (c) 2012-2013 Ludvig Strigeus
// Copyright (c) 2017,2018 Sorgelig
//
// This program is GPL Licensed. See COPYING for the full license.
//
//
////////////////////////////////////////////////////////////////////////////////////////////////////////

// altera message_off 10030

module Hq2x #(parameter LENGTH, parameter HALF_DEPTH)
(
	input             clk,

	input             ce_in,
	input  [DWIDTH:0] inputpixel,
	input             mono,
	input             disable_hq2x,
	input             reset_frame,
	input             reset_line,

	input             ce_out,
	input       [1:0] read_y,
	input             hblank,
	output [DWIDTH:0] outpixel
);


localparam AWIDTH = $clog2(LENGTH)-1;
localparam DWIDTH = HALF_DEPTH ? 11 : 23;
localparam DWIDTH1 = DWIDTH+1;

(* romstyle = "MLAB" *) reg [5:0] hqTable[256];
initial begin
	hqTable[0] = 19; hqTable[1] = 19; hqTable[2] = 26; hqTable[3] = 11;
	hqTable[4] = 19; hqTable[5] = 19; hqTable[6] = 26; hqTable[7] = 11;
	hqTable[8] = 23; hqTable[9] = 15; hqTable[10] = 47; hqTable[11] = 35;
	hqTable[12] = 23; hqTable[13] = 15; hqTable[14] = 55; hqTable[15] = 39;
	hqTable[16] = 19; hqTable[17] = 19; hqTable[18] = 26; hqTable[19] = 58;
	hqTable[20] = 19; hqTable[21] = 19; hqTable[22] = 26; hqTable[23] = 58;
	hqTable[24] = 23; hqTable[25] = 15; hqTable[26] = 35; hqTable[27] = 35;
	hqTable[28] = 23; hqTable[29] = 15; hqTable[30] = 7; hqTable[31] = 35;
	hqTable[32] = 19; hqTable[33] = 19; hqTable[34] = 26; hqTable[35] = 11;
	hqTable[36] = 19; hqTable[37] = 19; hqTable[38] = 26; hqTable[39] = 11;
	hqTable[40] = 23; hqTable[41] = 15; hqTable[42] = 55; hqTable[43] = 39;
	hqTable[44] = 23; hqTable[45] = 15; hqTable[46] = 51; hqTable[47] = 43;
	hqTable[48] = 19; hqTable[49] = 19; hqTable[50] = 26; hqTable[51] = 58;
	hqTable[52] = 19; hqTable[53] = 19; hqTable[54] = 26; hqTable[55] = 58;
	hqTable[56] = 23; hqTable[57] = 15; hqTable[58] = 51; hqTable[59] = 35;
	hqTable[60] = 23; hqTable[61] = 15; hqTable[62] = 7; hqTable[63] = 43;
	hqTable[64] = 19; hqTable[65] = 19; hqTable[66] = 26; hqTable[67] = 11;
	hqTable[68] = 19; hqTable[69] = 19; hqTable[70] = 26; hqTable[71] = 11;
	hqTable[72] = 23; hqTable[73] = 61; hqTable[74] = 35; hqTable[75] = 35;
	hqTable[76] = 23; hqTable[77] = 61; hqTable[78] = 51; hqTable[79] = 35;
	hqTable[80] = 19; hqTable[81] = 19; hqTable[82] = 26; hqTable[83] = 11;
	hqTable[84] = 19; hqTable[85] = 19; hqTable[86] = 26; hqTable[87] = 11;
	hqTable[88] = 23; hqTable[89] = 15; hqTable[90] = 51; hqTable[91] = 35;
	hqTable[92] = 23; hqTable[93] = 15; hqTable[94] = 51; hqTable[95] = 35;
	hqTable[96] = 19; hqTable[97] = 19; hqTable[98] = 26; hqTable[99] = 11;
	hqTable[100] = 19; hqTable[101] = 19; hqTable[102] = 26; hqTable[103] = 11;
	hqTable[104] = 23; hqTable[105] = 61; hqTable[106] = 7; hqTable[107] = 35;
	hqTable[108] = 23; hqTable[109] = 61; hqTable[110] = 7; hqTable[111] = 43;
	hqTable[112] = 19; hqTable[113] = 19; hqTable[114] = 26; hqTable[115] = 11;
	hqTable[116] = 19; hqTable[117] = 19; hqTable[118] = 26; hqTable[119] = 58;
	hqTable[120] = 23; hqTable[121] = 15; hqTable[122] = 51; hqTable[123] = 35;
	hqTable[124] = 23; hqTable[125] = 61; hqTable[126] = 7; hqTable[127] = 43;
	hqTable[128] = 19; hqTable[129] = 19; hqTable[130] = 26; hqTable[131] = 11;
	hqTable[132] = 19; hqTable[133] = 19; hqTable[134] = 26; hqTable[135] = 11;
	hqTable[136] = 23; hqTable[137] = 15; hqTable[138] = 47; hqTable[139] = 35;
	hqTable[140] = 23; hqTable[141] = 15; hqTable[142] = 55; hqTable[143] = 39;
	hqTable[144] = 19; hqTable[145] = 19; hqTable[146] = 26; hqTable[147] = 11;
	hqTable[148] = 19; hqTable[149] = 19; hqTable[150] = 26; hqTable[151] = 11;
	hqTable[152] = 23; hqTable[153] = 15; hqTable[154] = 51; hqTable[155] = 35;
	hqTable[156] = 23; hqTable[157] = 15; hqTable[158] = 51; hqTable[159] = 35;
	hqTable[160] = 19; hqTable[161] = 19; hqTable[162] = 26; hqTable[163] = 11;
	hqTable[164] = 19; hqTable[165] = 19; hqTable[166] = 26; hqTable[167] = 11;
	hqTable[168] = 23; hqTable[169] = 15; hqTable[170] = 55; hqTable[171] = 39;
	hqTable[172] = 23; hqTable[173] = 15; hqTable[174] = 51; hqTable[175] = 43;
	hqTable[176] = 19; hqTable[177] = 19; hqTable[178] = 26; hqTable[179] = 11;
	hqTable[180] = 19; hqTable[181] = 19; hqTable[182] = 26; hqTable[183] = 11;
	hqTable[184] = 23; hqTable[185] = 15; hqTable[186] = 51; hqTable[187] = 39;
	hqTable[188] = 23; hqTable[189] = 15; hqTable[190] = 7; hqTable[191] = 43;
	hqTable[192] = 19; hqTable[193] = 19; hqTable[194] = 26; hqTable[195] = 11;
	hqTable[196] = 19; hqTable[197] = 19; hqTable[198] = 26; hqTable[199] = 11;
	hqTable[200] = 23; hqTable[201] = 15; hqTable[202] = 51; hqTable[203] = 35;
	hqTable[204] = 23; hqTable[205] = 15; hqTable[206] = 51; hqTable[207] = 39;
	hqTable[208] = 19; hqTable[209] = 19; hqTable[210] = 26; hqTable[211] = 11;
	hqTable[212] = 19; hqTable[213] = 19; hqTable[214] = 26; hqTable[215] = 11;
	hqTable[216] = 23; hqTable[217] = 15; hqTable[218] = 51; hqTable[219] = 35;
	hqTable[220] = 23; hqTable[221] = 15; hqTable[222] = 7; hqTable[223] = 35;
	hqTable[224] = 19; hqTable[225] = 19; hqTable[226] = 26; hqTable[227] = 11;
	hqTable[228] = 19; hqTable[229] = 19; hqTable[230] = 26; hqTable[231] = 11;
	hqTable[232] = 23; hqTable[233] = 15; hqTable[234] = 51; hqTable[235] = 35;
	hqTable[236] = 23; hqTable[237] = 15; hqTable[238] = 7; hqTable[239] = 43;
	hqTable[240] = 19; hqTable[241] = 19; hqTable[242] = 26; hqTable[243] = 11;
	hqTable[244] = 19; hqTable[245] = 19; hqTable[246] = 26; hqTable[247] = 11;
	hqTable[248] = 23; hqTable[249] = 15; hqTable[250] = 7; hqTable[251] = 35;
	hqTable[252] = 23; hqTable[253] = 15; hqTable[254] = 7; hqTable[255] = 43;
end

wire [5:0] hqrule = hqTable[nextpatt];

reg [23:0] Prev0, Prev1, Prev2, Curr0, Curr1, Curr2, Next0, Next1, Next2;
reg [23:0] A, B, D, F, G, H;
reg  [7:0] pattern, nextpatt;
reg  [1:0] cyc;

reg  curbuf;
reg  prevbuf = 0;
wire iobuf = !curbuf;

wire diff0, diff1;
DiffCheck diffcheck0(Curr1, (cyc == 0) ? Prev0 : (cyc == 1) ? Curr0 : (cyc == 2) ? Prev2 : Next1, diff0);
DiffCheck diffcheck1(Curr1, (cyc == 0) ? Prev1 : (cyc == 1) ? Next0 : (cyc == 2) ? Curr2 : Next2, diff1);

wire [7:0] new_pattern = {diff1, diff0, pattern[7:2]};

wire [23:0] X = (cyc == 0) ? A : (cyc == 1) ? Prev1 : (cyc == 2) ? Next1 : G;
wire [23:0] blend_result_pre;
Blend blender(clk, ce_in, disable_hq2x ? 6'd0 : hqrule, Curr0, X, B, D, F, H, blend_result_pre);

wire [DWIDTH:0] Curr20tmp;
wire     [23:0] Curr20 = HALF_DEPTH ? h2rgb(Curr20tmp) : Curr20tmp;
wire [DWIDTH:0] Curr21tmp;
wire     [23:0] Curr21 = HALF_DEPTH ? h2rgb(Curr21tmp) : Curr21tmp;

reg  [AWIDTH:0] wrin_addr2;
reg  [DWIDTH:0] wrpix;
reg             wrin_en;

function [23:0] h2rgb;
	input [11:0] v;
begin
	h2rgb = mono ? {v[7:0], v[7:0], v[7:0]} : {v[11:8],v[11:8],v[7:4],v[7:4],v[3:0],v[3:0]};
end
endfunction

function [11:0] rgb2h;
	input [23:0] v;
begin
	rgb2h = mono ? {4'b0000, v[23:20], v[19:16]} : {v[23:20], v[15:12], v[7:4]};
end
endfunction

hq2x_in #(.LENGTH(LENGTH), .DWIDTH(DWIDTH)) hq2x_in
(
	.clk(clk),

	.rdaddr(offs),
	.rdbuf0(prevbuf),
	.rdbuf1(curbuf),
	.q0(Curr20tmp),
	.q1(Curr21tmp),

	.wraddr(wrin_addr2),
	.wrbuf(iobuf),
	.data(wrpix),
	.wren(wrin_en)
);

reg     [AWIDTH+1:0] read_x;
reg     [AWIDTH+1:0] wrout_addr; 
reg                  wrout_en;
reg  [DWIDTH1*4-1:0] wrdata, wrdata_pre;
wire [DWIDTH1*4-1:0] outpixel_x4;
reg  [DWIDTH1*2-1:0] outpixel_x2;

assign outpixel = read_x[0] ? outpixel_x2[DWIDTH1*2-1:DWIDTH1] : outpixel_x2[DWIDTH:0];

hq2x_buf #(.NUMWORDS(LENGTH*2), .AWIDTH(AWIDTH+1), .DWIDTH(DWIDTH1*4-1)) hq2x_out
(
	.clock(clk),

	.rdaddress({read_x[AWIDTH+1:1],read_y[1]}),
	.q(outpixel_x4),

	.data(wrdata),
	.wraddress(wrout_addr),
	.wren(wrout_en)
);

always @(posedge clk) begin
	if(ce_out) begin
		if(read_x[0]) outpixel_x2 <= read_y[0] ? outpixel_x4[DWIDTH1*4-1:DWIDTH1*2] : outpixel_x4[DWIDTH1*2-1:0];
		if(~hblank & ~&read_x) read_x <= read_x + 1'd1;
		if(hblank) read_x <= 0;
	end
end

wire [DWIDTH:0] blend_result = HALF_DEPTH ? rgb2h(blend_result_pre) : blend_result_pre[DWIDTH:0];

reg [AWIDTH:0] offs;
always @(posedge clk) begin
	reg old_reset_line;
	reg old_reset_frame;
	reg [3:0] wrdata_finished;
	reg [AWIDTH+1:0] waddr; 

	wrout_en <= 0;
	wrin_en  <= 0;

	if(ce_in) begin

		// blend_result has been delayed by 4 cycles
		case(cyc)
			0: wrdata[DWIDTH:0]                   <= blend_result;
			1: wrdata[DWIDTH1+DWIDTH:DWIDTH1]     <= blend_result;
			2: wrdata[DWIDTH1*3+DWIDTH:DWIDTH1*3] <= blend_result;
			3: wrdata[DWIDTH1*2+DWIDTH:DWIDTH1*2] <= blend_result;
		endcase

		wrdata_finished <= wrdata_finished << 1;
		if(wrdata_finished[3]) begin
			wrout_en <= 1;
			wrout_addr <= waddr;
		end

		if(~&offs) begin
			if (cyc == 1) begin
				Prev2 <= Curr20;
				Curr2 <= Curr21;
				Next2 <= HALF_DEPTH ? h2rgb(inputpixel) : inputpixel;
				wrpix <= inputpixel;
				wrin_addr2 <= offs;
				wrin_en <= 1;
			end

			if(cyc==3) begin
				offs <= offs + 1'd1;
				waddr <= {offs, curbuf};
				wrdata_finished[0] <= 1;
			end
		end

		pattern <= new_pattern;
		if(cyc==3) begin
			nextpatt <= {new_pattern[7:6], new_pattern[3], new_pattern[5], new_pattern[2], new_pattern[4], new_pattern[1:0]};
			{A, G} <= {Prev0, Next0};
			{B, F, H, D} <= {Prev1, Curr2, Next1, Curr0};
			{Prev0, Prev1} <= {Prev1, Prev2};
			{Curr0, Curr1} <= {Curr1, Curr2};
			{Next0, Next1} <= {Next1, Next2};
		end else begin
			nextpatt <= {nextpatt[5], nextpatt[3], nextpatt[0], nextpatt[6], nextpatt[1], nextpatt[7], nextpatt[4], nextpatt[2]};
			{B, F, H, D} <= {F, H, D, B};
		end

		cyc <= cyc + 1'b1;
		if(old_reset_line && ~reset_line) begin
			old_reset_frame <= reset_frame;
			offs <= 0;
			cyc <= 0;
			curbuf <= ~curbuf;
			prevbuf <= curbuf;
			{Prev0, Prev1, Prev2, Curr0, Curr1, Curr2, Next0, Next1, Next2} <= '0;
			if(old_reset_frame & ~reset_frame) begin
				curbuf <= 0;
				prevbuf <= 0;
			end
		end
		
		old_reset_line  <= reset_line;
	end
end

endmodule

////////////////////////////////////////////////////////////////////////////////////////////////////////

module hq2x_in #(parameter LENGTH, parameter DWIDTH)
(
	input            clk,

	input [AWIDTH:0] rdaddr,
	input            rdbuf0, rdbuf1,
	output[DWIDTH:0] q0,q1,

	input [AWIDTH:0] wraddr,
	input            wrbuf,
	input [DWIDTH:0] data,
	input            wren
);

localparam AWIDTH = $clog2(LENGTH)-1;
wire  [DWIDTH:0] out[2];
assign q0 = out[rdbuf0];
assign q1 = out[rdbuf1];

hq2x_buf #(.NUMWORDS(LENGTH), .AWIDTH(AWIDTH), .DWIDTH(DWIDTH)) buf0(clk,data,rdaddr,wraddr,wren && (wrbuf == 0),out[0]);
hq2x_buf #(.NUMWORDS(LENGTH), .AWIDTH(AWIDTH), .DWIDTH(DWIDTH)) buf1(clk,data,rdaddr,wraddr,wren && (wrbuf == 1),out[1]);

endmodule

module hq2x_buf #(parameter NUMWORDS, parameter AWIDTH, parameter DWIDTH)
(
	input                 clock,
	input      [DWIDTH:0] data,
	input      [AWIDTH:0] rdaddress,
	input      [AWIDTH:0] wraddress,
	input                 wren,
	output reg [DWIDTH:0] q
);

reg [DWIDTH:0] ram[0:NUMWORDS-1];

always_ff@(posedge clock) begin
	if(wren) ram[wraddress] <= data;
	q <= ram[rdaddress];
end

endmodule

////////////////////////////////////////////////////////////////////////////////////////////////////////

module DiffCheck
(
	input [23:0] rgb1,
	input [23:0] rgb2,
	output       result
);

	wire [7:0] r = rgb1[7:1]   - rgb2[7:1];
	wire [7:0] g = rgb1[15:9]  - rgb2[15:9];
	wire [7:0] b = rgb1[23:17] - rgb2[23:17];
	wire [8:0] t = $signed(r) + $signed(b);
	wire [9:0] y = $signed(t) + $signed({g[7], g});
	wire [8:0] u = $signed(r) - $signed(b);
	wire [9:0] v = $signed({g, 1'b0}) - $signed(t);

	// if y is inside (-96..96)
	wire y_inside = (y < 10'h60 || y >= 10'h3a0);

	// if u is inside (-16, 16)
	wire u_inside = (!u[8:4] || &u[8:4]); //(u < 9'h10 || u >= 9'h1f0);

	// if v is inside (-24, 24)
	wire v_inside = (v < 10'h18 || v >= 10'h3e8);
	assign result = !(y_inside && u_inside && v_inside);

endmodule

module Blend
(
	input         clk,
	input         clk_en,
	input   [5:0] rule,
	input  [23:0] E,
	input  [23:0] A,
	input  [23:0] B,
	input  [23:0] D,
	input  [23:0] F,
	input  [23:0] H,
	output reg [23:0] Result
);

	localparam BLEND1 = 7'b110_10_00; // (A * 12 + B * 4        ) >> 4
	localparam BLEND2 = 7'b100_10_10; // (A *  8 + B * 4 + C * 4) >> 4
	localparam BLEND3 = 7'b101_10_01; // (A * 10 + B * 4 + C * 2) >> 4
	localparam BLEND4 = 7'b110_01_01; // (A * 12 + B * 2 + C * 2) >> 4
	localparam BLEND5 = 7'b010_11_11; // (A *  4 + B * 6 + C * 6) >> 4
	localparam BLEND6 = 7'b111_00_00; // (A * 14 + B * 1 + C * 1) >> 4

	reg [23:0] a,b,d,e,h,f;
	reg  [3:0] bl_rule;
	reg  [1:0] df_rule;
	always @(posedge clk) if (clk_en) begin
		{bl_rule,df_rule} <= rule;
		a <= A; b <= B; d <= D; e <= E; f <= F; h <= H;
	end

	wire is_diff;
	DiffCheck diff_checker(df_rule[1] ? b : h, df_rule[0] ? d : f, is_diff);

	reg [23:0] i10,i20,i30;
	reg  [6:0] op0;
	always @(posedge clk) if (clk_en) begin
		i10 <= e;
		case({!is_diff, bl_rule})
		1,11,12,13,17: {op0, i20, i30} <= {BLEND1, a, 24'd0};
		      2,14,18: {op0, i20, i30} <= {BLEND1, d, 24'd0};
		      3,15,19: {op0, i20, i30} <= {BLEND1, b, 24'd0};
			4,20,24,27: {op0, i20, i30} <= {BLEND2, d, b};
			      5,21: {op0, i20, i30} <= {BLEND2, a, b};
			      6,22: {op0, i20, i30} <= {BLEND2, a, d};
		        25,29: {op0, i20, i30} <= {BLEND5, d, b};
			        26: {op0, i20, i30} <= {BLEND6, d, b};
			        28: {op0, i20, i30} <= {BLEND4, d, b};
			        30: {op0, i20, i30} <= {BLEND3, b, d};
			        31: {op0, i20, i30} <= {BLEND3, d, b};
		      default: {op0, i20, i30} <= {BLEND1, e, 24'd0}; 
		endcase
	end

	reg [23:0] i1,i2,i3;
	reg  [6:0] op;
	always @(posedge clk) if (clk_en) begin
		op <= op0; i1 <= i10; i2 <= i20; i3 <= i30;
	end

	function  [34:0] mul24x3;
		input  [23:0] op1;
		input   [2:0] op2;
	begin
		mul24x3 = 0;
		if(op2[0]) mul24x3 = mul24x3 + {op1[23:16], 4'b0000, op1[15:8], 4'b0000, op1[7:0]};
		if(op2[1]) mul24x3 = mul24x3 + {op1[23:16], 4'b0000, op1[15:8], 4'b0000, op1[7:0], 1'b0};
		if(op2[2]) mul24x3 = mul24x3 + {op1[23:16], 4'b0000, op1[15:8], 4'b0000, op1[7:0], 2'b00};
	end
	endfunction

	wire [35:0] res = {mul24x3(i1, op[6:4]), 1'b0} + mul24x3(i2, {op[3:2], !op[3:2]}) + mul24x3(i3, {op[1:0], !op[3:2]});

	always @(posedge clk) if (clk_en) Result <= {res[35:28],res[23:16],res[11:4]};

endmodule
