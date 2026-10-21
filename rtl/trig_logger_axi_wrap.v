`timescale 1 ns / 1 ps
// -------------------------------------------------------------
// Minimal AXI4-Lite wrapper for trig_logger
// - 32-bit word regs, offset = 4*index (ADDR_LSB=2)
// - N_REGS = 2**LOG_NPAR
// - Only edit: USER MAP and USER INSTANTIATION
//
// Register map (offset = 4 * index):
//   0x00 control    : [0]arm [1]clear_ts [2]reset [3]snap [4]ack
//   0x04 frame_len  : [ADDR_BITS-2:0] records per buffer before swap
//   0x08 flush_ticks: [31:0] clock cycles before a forced swap of a partial
//                     buffer (0 = never). Clock cycles, not us -- the
//                     timestamp has no prescaler, so 100 ms = 12_500_000.
//   0x0C log_n_avg  : [3:0] boxcar window = 2^log_n_avg samples (<= MAX_LOG_AVG)
//   0x10 n_delay    : [31:0] clock cycles from the trigger to the energy latch
//   0x14 trig_dead  : [31:0] holdoff cycles after a record is written
//   0x18 dir_thr_pos: [15:0] signed  (dir_in at or above -> +1)
//   0x1C dir_thr_neg: [15:0] signed  (dir_in at or below -> -1)
//   0x20 trig_cfg   : [3:0]trig_sel  [4]trig_invert
//   0x24 spare
//   0x28 spare
//   0x2C spare
//   ---- read-only (regs 12..31) ----
//   0x30 status     : [0]ready [1]ready_buf [2]dropped_nonzero
//                     [3]skipped_nonzero [4]busy [5]avg_ready [6]trig_level
//   0x34 ready_count
//   0x38 dropped
//   0x3C ts_snap_lo : timestamp[31:0]
//   0x40 ts_snap_hi : timestamp[45:32]  (14 bits)
//   0x44 events_lo  : total_events[31:0]
//   0x48 events_hi  : total_events[45:32]
//   0x4C skipped    : triggers ignored (busy / dead / window not primed)
//   0x50 live       : [15:0] energy_now (signed) [17:16] dir_now
// -------------------------------------------------------------
module trig_logger_axi_wrap #(
    // AXI
    parameter integer C_S_AXI_ADDR_WIDTH = 8,
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    // Register bank
    parameter integer LOG_NPAR    = 5,   // 5 -> 32 regs
    // trig_logger geometry
    parameter integer TS_WIDTH    = 46,
    parameter integer E_WIDTH     = 16,
    parameter integer DIR_WIDTH   = 2,
    parameter integer REC_WIDTH   = 64,
    parameter integer ADDR_BITS   = 13,  // 2^ADDR_BITS words total (2 buffers)
    parameter integer DATA_WIDTH  = 16,
    parameter integer MAX_LOG_AVG = 11,  // 2048-sample boxcar ceiling
    parameter integer TRIG_BUS_W  = 16,
    parameter integer DLY_WIDTH   = 32
)(
    // AXI4-Lite
    input  wire                              s_axi_aclk,
    input  wire                              s_axi_aresetn,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_awaddr,
    input  wire                              s_axi_awvalid,
    output wire                              s_axi_awready,
    input  wire [C_S_AXI_DATA_WIDTH-1:0]     s_axi_wdata,
    input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0] s_axi_wstrb,
    input  wire                              s_axi_wvalid,
    output wire                              s_axi_wready,
    output wire [1:0]                        s_axi_bresp,
    output wire                              s_axi_bvalid,
    input  wire                              s_axi_bready,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_araddr,
    input  wire                              s_axi_arvalid,
    output wire                              s_axi_arready,
    output wire [C_S_AXI_DATA_WIDTH-1:0]     s_axi_rdata,
    output wire [1:0]                        s_axi_rresp,
    output wire                              s_axi_rvalid,
    input  wire                              s_axi_rready,

    // ---------------------------------------------------------
    // USER PORTS BEGIN (edit to match your IP)
    // ---------------------------------------------------------
    input  wire signed [DATA_WIDTH-1:0]      x_in,       // IN1, energy  (adc tdata[15:0])
    input  wire signed [DATA_WIDTH-1:0]      dir_in,     // IN2, piezo direction (adc tdata[31:16])
    input  wire [TRIG_BUS_W-1:0]             trig_bus,   // digital inputs (exp_p[7:0] ++ exp_n[7:0])

    // BRAM Port-B (Port-A -> AXI BRAM Ctrl / CDMA source)
    output wire [ADDR_BITS-1:0]              bram_addr,
    output wire [REC_WIDTH-1:0]              bram_din,
    output wire                              bram_en,
    output wire [(REC_WIDTH/8)-1:0]          bram_we
);

    localparam integer ADDR_LSB   = 2;                  // 32-bit words
    localparam integer N_REGS     = (1 << LOG_NPAR);    // 32
    localparam integer N_READONLY = 20;                 // regs 12..31 are read-only
    localparam [1:0]   RESP_OK    = 2'b00;

    // ----------------------------
    // AXI write channel (tiny)
    // ----------------------------
    reg awready, wready, bvalid;
    reg [1:0] bresp;
    reg [C_S_AXI_ADDR_WIDTH-1:0] awaddr_q;

    assign s_axi_awready = awready;
    assign s_axi_wready  = wready;
    assign s_axi_bvalid  = bvalid;
    assign s_axi_bresp   = bresp;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            awready <= 1'b0; wready <= 1'b0; bvalid <= 1'b0; bresp <= RESP_OK;
            awaddr_q <= {C_S_AXI_ADDR_WIDTH{1'b0}};
        end else begin
            awready <= (!awready && s_axi_awvalid && s_axi_wvalid);
            wready  <= (!wready  && s_axi_wvalid  && s_axi_awvalid);
            if (!awready && s_axi_awvalid && s_axi_wvalid) awaddr_q <= s_axi_awaddr;

            if (!bvalid && awready && s_axi_awvalid && wready && s_axi_wvalid) begin
                bvalid <= 1'b1; bresp <= RESP_OK;
            end else if (bvalid && s_axi_bready) begin
                bvalid <= 1'b0;
            end
        end
    end

    // ----------------------------
    // Read-only outputs from the module
    //
    // Declared up here, ahead of the register bank that samples them, so the
    // file is legal Verilog-2001. (event_logger_axi_wrap declares these below
    // the bank instead: Vivado synthesis accepts the forward reference, but
    // xvlog rejects it, which is why that wrapper cannot be simulated.)
    // ----------------------------
    wire                      ready;
    wire                      ready_buf;
    wire [ADDR_BITS-1:0]      ready_count;
    wire               [31:0] dropped;
    wire               [31:0] skipped;
    wire [TS_WIDTH-1:0]       ts_snap;
    wire [TS_WIDTH-1:0]       total_events;
    wire                      busy;
    wire                      avg_ready;
    wire                      trig_level;
    wire signed [E_WIDTH-1:0] energy_now;
    wire [DIR_WIDTH-1:0]      dir_now;

    // ----------------------------
    // Register bank (N_REGS x 32)
    // ----------------------------
    reg [31:0] regs [0:N_REGS-1];

    function [31:0] wmask32(input [3:0] strobe);
        wmask32 = { {8{strobe[3]}}, {8{strobe[2]}}, {8{strobe[1]}}, {8{strobe[0]}} };
    endfunction

    wire write_fire = awready && s_axi_awvalid && wready && s_axi_wvalid;
    wire [LOG_NPAR-1:0] widx = awaddr_q[ADDR_LSB +: LOG_NPAR];

    integer k;
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            for (k = 0; k < N_REGS; k = k + 1) regs[k] <= 32'd0;
        end else begin
            if (write_fire && widx < (N_REGS - N_READONLY))
                regs[widx] <= (regs[widx] & ~wmask32(s_axi_wstrb))
                            | (s_axi_wdata &  wmask32(s_axi_wstrb));
            regs[12] <= {25'd0, trig_level, avg_ready, busy,
                         (skipped != 32'd0), (dropped != 32'd0), ready_buf, ready};
            regs[13] <= {{(32-ADDR_BITS){1'b0}}, ready_count};
            regs[14] <= dropped;
            regs[15] <= ts_snap[31:0];
            regs[16] <= {{(32-(TS_WIDTH-32)){1'b0}}, ts_snap[TS_WIDTH-1:32]};
            regs[17] <= total_events[31:0];
            regs[18] <= {{(32-(TS_WIDTH-32)){1'b0}}, total_events[TS_WIDTH-1:32]};
            regs[19] <= skipped;
            regs[20] <= {{(32-E_WIDTH-DIR_WIDTH){1'b0}}, dir_now, energy_now};
        end
    end

    // ----------------------------
    // AXI read channel (tiny)
    // ----------------------------
    reg arready, rvalid;
    reg [1:0] rresp;
    reg [31:0] rdata;
    reg [C_S_AXI_ADDR_WIDTH-1:0] araddr_q;

    assign s_axi_arready = arready;
    assign s_axi_rvalid  = rvalid;
    assign s_axi_rresp   = rresp;
    assign s_axi_rdata   = rdata;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            arready <= 1'b0; rvalid <= 1'b0; rresp <= RESP_OK; rdata <= 32'd0; araddr_q <= 0;
        end else begin
            arready <= (!arready && s_axi_arvalid);
            if (!arready && s_axi_arvalid) araddr_q <= s_axi_araddr;

            if (!rvalid && arready && s_axi_arvalid) begin
                rvalid <= 1'b1; rresp <= RESP_OK;
                rdata <= regs[araddr_q[ADDR_LSB +: LOG_NPAR]];
            end else if (rvalid && s_axi_rready) begin
                rvalid <= 1'b0;
            end
        end
    end

    // ---------------------------------------------------------
    // USER MAP BEGIN  (name your registers here)
    // ---------------------------------------------------------
    wire        [31:0] control     = regs[0];        // +0x00
    wire               arm         = control[0];
    wire               clear_ts    = control[1];
    wire               ctrl_reset  = control[2];
    wire               snap        = control[3];
    wire               ack         = control[4];
    wire [ADDR_BITS-1:0] frame_len = regs[1][ADDR_BITS-1:0];   // +0x04
    wire        [31:0] flush_ticks = regs[2];                  // +0x08
    wire         [3:0] log_n_avg   = regs[3][3:0];             // +0x0C
    wire [DLY_WIDTH-1:0] n_delay   = regs[4][DLY_WIDTH-1:0];   // +0x10
    wire [DLY_WIDTH-1:0] trig_dead = regs[5][DLY_WIDTH-1:0];   // +0x14
    wire signed [DATA_WIDTH-1:0] dir_thr_pos = regs[6][DATA_WIDTH-1:0];  // +0x18
    wire signed [DATA_WIDTH-1:0] dir_thr_neg = regs[7][DATA_WIDTH-1:0];  // +0x1C
    wire         [3:0] trig_sel    = regs[8][3:0];             // +0x20
    wire               trig_invert = regs[8][4];

    // (the module's read-only outputs are declared above the register bank)

    // clock/reset (simple: tie to AXI, plus soft reset bit)
    wire fclk = s_axi_aclk;
    wire frst = ~s_axi_aresetn | ctrl_reset;

    // ---------------------------------------------------------
    // USER INSTANTIATION BEGIN (drop your module here)
    // ---------------------------------------------------------
    trig_logger #(
        .TS_WIDTH    (TS_WIDTH),
        .E_WIDTH     (E_WIDTH),
        .DIR_WIDTH   (DIR_WIDTH),
        .REC_WIDTH   (REC_WIDTH),
        .ADDR_BITS   (ADDR_BITS),
        .DATA_WIDTH  (DATA_WIDTH),
        .MAX_LOG_AVG (MAX_LOG_AVG),
        .TRIG_BUS_W  (TRIG_BUS_W),
        .DLY_WIDTH   (DLY_WIDTH)
    ) u_trig_logger (
        .clk          (fclk),
        .rst          (frst),
        .arm          (arm),
        .clear_ts     (clear_ts),
        .frame_len    (frame_len),
        .flush_ticks  (flush_ticks),
        .log_n_avg    (log_n_avg),
        .n_delay      (n_delay),
        .trig_dead    (trig_dead),
        .dir_thr_pos  (dir_thr_pos),
        .dir_thr_neg  (dir_thr_neg),
        .trig_sel     (trig_sel),
        .trig_invert  (trig_invert),
        .snap         (snap),
        .ack          (ack),
        .x_in         (x_in),
        .dir_in       (dir_in),
        .trig_bus     (trig_bus),
        .bram_addr    (bram_addr),
        .bram_din     (bram_din),
        .bram_en      (bram_en),
        .bram_we      (bram_we),
        .ready        (ready),
        .ready_buf    (ready_buf),
        .ready_count  (ready_count),
        .dropped      (dropped),
        .skipped      (skipped),
        .ts_snap      (ts_snap),
        .total_events (total_events),
        .busy         (busy),
        .avg_ready    (avg_ready),
        .trig_level   (trig_level),
        .energy_now   (energy_now),
        .dir_now      (dir_now)
    );

endmodule
