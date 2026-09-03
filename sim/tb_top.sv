// Testbench for the ZX Spectrum MiSTer core (Scorpion ZS-256 development).
// - Replaces sys/hps_io with sim/host_model.v (TB drives dut.hps_io.tb_* hierarchically)
// - Models the SDRAM chip (sim/sdram_model.v), PLL and Altera prims (sim/prims/)
// - Select test: ghdl run work -- TEST=<name>   ($value$plusargs)
`timescale 1ns / 1ps

module tb_top;

    reg clk_50 = 0;
    always #10 clk_50 = ~clk_50;      // 50 MHz reference (absolute rate irrelevant in sim)

    wire [45:0] hps_bus;
    wire [15:0] sd_dq;
    wire        sdr_clk, sdr_cke;
    wire [12:0] sdr_a;
    wire [1:0]  sdr_ba;
    wire [3:0] adc_bus;   // left undriven (high-impedance)
    wire        sdr_dqml, sdr_dqmh, sdr_ncs, sdr_ncas, sdr_nras, sdr_nwe;

    emu dut (
        .CLK_50M(clk_50),
        .RESET(1'b0),
        .HPS_BUS(hps_bus),
        .CLK_VIDEO(), .CE_PIXEL(),
        .VIDEO_ARX(), .VIDEO_ARY(),
        .VGA_R(), .VGA_G(), .VGA_B(), .VGA_HS(), .VGA_VS(), .VGA_DE(),
        .VGA_F1(), .VGA_SL(), .VGA_SCALER(), .VGA_DISABLE(),
        .HDMI_WIDTH(12'd1920), .HDMI_HEIGHT(12'd1080),
        .LED_USER(), .LED_POWER(), .LED_DISK(), .BUTTONS(),
        .CLK_AUDIO(clk_50), .AUDIO_L(), .AUDIO_R(), .AUDIO_S(), .AUDIO_MIX(),
        .ADC_BUS(adc_bus),
        .SD_SCK(), .SD_MOSI(), .SD_MISO(1'b0), .SD_CS(), .SD_CD(1'b1),
        .DDRAM_CLK(), .DDRAM_BUSY(1'b0), .DDRAM_BURSTCNT(), .DDRAM_ADDR(),
        .DDRAM_DOUT(64'd0), .DDRAM_DOUT_READY(1'b1),
        .DDRAM_RD(), .DDRAM_DIN(), .DDRAM_BE(), .DDRAM_WE(),
        .SDRAM_CLK(sdr_clk), .SDRAM_CKE(sdr_cke), .SDRAM_A(sdr_a), .SDRAM_BA(sdr_ba),
        .SDRAM_DQ(sd_dq), .SDRAM_DQML(sdr_dqml), .SDRAM_DQMH(sdr_dqmh),
        .SDRAM_nCS(sdr_ncs), .SDRAM_nCAS(sdr_ncas), .SDRAM_nRAS(sdr_nras), .SDRAM_nWE(sdr_nwe),
        .UART_CTS(1'b0), .UART_RTS(), .UART_RXD(1'b0), .UART_TXD(), .UART_DTR(), .UART_DSR(1'b0),
        .USER_IN(7'd0), .USER_OUT(),
        .OSD_STATUS(1'b0)
    );

    sdram_model sdr (
        .SDRAM_DQ(sd_dq), .SDRAM_A(sdr_a), .SDRAM_DQML(sdr_dqml), .SDRAM_DQMH(sdr_dqmh),
        .SDRAM_BA(sdr_ba), .SDRAM_nCS(sdr_ncs), .SDRAM_nWE(sdr_nwe),
        .SDRAM_nRAS(sdr_nras), .SDRAM_nCAS(sdr_ncas), .SDRAM_CKE(sdr_cke), .SDRAM_CLK(sdr_clk)
    );

    wire tb_clksys;
    assign tb_clksys = dut.clk_sys;



    // ------------------------------------------------------------------
    // TB helpers (hierarchical drives into the hps_io stub + DUT internals)
    // ------------------------------------------------------------------

    // OSD machine word for Scorpion ZS-256 (status[12:10] = 5). Downloads must hold
    // this word while reset is asserted, or the core re-samples the machine flag and
    // leaves Scorpion mode.
    localparam [63:0] M_SCORP = {51'b0, 3'd5, 10'b0};

    task set_status(input [63:0] v);
        begin
            dut.hps_io.tb_status = v;
            repeat (4) @(posedge tb_clksys);
        end
    endtask

    // Pulse the core reset (OSD status bit 0) while holding `v` as the machine word
    task machine_reset(input [63:0] v);
        begin
            dut.hps_io.tb_status = v;
            repeat (10) @(posedge tb_clksys);
            dut.hps_io.tb_status = v | 64'h1;      // status[0] = Reset & Apply
            repeat (50) @(posedge tb_clksys);
            dut.hps_io.tb_status = v;
            repeat (20) @(posedge tb_clksys);
        end
    endtask

    // Wait for the SDRAM controller to finish its startup/refresh sequence
    // (~12100 clk_sys cycles ~= 1.9 ms sim time, once per simulation run; the PLL
    // model holds `locked` high so machine resets do not restart it). Until then it
    // accepts no accesses and ready is X.
    task wait_sdr_up;
        integer i;
        begin
            i = 0;
            while (dut.ram_ready !== 1'b1 && i < 50000) begin
                @(posedge tb_clksys);
                i = i + 1;
            end
            if (dut.ram_ready !== 1'b1) begin
                $display("wait_sdr_up: TIMEOUT");
                $finish;
            end
        end
    endtask
    // Host download flows exactly like the real HPS: the core holds the CPU in reset
    // while a download is active, because load = (reset | ~nBUSACK) & ioctl_download.
    // Asserting BUSRQ on its own is NOT sufficient: snap_loader raises snap_reset on
    // every download start, which cold-resets the machine and the CPU can never take
    // the bus to answer BUSRQ while held in reset. So: reset first, then download.
    task start_download(input [63:0] machine);
        begin
            dut.hps_io.tb_status = machine | 64'h1;   // hold core reset (status[0])
            wait_sdr_up;                              // SDRAM must be up before streaming
            repeat (50) @(posedge tb_clksys);
            dut.hps_io.tb_ioctl_download_d = 1'b1;
            repeat (4) @(posedge tb_clksys);
        end
    endtask

    task stop_download(input [63:0] machine);
        begin
            dut.hps_io.tb_ioctl_download_d = 1'b0;
            repeat (4) @(posedge tb_clksys);
            dut.hps_io.tb_status = machine;           // release reset -> CPU boots
            repeat (20) @(posedge tb_clksys);
        end
    endtask

    // Stream one byte of a host download (index 0, boot.rom path). Requires an active
    // download window (start_download). The strobe must be held across a full clk_sys
    // cycle: the TB resumes in the same active region as the DUT's sampling edge, so a
    // one-cycle pulse can race and be missed. The 8-cycle tail lets the SDRAM
    // controller finish the access before the next write is latched.
    task write_rom_byte(input [23:0] off, input [7:0] d);
        begin
            dut.hps_io.tb_ioctl_index_d = 8'd0;
            dut.hps_io.tb_ioctl_addr_d  = {1'b0, off};
            dut.hps_io.tb_ioctl_dout_d  = d;
            dut.hps_io.tb_ioctl_wr_d    = 1'b1;
            repeat (2) @(posedge tb_clksys);
            dut.hps_io.tb_ioctl_wr_d    = 1'b0;
            repeat (8) @(posedge tb_clksys);
        end
    endtask

    // Load a file (hex) through the real host download path, index 0.
    task load_rom_file(input [63:0] machine, input [255:0] hexpath, input integer nbytes);
        reg [7:0] rom [0:262143];
        integer i;
        begin
            $readmemh(hexpath, rom);
            start_download(machine);
            for (i = 0; i < nbytes; i++) write_rom_byte(i[23:0], rom[i]);
            stop_download(machine);
            $display("loaded %0d bytes from %0s", i, hexpath);
        end
    endtask

    // Load a byte range of a hex file through the real host download path.
    task load_rom_range(input [63:0] machine, input [255:0] hexpath, input integer off_start, input integer count);
        reg [7:0] rom [0:262143];
        integer i, off;
        begin
            $readmemh(hexpath, rom);
            start_download(machine);
            for (i = 0; i < count; i++) begin
                off = off_start + i;
                write_rom_byte(off[23:0], rom[off]);
            end
            stop_download(machine);
            $display("loaded %0d bytes from %0s @%h", i, hexpath, off_start);
        end
    endtask

    // Stream one byte of a snapshot download (ioctl index 4). The snap_loader
    // state machine advances on EVERY cycle ioctl_wr is high, so the strobe must
    // be sampled for exactly one clk_sys: set it strictly between edges (#1), let
    // one edge sample it, clear it before the next.
    //
    // Pacing: the SDRAM controller needs ~5 cycles per access and only latches a
    // write request while idle - a second we edge before the pending one is
    // consumed overwrites it (data loss). The loader's snap_wr is registered one
    // cycle after the sampling edge, so "ram_ready is high right now" does NOT
    // mean the previous byte's access is done. Robust protocol: after strobing,
    // wait for ready to FALL (this byte's we edge), then RISE again (access
    // issued), then settle 3 more edges (IDLE_2 -> IDLE_1 -> IDLE) so the next
    // we edge always lands on an idle controller. Header bytes produce no write,
    // so ready never falls - bail out of the fall-wait after a few edges.
    task write_snap_byte(input [23:0] off, input [7:0] d);
        integer i;
        integer f;
        begin
            #1;                                   // strictly between edges: no sampling race
            dut.hps_io.tb_ioctl_addr_d = {1'b0, off};
            dut.hps_io.tb_ioctl_dout_d = d;
            dut.hps_io.tb_ioctl_wr_d   = 1'b1;
            @(posedge tb_clksys);                 // the one cycle the loader samples this byte
            #1;
            dut.hps_io.tb_ioctl_wr_d   = 1'b0;
            f = 0;
            while (dut.ram_ready === 1'b1 && f < 8) begin @(posedge tb_clksys); f = f + 1; end
            if (f < 8) begin
                i = 0;
                while (dut.ram_ready !== 1'b1 && i < 128) begin @(posedge tb_clksys); i = i + 1; end
                repeat (3) @(posedge tb_clksys);  // settle to IDLE before the next we edge
            end else i = 0;
        end
    endtask

    // Write one byte directly into SDRAM (bypasses CPU/host paths). Works while
    // the CPU stub is active: pin nMREQ high so no CPU read edge can race ours,
    // wait for the controller to be idle, issue a clean we edge, wait for done.
    task sdram_write(input [24:0] la, input [7:0] d);
        integer i;
        begin
            force dut.nMREQ = 1'b1;
            i = 0;
            while ((dut.ram_ready !== 1'b1 || dut.ram_rd === 1'b1) && i < 64) begin
                @(posedge tb_clksys);
                i = i + 1;
            end
            force dut.ram_addr = la;
            force dut.ram_din  = d;
            force dut.ram_we   = 1'b1;
            repeat (2) @(posedge tb_clksys);
            force dut.ram_we   = 1'b0;
            i = 0;
            while (dut.ram_ready !== 1'b1 && i < 64) begin
                @(posedge tb_clksys);
                i = i + 1;
            end
            release dut.ram_we;
            release dut.ram_din;
            release dut.ram_addr;
            release dut.nMREQ;
            repeat (8) @(posedge tb_clksys);
        end
    endtask

    // Pin the combinational page_rom decode to a value (hierarchical force).
    task set_rom_page(input [3:0] p);
        begin
            force dut.page_rom = p;
            repeat (2) @(posedge tb_clksys);
        end
    endtask

    // CPU I/O port write: force the bus like a Z80 OUT cycle. Holds nM1 high so
    // io_wr can fire regardless of the stub's tick phase; the handler latches on
    // the first sampled edge (io_wr & ~old_wr).
    task io_write(input [15:0] a, input [7:0] v);
        begin
            force dut.nM1   = 1'b1;
            force dut.nIORQ = 1'b0;
            force dut.nWR   = 1'b0;
            force dut.addr  = a;
            force dut.cpu_dout = v;
            repeat (8) @(posedge tb_clksys);
            force dut.nWR   = 1'b1;
            force dut.nIORQ = 1'b1;
            release dut.cpu_dout;
            release dut.addr;
            release dut.nM1;
            repeat (4) @(posedge tb_clksys);
        end
    endtask

    // CPU memory read at address a: force the bus like a Z80 M-cycle. Pin nMREQ
    // high first so no stub read edge can race ours, wait for the controller to
    // be idle, then issue the read and sample cpu_din when ready rises (data latch).
    task cpu_read(input [15:0] a, output [7:0] d);
        integer i;
        begin
            force dut.nMREQ = 1'b1;
            i = 0;
            while ((dut.ram_ready !== 1'b1 || dut.ram_rd === 1'b1) && i < 64) begin
                @(posedge tb_clksys);
                i = i + 1;
            end
            force dut.nM1   = 1'b1;
            force dut.addr  = a;
            force dut.nRD   = 1'b0;
            force dut.nMREQ = 1'b0;
            d = 8'hxx;
            i = 0;
            while (dut.ram_ready !== 1'b0 && i < 32) begin
                @(posedge tb_clksys);
                i = i + 1;
            end
            i = 0;
            while (dut.ram_ready !== 1'b1 && i < 64) begin
                @(posedge tb_clksys);
                i = i + 1;
            end
            d = dut.cpu_din;
            force dut.nMREQ = 1'b1;
            force dut.nRD   = 1'b1;
            release dut.addr;
            release dut.nM1;
            repeat (8) @(posedge tb_clksys);
        end
    endtask
    // CPU I/O read at port a: force the bus like a Z80 IORQ read cycle.
    task io_read(input [15:0] a, output [7:0] d);
        integer i;
        begin
            force dut.nMREQ = 1'b1;
            repeat (4) @(posedge tb_clksys);
            force dut.nM1   = 1'b1;
            force dut.nIORQ = 1'b0;
            force dut.nRD   = 1'b0;
            force dut.addr  = a;
            d = 8'hxx;
            repeat (4) @(posedge tb_clksys);
            d = dut.cpu_din;
            force dut.nRD   = 1'b1;
            force dut.nIORQ = 1'b1;
            release dut.addr;
            release dut.nM1;
            repeat (8) @(posedge tb_clksys);
        end
    endtask
    // Force one M1 fetch cycle at address a (used to trigger M1-edge latches such as
    // trdos_en, which the fetch-loop stub never reaches on its own).
    task force_m1(input [15:0] a);
        integer i;
        begin
            i = 0;
            while (dut.m1 === 1'b1 && i < 32) begin @(posedge tb_clksys); i = i + 1; end
            force dut.nM1   = 1'b0;
            force dut.nMREQ = 1'b0;
            force dut.addr  = a;
            repeat (2) @(posedge tb_clksys);
            release dut.nM1;
            release dut.nMREQ;
            release dut.addr;
            repeat (8) @(posedge tb_clksys);
        end
    endtask

    // CPU memory write at address a: force the bus like a Z80 M-cycle write.
    task mem_write(input [15:0] a, input [7:0] v);
        integer i;
        begin
            force dut.nMREQ = 1'b1;
            i = 0;
            while ((dut.ram_ready !== 1'b1 || dut.ram_rd === 1'b1) && i < 64) begin
                @(posedge tb_clksys);
                i = i + 1;
            end
            force dut.nM1   = 1'b1;
            force dut.nMREQ = 1'b0;
            force dut.nWR   = 1'b0;
            force dut.addr  = a;
            force dut.cpu_dout = v;
            repeat (4) @(posedge tb_clksys);
            force dut.nWR   = 1'b1;
            force dut.nMREQ = 1'b1;
            release dut.cpu_dout;
            release dut.addr;
            release dut.nM1;
            i = 0;
            while (dut.ram_ready !== 1'b1 && i < 64) begin
                @(posedge tb_clksys);
                i = i + 1;
            end
            repeat (8) @(posedge tb_clksys);
        end
    endtask

    // Read one byte from SDRAM at logical address la. Works while the CPU stub is
    // active: pin nMREQ high so no stub read edge can race ours, wait for the
    // controller to be idle, issue a clean rd edge, sample dout when ready rises.
    task probe_read(input [24:0] la, output [7:0] d);
        integer i;
        begin
            force dut.nMREQ = 1'b1;
            i = 0;
            while ((dut.ram_ready !== 1'b1 || dut.ram_rd === 1'b1) && i < 64) begin
                @(posedge tb_clksys);
                i = i + 1;
            end
            force dut.ram_addr = la;
            force dut.ram_rd   = 1'b1;
            d = 8'hxx;
            i = 0;
            while (dut.ram_ready !== 1'b0 && i < 32) begin
                @(posedge tb_clksys);
                i = i + 1;
            end
            i = 0;
            while (dut.ram_ready !== 1'b1 && i < 64) begin
                @(posedge tb_clksys);
                i = i + 1;
            end
            d = dut.ram_dout;
            force dut.ram_rd   = 1'b0;
            release dut.ram_addr;
            release dut.nMREQ;
            repeat (8) @(posedge tb_clksys);
        end
    endtask

    // PS2 key events: format {event, press, ext, code} per rtl/keyboard.sv (edge on bit[10])
    task press_key(input [7:0] code, input ext = 1'b0);
        begin
            dut.hps_io.tb_ps2_d = {1'b1, 1'b1, ext, code};
            repeat (50) @(posedge tb_clksys);
            dut.hps_io.tb_ps2_d = {1'b0, 1'b1, ext, code};
            repeat (50) @(posedge tb_clksys);
        end
    endtask

    task release_key(input [7:0] code, input ext = 1'b0);
        begin
            dut.hps_io.tb_ps2_d = {1'b1, 1'b0, ext, code};
            repeat (50) @(posedge tb_clksys);
            dut.hps_io.tb_ps2_d = {1'b0, 1'b0, ext, code};
            repeat (50) @(posedge tb_clksys);
        end
    endtask

    // ------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------

    task test_smoke;
        integer i, mreqs;
        reg [7:0] d;
        begin
            // SDRAM controller startup takes ~12100 clk_sys
            $display("smoke: waiting for ram_ready");
            wait (dut.ram_ready === 1'b1);
            $display("smoke: ram_ready at t=%0t", $time);
            repeat (200) @(posedge tb_clksys);

            // Machine = ZX48 (status[12:10] = 3). Download under held reset, as the
            // real HPS does (load = (reset | ~nBUSACK) & ioctl_download).
            start_download(64'd3 << 10);

            // 16-byte pattern at file offset 0 (index 0 -> logical base 0x150000)
            for (i = 0; i < 16; i++) write_rom_byte(i[23:0], 8'(i * 7 + 3));

            // Read back exactly where the download landed. The controller writes each
            // byte to its half of a 16-bit word (A[12:11] masks), so even/odd offsets
            // land in different halves of the same physical word - verify both.
            probe_read(25'h150000, d);
            if (d !== 8'h03) begin
                $display("SMOKE FAIL: readback[0] got 0x%02X want 0x03", d);
                $finish;
            end
            probe_read(25'h150001, d);
            if (d !== 8'h0A) begin
                $display("SMOKE FAIL: readback[1] got 0x%02X want 0x0A", d);
                $finish;
            end
            $display("smoke: rom readback ok, byte halves verified");

            stop_download(64'd3 << 10);

            // CPU must be fetching (MREQ follows CEN_p pulses from the ULA)
            mreqs = 0;
            for (i = 0; i < 100000 && mreqs < 100; i++) begin
                @(posedge tb_clksys);
                if (dut.nMREQ === 1'b0) mreqs = mreqs + 1;
            end
            if (mreqs >= 100) $display("SMOKE PASS: rom readback ok, %0d MREQ cycles observed", mreqs);
            else begin
                $display("SMOKE FAIL: only %0d MREQ cycles in 100k clk_sys", mreqs);
                $finish;
            end
        end
    endtask

    // Regression baseline: for every existing machine (status[12:10] 0-4) and a set
    // of paging-register values, sweep the CPU address space and record the decoded
    // ram_addr. Run BEFORE scorpion RTL changes (-> regression_base.txt) and after
    // (-> regression_new.txt); the diff must be empty.
    reg [255:0] g_regfile = "sim/out/regression_new.txt";

    task test_regression;
        integer fd, m, pval, a, i;
        begin
            fd = $fopen(g_regfile, "w");
            if (!fd) begin
                $display("REGRESSION FAIL: cannot open %0s", g_regfile);
                $finish;
            end
            for (m = 0; m < 5; m++) begin
                machine_reset({51'b0, 3'(m), 10'b0});
                repeat (20) @(posedge tb_clksys);
                pval = 0;
                while (pval <= 'h10) begin
                    if (pval != 0) begin
                        force dut.page_reg = pval[7:0];
                        if (m == 4) force dut.page_reg_plus3 = pval[7:0];
                        repeat (4) @(posedge tb_clksys);
                    end
                    for (a = 0; a <= 16'hF000; a += 16'h1000) begin
                        force dut.addr = a[15:0];
                        repeat (2) @(posedge tb_clksys);
                        $fwrite(fd, "M%0d P%02X A%04X R%05X\n", m, pval, a, dut.ram_addr);
                        release dut.addr;
                    end
                    if (pval != 0) begin
                        release dut.page_reg;
                        if (m == 4) release dut.page_reg_plus3;
                    end
                    pval = (pval == 'h10) ? -1 : (pval == 0 ? 'h0F : 'h10);
                end
            end
            $fclose(fd);
            $display("REGRESSION PASS: %0s written", g_regfile);
        end
    endtask

    // alias: load the synthetic ROM through the real host download path and verify
    // each Scorpion page reads back through its window (page_rom 0-3, prefix {3'b110},
    // columns 32-35 = file offsets 0x30000-0x3FFFF). Spot-checks the existing ZX48
    // ROM window is unchanged.
    task test_alias;
        integer p, r;
        reg [7:0] d;
        reg [7:0] expected [0:262143];
        begin
            $readmemh("sim/roms/synthetic_boot.hex", expected);
            machine_reset({51'b0, 3'd5, 10'b0});   // Scorpion
            load_rom_range(M_SCORP, "sim/roms/synthetic_boot.hex", 22'h2C000, 22'h14000); // chunks 11-15
            for (p = 0; p < 4; p++) begin
                set_rom_page(p[3:0]);
                for (r = 0; r < 16'h4000; r += 16'h100) begin
                    probe_read({3'b110, p[3:0], r[13:0]}, d);
                    if (d !== expected[(12 + p) * 16'h4000 + r]) begin
                        $display("ALIAS FAIL p=%0d off=%h got=%h want=%h", p, r, d, expected[(12 + p) * 16'h4000 + r]);
                        $finish;
                    end
                end
            end
            release dut.page_rom;
            machine_reset({51'b0, 3'd3, 10'b0});   // ZX48: existing window unchanged
            set_rom_page(4'd15);
            probe_read({3'b101, 4'd15, 14'h0000}, d);
            if (d !== expected[11 * 16'h4000]) begin
                $display("ALIAS FAIL: ZX48 spot got=%h want=%h", d, expected[11 * 16'h4000]);
                $finish;
            end
            release dut.page_rom;
            $display("ALIAS PASS");
        end
    endtask

    // paging: Scorpion memory map (per Fuse + speccy-bootcamp): #4000-#7FFF is fixed
    // to bank 5, #8000-#BFFF fixed to bank 2, and #C000-#FFFF shows the selected bank
    // scorp_page = {#1FFD[4], #7FFD[2:0]}. Verify all 16 banks through the paged
    // window and that the two fixed windows do not follow page selection.
    task test_paging;
        integer b, want;
        reg [7:0] d;
        begin
            machine_reset({51'b0, 3'd5, 10'b0});   // Scorpion
            wait_sdr_up;                            // controller still in startup at t=0
            // Distinct pattern bytes per bank at offsets 0 / 0x2000 / 0x3FFF of the 16KB bank
            for (b = 0; b < 16; b++) begin
                sdram_write({1'b0, b[3:0], 14'h0000}, (b * 7 + 3));
                sdram_write({1'b0, b[3:0], 14'h2000}, (b * 7 + 4));
                sdram_write({1'b0, b[3:0], 14'h3FFF}, (b * 7 + 5));
            end
            // Paged window: each bank must appear at #C000-#FFFF when selected
            for (b = 0; b < 16; b++) begin
                io_write(16'h7FFD, {4'b0, b[2:0]});        // #7FFD <- page low bits
                io_write(16'h1FFD, {2'b0, b[3], 4'b0});    // #1FFD <- bit 4 (upper page bit)
                cpu_read(16'hC000, d);
                want = b * 7 + 3;
                if (d !== want) begin $display("PAGING FAIL bank=%0d off=0 got=%h want=%h", b, d, want[7:0]); $finish; end
                cpu_read(16'hE000, d);
                want = b * 7 + 4;
                if (d !== want) begin $display("PAGING FAIL bank=%0d off=2000 got=%h want=%h", b, d, want[7:0]); $finish; end
                cpu_read(16'hFFFF, d);
                want = b * 7 + 5;
                if (d !== want) begin $display("PAGING FAIL bank=%0d off=3FFF got=%h want=%h", b, d, want[7:0]); $finish; end
            end
            // Fixed windows: #4000 -> bank 5, #8000 -> bank 2, even with bank 0 selected
            io_write(16'h7FFD, 8'h00);
            io_write(16'h1FFD, 8'h00);
            cpu_read(16'h4000, d);
            want = 5 * 7 + 3;
            if (d !== want) begin $display("PAGING FAIL fixed #4000 got=%h want=%h", d, want[7:0]); $finish; end
            cpu_read(16'h6000, d);
            want = 5 * 7 + 4;
            if (d !== want) begin $display("PAGING FAIL fixed #6000 got=%h want=%h", d, want[7:0]); $finish; end
            cpu_read(16'h8000, d);
            want = 2 * 7 + 3;
            if (d !== want) begin $display("PAGING FAIL fixed #8000 got=%h want=%h", d, want[7:0]); $finish; end
            // vram mirror: writes to physical screen banks (5/7) mirror into the ULA dpram
            // at {bank-half, addr[13:0]}; data-bank writes must not. #4000 is always bank 5;
            // #C000 follows scorp_page (half = column[1]).
            io_write(16'h7FFD, 8'h05);                      // page 5 at #C000 (screen bank)
            mem_write(16'hC000, 8'hA5);                     // -> dpram[0x0000]
            if (dut.vram.altsyncram_component.mem[15'd0][7:0] !== 8'hA5) begin $display("PAGING FAIL vram mirror #C000 page5"); $finish; end
            io_write(16'h7FFD, 8'h07);                      // page 7 -> dpram half 1
            mem_write(16'hC000, 8'h5A);                     // -> dpram[0x4000]
            if (dut.vram.altsyncram_component.mem[15'h4000][7:0] !== 8'h5A) begin $display("PAGING FAIL vram mirror #C000 page7"); $finish; end
            io_write(16'h7FFD, 8'h00);                      // page 0 (data bank): must NOT mirror
            mem_write(16'hC020, 8'h3C);
            if (dut.vram.altsyncram_component.mem[15'd0][7:0] !== 8'hA5) begin $display("PAGING FAIL vram non-mirror page0"); $finish; end
            if (dut.vram.altsyncram_component.mem[15'h4000][7:0] !== 8'h5A) begin $display("PAGING FAIL vram non-mirror page0 half1"); $finish; end
            mem_write(16'h4010, 8'hC3);                     // #4000 always bank 5 -> dpram[0x0010]
            if (dut.vram.altsyncram_component.mem[15'd16][7:0] !== 8'hC3) begin $display("PAGING FAIL vram mirror #4000"); $finish; end
            // Port read conformance (speccy-bootcamp): #7FFD is write-only (no assertion -
            // floating bus); #1FFD reads return #FF on non-Turbo boards.
            io_read(16'h1FFD, d);
            if (d !== 8'hFF) begin $display("PAGING FAIL #1FFD read got=%h want=ff", d); $finish; end
            // Bit-5 lockout: OUT (#7FFD),%00100000 blocks further paging writes until reset.
            io_write(16'h7FFD, 8'h25);      // page 5 + lock bit (this write still applies)
            io_write(16'h7FFD, 8'h03);      // must be ignored (locked)
            io_write(16'h1FFD, 8'h10);      // must be ignored (locked)
            cpu_read(16'hE000, d);         // still bank 5 (off 0x2000): page stayed 5, upper bit stayed 0
            want = 5 * 7 + 4;
            if (d !== want) begin $display("PAGING FAIL lockout #E000 got=%h want=%h", d, want[7:0]); $finish; end
            if (dut.page_reg !== 8'h25) begin $display("PAGING FAIL lockout page_reg got=%h want=25", dut.page_reg); $finish; end
            if (dut.scorp_1ffd !== 8'h00) begin $display("PAGING FAIL lockout scorp_1ffd got=%h want=0", dut.scorp_1ffd); $finish; end
            // Reset clears the lockout ("until reset" half of the contract):
            // paging writes apply again and the paged window follows.
            machine_reset({51'b0, 3'd5, 10'b0});   // Scorpion
            wait_sdr_up;                            // controller restarts on reset
            io_write(16'h7FFD, 8'h03);              // must now apply (unlocked)
            if (dut.page_reg !== 8'h03) begin $display("PAGING FAIL post-reset page_reg got=%h want=03", dut.page_reg); $finish; end
            cpu_read(16'hC000, d);                  // paged window follows: bank 3 at offset 0
            want = 3 * 7 + 3;
            if (d !== want) begin $display("PAGING FAIL post-reset #C000 got=%h want=%h", d, want[7:0]); $finish; end
            $display("PAGING PASS");
        end
    endtask
    // romchain: walk the Scorpion #0000 ROM select chain with real ROM content:
    // default ROM0 -> #7FFD[4]=1 ROM1 -> #1FFD[1] Shadow -> #1FFD[0] RAM bank 0
    // (written through the window) -> clear both -> ROM0.
    task test_romchain;
        reg [7:0] d, e0, e1, e2, e3;
        reg [7:0] romexp [0:262143];
        begin
            $readmemh("sim/roms/synthetic_boot.hex", romexp);
            machine_reset({51'b0, 3'd5, 10'b0});   // Scorpion, scorp_1ffd=0, page_reg=0
            load_rom_range(M_SCORP, "sim/roms/synthetic_boot.hex", 22'h30000, 22'h10000);  // chunks 12-15
            e0 = romexp[20'h30000];
            e1 = romexp[20'h34000];
            e2 = romexp[20'h38000];
            cpu_read(16'h0000, d);
            if (d !== e0) begin $display("ROMCHAIN FAIL step1 got=%h want=%h", d, e0); $finish; end
            io_write(16'h7FFD, 8'h10);             // page_reg[4]=1 -> ROM1 (48K BASIC)
            cpu_read(16'h0000, d);
            if (d !== e1) begin $display("ROMCHAIN FAIL step2 got=%h want=%h", d, e1); $finish; end
            io_write(16'h1FFD, 8'h02);             // Shadow Service Monitor (ROM2)
            cpu_read(16'h0000, d);
            if (d !== e2) begin $display("ROMCHAIN FAIL step3 got=%h want=%h", d, e2); $finish; end
            io_write(16'h1FFD, 8'h03);             // RAM bank 0 at #0000
            mem_write(16'h0000, 8'h5A);
            cpu_read(16'h0000, d);
            if (d !== 8'h5A) begin $display("ROMCHAIN FAIL step4 got=%h want=5A", d); $finish; end
            io_write(16'h1FFD, 8'h00);             // back to ROM0
            io_write(16'h7FFD, 8'h00);
            cpu_read(16'h0000, d);
            if (d !== e0) begin $display("ROMCHAIN FAIL step5 got=%h want=%h", d, e0); $finish; end
            // TR-DOS ROM3: an M1 fetch at #3Dxx latches trdos_en -> page_rom=3 (column 35),
            // the core's emulation of the Beta 128 FDC ROMCS path.
            e3 = romexp[20'h3C000];
            force_m1(16'h3D00);
            if (dut.page_rom !== 4'd3) begin $display("ROMCHAIN FAIL trdos page_rom got=%d want=3", dut.page_rom); $finish; end
            cpu_read(16'h0000, d);
            if (d !== e3) begin $display("ROMCHAIN FAIL trdos #0000 got=%h want=%h", d, e3); $finish; end
            force_m1(16'hC000);             // clear trdos_en (M1 with addr[15:14]=11)
            $display("ROMCHAIN PASS");
        end
    endtask

    // MNI: F11 (no modifiers) pulses NMI; on Scorpion the core must also select the
    // Shadow Service Monitor (scorp_1ffd bit 1 set, bit 0 kept -> ROM2 window). The
    // stub's NMI vector M1 at #0066 must land in the ROM2 column; OUT (#1FFD),0 via
    // the real hardware path exits back to ROM0.
    task test_mni;
        integer i;
        begin
            machine_reset(M_SCORP);
            wait_sdr_up;                            // controller still in startup at t=0
            repeat (400) @(posedge tb_clksys);      // a few hundred cycles of normal fetches

            // Precondition: ROM0 active — an M1 fetch below #4000 decodes column 32.
            i = 0;
            while (!(dut.m1 && dut.addr < 16'h4000) && i < 4096) begin @(posedge tb_clksys); i = i + 1; end
            if (i >= 4096) begin $display("MNI FAIL no M1 fetch below #4000"); $finish; end
            if (dut.ram_addr[19:14] !== 6'd32) begin $display("MNI FAIL pre column got=%d want=32", dut.ram_addr[19:14]); $finish; end

            // F11 press -> Fn[11] rising edge -> NMI (MNI).
            press_key(8'h78);
            i = 0;
            while (dut.NMI !== 1'b1 && i < 200) begin @(posedge tb_clksys); i = i + 1; end
            if (dut.NMI !== 1'b1) begin $display("MNI FAIL no NMI pulse within 200 cycles"); $finish; end

            // MNI must select the Shadow Service Monitor: bit 1 set, bit 0 kept.
            if (dut.scorp_1ffd !== 8'h02) begin $display("MNI FAIL scorp_1ffd got=%h want=02", dut.scorp_1ffd); $finish; end

            // The stub's NMI vector: the M1 fetch at #0066 must land in the ROM2 window (column 34).
            i = 0;
            while (!(dut.m1 && dut.addr == 16'h0066) && i < 8192) begin @(posedge tb_clksys); i = i + 1; end
            if (i >= 8192) begin $display("MNI FAIL no vector M1 at #0066"); $finish; end
            if (dut.ram_addr[19:14] !== 6'd34) begin $display("MNI FAIL vector column got=%d want=34", dut.ram_addr[19:14]); $finish; end

            // Monitor exit via the real hardware path: OUT (#1FFD),0 -> ROM0 (column 32).
            release_key(8'h78);                     // drop F11 so NMI cannot re-fire
            io_write(16'h1FFD, 8'h00);
            i = 0;
            while (!(dut.m1 && dut.addr < 16'h4000) && i < 8192) begin @(posedge tb_clksys); i = i + 1; end
            if (i >= 8192) begin $display("MNI FAIL no M1 fetch below #4000 after exit"); $finish; end
            if (dut.ram_addr[19:14] !== 6'd32) begin $display("MNI FAIL post column got=%d want=32", dut.ram_addr[19:14]); $finish; end

            // Pre-set bit 0 (ROM1 select): a second MNI must preserve it -> 0x03.
            io_write(16'h1FFD, 8'h01);
            repeat (4) @(posedge tb_clksys);         // settle before NMI
            press_key(8'h78);
            i = 0;
            while (dut.NMI !== 1'b1 && i < 200) begin @(posedge tb_clksys); i = i + 1; end
            if (dut.NMI !== 1'b1) begin $display("MNI FAIL no second NMI pulse"); $finish; end
            repeat (4) @(posedge tb_clksys);         // let the mni_pending latch apply
            if (dut.scorp_1ffd !== 8'h03) begin $display("MNI FAIL pre-set bit0 got=%h want=03", dut.scorp_1ffd); $finish; end
            $display("MNI PASS");
        end
    endtask

    // snapscorp: load a minimal Scorpion .z80 (hw=10; generated by
    // tools/make_test_z80.py -> sim/roms/test_scorp.{z80,hex}) through the real
    // snapshot download path (ioctl index 4), starting from a non-Scorpion machine
    // so the hwset handshake is exercised. Verify: machine switches to Scorpion,
    // #7FFD/#1FFD restore page_reg/scorp_1ffd (scorp_page = {1,5} = 13), PC=#C000,
    // and the memory block lands where #C000 decodes under the restored paging.
    task test_snapscorp;
        integer i;
        reg [7:0] z80 [0:16473];
        reg [7:0] d;
        begin
            $readmemh("sim/roms/test_scorp.hex", z80);
            if (z80[34] !== 8'h0a) begin
                $display("SNAPSCORP FAIL: sim/roms/test_scorp.hex missing or bad (run tools/make_test_z80.py)");
                $finish;
            end
            machine_reset({51'b0, 3'd0, 10'b0});   // non-Scorpion start -> hwset path
            wait_sdr_up;                            // controller still in startup at t=0

            // Snapshot download window: index 4 must be presented before the
            // download rises (snap_loader gates on ioctl_index[4:0]==4), core reset
            // held as the real HPS does.
            dut.hps_io.tb_status = 64'h1;           // machine 0 + Reset & Apply
            wait_sdr_up;
            repeat (50) @(posedge tb_clksys);
            dut.hps_io.tb_ioctl_index_d    = 8'd4;
            dut.hps_io.tb_ioctl_download_d = 1'b1;
            repeat (4) @(posedge tb_clksys);

            for (i = 0; i < 16474; i++) write_snap_byte(i[23:0], z80[i]);

            dut.hps_io.tb_ioctl_download_d = 1'b0;
            repeat (4) @(posedge tb_clksys);

            // hwset handshake: the loader requests the machine change, the host acks
            // by presenting ARCH_SCORP in status[12:8], then releases core reset.
            i = 0;
            while (dut.snap_loader.snap_hwset !== 1'b1 && i < 256) begin @(posedge tb_clksys); i = i + 1; end
            if (dut.snap_loader.snap_hwset !== 1'b1) begin $display("SNAPSCORP FAIL: no snap_hwset after download"); $finish; end
            #1;
            dut.hps_io.tb_status[12:8] = 5'b101_00;   // host ack (reset bit still held)
            i = 0;
            while (dut.snap_loader.snap_hwset !== 1'b0 && i < 256) begin @(posedge tb_clksys); i = i + 1; end
            if (dut.snap_loader.snap_hwset !== 1'b0) begin $display("SNAPSCORP FAIL: snap_hwset stuck after ack"); $finish; end
            #1;
            dut.hps_io.tb_status = M_SCORP;           // release core reset

            i = 0;
            while (dut.reset !== 1'b0 && i < 256) begin @(posedge tb_clksys); i = i + 1; end
            if (dut.reset !== 1'b0) begin $display("SNAPSCORP FAIL: reset stuck after hwset ack"); $finish; end
            repeat (8) @(posedge tb_clksys);

            if (dut.scorp !== 1'b1) begin $display("SNAPSCORP FAIL: scorp mode not active"); $finish; end
            if (dut.page_reg[2:0] !== 3'd5) begin $display("SNAPSCORP FAIL: page_reg[2:0] got=%d want=5", dut.page_reg[2:0]); $finish; end
            if (dut.scorp_1ffd !== 8'h10) begin $display("SNAPSCORP FAIL: scorp_1ffd got=%h want=10", dut.scorp_1ffd); $finish; end
            // T80 REG file layout (T80.vhd): PC = [79:64]
            if (dut.cpu_reg[79:64] !== 16'hC000) begin $display("SNAPSCORP FAIL: PC got=%h want=C000", dut.cpu_reg[79:64]); $finish; end
            // The block's bank (13) is what #C000 decodes to under the restored paging
            cpu_read(16'hC000, d);
            if (d !== 8'h01) begin $display("SNAPSCORP FAIL: mem[C000] got=%h want=01", d); $finish; end
            cpu_read(16'hC010, d);
            if (d !== 8'h71) begin $display("SNAPSCORP FAIL: mem[C010] got=%h want=71", d); $finish; end
            $display("SNAPSCORP PASS");
        end
    endtask

    // Read one byte from the SDRAM model's memory array by 25-bit local address.
    // Non-intrusive (no bus traffic) - safe to call while the real CPU is running.
    // Controller mapping (rtl/sdram.sv): ACTIVE drives row = addr[13:1],
    // BA = addr[24:23]; CAS drives A[8:0] = addr[22:14] and the model decodes only
    // A[5:0] (= addr[19:14]) as the column with bank = BA[0] = addr[23].
    // Byte half = addr[0] (controller's dout select).
    function [7:0] sdr_byte;
        input [24:0] la;
        begin
            if (la[0]) sdr_byte = sdr.mem[la[23]][{la[13:1], la[19:14]}][15:8];
            else       sdr_byte = sdr.mem[la[23]][{la[13:1], la[19:14]}][7:0];
        end
    endfunction
    // Read one byte of the ULA's video RAM - the dpram mirror that receives every
    // CPU write to #4000-#7FFF (dpram half 0) and to #C000-#FFFF while scorp_page
    // is 5 (half 0) or 7 (half 1). Non-intrusive hierarchical read, same pattern
    // as sdr_byte(). Sampling the full 32 KB covers both screen banks.
    function [7:0] vram_byte;
        input [14:0] a;
        begin
            vram_byte = dut.vram.altsyncram_component.mem[a][7:0];
        end
    endfunction
    // boot: real Scorpion v2.94 firmware executing on a real Z80 (TV80 - only
    // compiled when run_sim.sh is invoked with REALCPU=1; the test fails fast
    // without it, so it can never pass against the fetch-only stub). Loads the ROM
    // pages through the host download path (the actual power-on flow), releases
    // reset, lets the CPU run, and verifies:
    //   1. M1 fetches from the ROM0 window (#0000-#3FFF -> SDRAM column 32)
    //   2. v2.94's post-init paging reaches its measured final state #7FFD=0x10,
    //      #1FFD=0x12: the firmware counts #7FFD down 0x17->0x10 (one step per
    //      ~1.1M core clocks) while #1FFD stays 0x12 (Shadow Monitor select);
    //      only executing firmware on a correctly decoding core reaches this state
    //   3. ULA frame INTs fire during boot (v2.94 waits for the first one)
    //   4. the border color register is defined after boot (FPGA power-on default
    //      0; v2.94 never writes #FF until TR-DOS is entered - ROM scan evidence)
    // The display file is NOT required to be non-zero: measured unattended boot
    // reaches the Shadow Monitor without drawing a screen (no display-file writes
    // during the whole sequence). Its contents are dumped to sim/out/screen_boot.hex
    // for inspection; the display write path itself is pinned by test_paging.
    task test_boot;
        integer i, row, c, m1cnt, nz, screen_nz, realcpu;
        reg [7:0] d;
        integer fd;
        reg [15:0] last_pc = 16'hffff;
        integer pc_changes = 0, int_edges = 0;
        reg old_int = 1'b1;
        reg paging_seen = 1'b0;
        begin
            // The fetch-only stub executes nothing - any pass without a real CPU is
            // a false green. run_sim.sh passes +REALCPU=1 when TV80 is compiled in.
            realcpu = 0;
            if (!$value$plusargs("REALCPU=%d", realcpu) || !realcpu) begin
                $display("BOOT FAIL: requires a real CPU (run: REALCPU=1 ./sim/run_sim.sh boot)");
                $finish;
            end

            machine_reset(M_SCORP);
            wait_sdr_up;

            // Power-on flow: the host downloads the boot ROM while reset is held.
            load_rom_range(M_SCORP, "sim/roms/synthetic_boot.hex", 22'h2C000, 22'h14000); // chunks 11-15 (ROM pages 0-3 + ZX48)

            // Let the real CPU run. Measured boot flow (v2.94 ROM, this host): ULA
            // frame INT at line 248; long DEC BC countdowns in ROM0; post-init then
            // counts #7FFD down 0x17->0x10 (~1.1M core clocks per step) while
            // #1FFD stays 0x12, completing at i~95M = ~850 ms of machine time.
            // Clock math (verified against ULA counters): T-state = 32 core clocks;
            // one frame = 312 lines x 448 ticks x 16 = 2,236,416 core clocks =
            // 20 ms machine time. Window: 120M core clocks (~1.07 s) - ~25% margin
            // over measured post-init completion. Poll memory directly (no bus
            // traffic) and exit early once the final paging state is reached.
            m1cnt = 0;
            for (i = 0; i < 120000000; i++) begin
                @(posedge tb_clksys);
                if (dut.page_reg === 8'h10 && dut.scorp_1ffd === 8'h12) paging_seen = 1'b1;
                if (old_int & ~dut.nINT) begin
                    int_edges = int_edges + 1;
                    if (int_edges <= 8) $display("DBG INT assert i=%0d vc=%0d hc=%0d", i, dut.ULA.vc, dut.ULA.hc);
                end
                old_int = dut.nINT;
                if (dut.m1 && dut.ram_addr[19:14] === 6'd32 && dut.addr <= 16'h3FFF) begin
                    m1cnt = m1cnt + 1;
                    if (i % 100000 == 0) $display("DBG i=%0d pc=%h", i, dut.addr);
                    if (dut.addr != last_pc) pc_changes = pc_changes + 1;
                    last_pc = dut.addr;
                end
                if (i % 50000 == 49999) begin
                    screen_nz = 0;
                    for (c = 0; c < 256; c++)
                        if (vram_byte(c * 128) !== 8'h00) screen_nz = screen_nz + 1;
                    // Periodic time-series so a single long run shows when each
                    // criterion becomes true; flushed so progress is visible even
                    // when stdout is piped (vvp fully buffers).
                    if (i % 500000 == 499999) begin
                        $display("DBG i=%0d m1=%0d int=%0d page=%h s1ffd=%h scr_nz=%0d", i, m1cnt, int_edges, dut.page_reg, dut.scorp_1ffd, screen_nz);
                        $fflush();
                    end
                    if (paging_seen) begin
                        $display("DBG early exit at i=%0d (post-init paging state reached)", i);
                        i = 120000000;
                    end
                end
            end
            $display("DBG m1cnt=%0d pc_changes=%0d int_edges=%0d last_pc=%h border=%b scorp_1ffd=%h page_reg=%h", m1cnt, pc_changes, int_edges, last_pc, dut.border_color, dut.scorp_1ffd, dut.page_reg);
            if (m1cnt < 100) begin
                $display("BOOT FAIL: only %0d M1 fetches from the ROM0 window", m1cnt);
                $finish;
            end

            // v2.94 post-init final state (measured real-CPU behavior): #7FFD=0x10,
            // #1FFD=0x12 - the firmware counts #7FFD down from 0x17 and stops here.
            if (!paging_seen) begin
                $display("BOOT FAIL: post-init paging state never reached (#7FFD=0x10, #1FFD=0x12); page_reg=%h scorp_1ffd=%h", dut.page_reg, dut.scorp_1ffd);
                $finish;
            end

            // v2.94 waits for the first ULA frame INT before continuing boot.
            if (int_edges == 0) begin
                $display("BOOT FAIL: no ULA frame INT observed during boot");
                $finish;
            end

            // Display file: unattended boot does not draw a screen (measured), so
            // non-zero content is NOT required. Dump the ULA's video RAM - the
            // dpram mirror of all display-file writes, i.e. what the ULA displays.
            nz = 0;
            fd = $fopen("sim/out/screen_boot.hex", "w");
            if (!fd) begin $display("BOOT FAIL: cannot open sim/out/screen_boot.hex"); $finish; end
            for (row = 0; row < 1024; row++) begin
                for (c = 0; c < 32; c++) begin
                    d = vram_byte(row * 32 + c);
                    if (d !== 8'h00) nz = nz + 1;
                    $fwrite(fd, "%02x", d);
                end
                $fwrite(fd, "\n");
            end
            $fclose(fd);

            // Border color: FPGA power-on default (0) - must stay defined, never X.
            if (dut.border_color === 3'bxxx) begin
                $display("BOOT FAIL: border color is X after boot");
                $finish;
            end

            $display("BOOT PASS: %0d M1 fetches from ROM0, post-init paging #7FFD=%h/#1FFD=%h reached, int_edges=%0d, screen non-zero bytes=%0d (informational), border=%b", m1cnt, dut.page_reg, dut.scorp_1ffd, int_edges, nz, dut.border_color);
        end
    endtask

    // ------------------------------------------------------------------
    // Main
    // ------------------------------------------------------------------
    reg [127:0] testname = "smoke";

    initial begin
        if (!$value$plusargs("TEST=%s", testname)) testname = "smoke";
        if ($value$plusargs("REGFILE=%s", g_regfile));
        $display("tb_top: running test '%0s'", testname);
        case (testname)
            "smoke":       test_smoke();
            "regression":  test_regression();
            "alias":       test_alias();
            "paging":      test_paging();
            "romchain":    test_romchain();
            "mni":         test_mni();
            "snapscorp":   test_snapscorp();
            "boot":        test_boot();
            default:       $display("unknown test %0s", testname);
        endcase
        $display("DONE");
        $finish;
    end

    // Global watchdog (default 20 ms sim time; override with +STOPNS=<ns>)
    integer stop_ns = 20_000_000;
    initial begin
        if ($value$plusargs("STOPNS=%d", stop_ns));
        #(stop_ns);
        $display("WATCHDOG TIMEOUT at t=%0t (requested %0d ns)", $time, stop_ns);
        $finish;
    end

endmodule
