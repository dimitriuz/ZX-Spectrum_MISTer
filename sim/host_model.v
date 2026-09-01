// Simulation replacement for sys/hps_io.sv (MiSTer HPS protocol wrapper).
// Same module name and the ports emu connects; the MiSTer host is modeled by TB-driven
// regs, written hierarchically from tb_top: dut.hps_io.tb_*
//   tb_status[63:0]      OSD status word (bit 0 = reset, [12:10] = machine)
//   tb_ioctl_wr/addr/dout/download/index   ROM/snapshot download strobes
//   tb_ps2[10:0]         {event, press, ext, code} — edge on bit[10] strobes a key
// Disk/SD interfaces are tied off (no disk I/O in the current test set).
module hps_io #(parameter CONF_STR = "", parameter VDNUM = 1) (
    input             clk_sys,
    inout      [45:0] HPS_BUS,

    output     [10:0] ps2_key,
    output     [24:0] ps2_mouse,
    output     [15:0] joystick_0,
    output     [15:0] joystick_1,
    output      [1:0] buttons,
    output            forced_scandoubler,
    input             new_vmode,
    output     [63:0] status,
    input       [3:0] status_menumask,
    input             status_set,
    input      [63:0] status_in,
    input      [31:0] sd_lba[2],
    input       [1:0] sd_rd,
    input       [1:0] sd_wr,
    output      [1:0] sd_ack,
    output      [8:0] sd_buff_addr,
    output      [7:0] sd_buff_dout,
    input       [7:0] sd_buff_din[2],
    input             sd_buff_wr,
    output      [1:0] img_mounted,
    output     [63:0] img_size,
    output            img_readonly,

    output            ioctl_wr,
    output     [24:0] ioctl_addr,
    output      [7:0] ioctl_dout,
    output            ioctl_download,
    output      [7:0] ioctl_index,
    input             ioctl_wait,

    input      [21:0] gamma_bus
);
    // TB-controlled state (drive via hierarchical refs from tb_top)
    reg  [63:0] tb_status       = 0;
    reg         tb_ioctl_wr_d   = 0;
    reg  [24:0] tb_ioctl_addr_d = 0;
    reg  [7:0]  tb_ioctl_dout_d = 0;
    reg         tb_ioctl_download_d = 0;
    reg  [7:0]  tb_ioctl_index_d = 0;
    reg  [10:0] tb_ps2_d        = 0;

    assign ps2_key          = tb_ps2_d;
    assign ps2_mouse        = 0;
    assign joystick_0       = 0;
    assign joystick_1       = 0;
    assign buttons          = 0;
    // The real hps_io drives `status` (the OSD-applied machine word) into emu; the TB
    // plays the HPS side by writing tb_status. Combinational is fine: TB tasks insert
    // wait cycles after every tb_* update.
    assign status           = tb_status;
    assign forced_scandoubler = 0;

    assign sd_ack           = 0;   // no disk I/O in sim (extend if a test needs it)
    assign sd_buff_addr     = 0;
    assign sd_buff_dout     = 0;
    assign img_mounted      = 0;
    assign img_size         = 0;
    assign img_readonly     = 0;

    assign ioctl_wr         = tb_ioctl_wr_d;
    assign ioctl_addr       = tb_ioctl_addr_d;
    assign ioctl_dout       = tb_ioctl_dout_d;
    assign ioctl_download   = tb_ioctl_download_d;
    assign ioctl_index      = tb_ioctl_index_d;

endmodule
