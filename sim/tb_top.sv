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

    // Host download flows exactly like the real HPS: the core holds the CPU in reset
    // while a download is active, because load = (reset | ~nBUSACK) & ioctl_download.
    // Asserting BUSRQ on its own is NOT sufficient: snap_loader raises snap_reset on
    // every download start, which cold-resets the machine and the CPU can never take
    // the bus to answer BUSRQ while held in reset. So: reset first, then download.
    task start_download(input [63:0] machine);
        begin
            dut.hps_io.tb_status = machine | 64'h1;   // hold core reset (status[0])
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

    // Read one byte from SDRAM at logical address la. Requires the CPU to be out of
    // the way (held in reset by start_download). Forces ram_addr/ram_rd directly;
    // captures dout once the access has settled (ready may already be high for a
    // same-word read, which the controller answers without re-issuing CAS).
    task probe_read(input [24:0] la, output [7:0] d);
        integer i;
        reg done;
        begin
            force dut.ram_addr = la;
            force dut.ram_rd   = 1'b1;
            i = 0;
            done = 0;
            while (!done && i < 32) begin
                @(posedge tb_clksys);
                if (i >= 6 && dut.ram_ready === 1'b1) begin
                    d = dut.ram_dout;
                    done = 1;
                end
                i = i + 1;
            end
            force dut.ram_rd   = 1'b0;
            release dut.ram_addr;
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

    // ------------------------------------------------------------------
    // Main
    // ------------------------------------------------------------------

    reg [63:0] testname = "smoke";

    initial begin
        if (!$value$plusargs("TEST=%s", testname)) testname = "smoke";
        $display("tb_top: running test '%0s'", testname);
        case (testname)
            "smoke":   test_smoke();
            default:   $display("unknown test %0s", testname);
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
