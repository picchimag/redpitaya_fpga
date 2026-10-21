`timescale 1 ns / 1 ps
//
// AXI4-Lite level testbench for trig_logger_axi_wrap.
//
// The wrapper changes the house template's register geometry (LOG_NPAR 4 -> 5,
// N_READONLY 8 -> 20), so this checks the part that arithmetic affects: which
// registers accept writes, which are read-only, that every field reaches the
// module, and that the read-only words report the module's real state.
//
module tb_trig_logger_axi;

    localparam integer AW = 8;
    localparam integer DW = 32;

    reg clk = 0, aresetn = 0;
    always #4 clk = ~clk;                      // 125 MHz

    reg  [AW-1:0] awaddr = 0, araddr = 0;
    reg           awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    reg  [DW-1:0] wdata = 0;
    reg  [3:0]    wstrb = 4'hF;
    wire          awready, wready, bvalid, arready, rvalid;
    wire [1:0]    bresp, rresp;
    wire [DW-1:0] rdata;

    reg signed [15:0] x_in = 0, dir_in = 0;
    reg       [15:0]  trig_bus = 0;
    wire [12:0] bram_addr;
    wire [63:0] bram_din;
    wire        bram_en;
    wire [7:0]  bram_we;

    trig_logger_axi_wrap #(
        .C_S_AXI_ADDR_WIDTH(AW), .C_S_AXI_DATA_WIDTH(DW),
        .LOG_NPAR(5), .MAX_LOG_AVG(4)          // small boxcar: primes fast
    ) dut (
        .s_axi_aclk(clk), .s_axi_aresetn(aresetn),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid),
        .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid),
        .s_axi_rready(rready),
        .x_in(x_in), .dir_in(dir_in), .trig_bus(trig_bus),
        .bram_addr(bram_addr), .bram_din(bram_din),
        .bram_en(bram_en), .bram_we(bram_we)
    );

    integer errors = 0;
    task check(input cond, input [255:0] name);
        begin
            if (cond) $display("  PASS  %0s", name);
            else begin $display("  FAIL  %0s", name); errors = errors + 1; end
        end
    endtask

    // ---- minimal AXI4-Lite master ----
    task axi_write(input [AW-1:0] a, input [DW-1:0] d);
        begin
            @(posedge clk);
            awaddr <= a; wdata <= d; awvalid <= 1; wvalid <= 1; bready <= 1;
            wait (awready && wready);
            @(posedge clk);
            awvalid <= 0; wvalid <= 0;
            wait (bvalid);
            @(posedge clk);
            bready <= 0;
            @(posedge clk);
        end
    endtask

    task axi_read(input [AW-1:0] a, output [DW-1:0] d);
        begin
            @(posedge clk);
            araddr <= a; arvalid <= 1; rready <= 1;
            wait (arready);
            @(posedge clk);
            arvalid <= 0;
            wait (rvalid);
            d = rdata;
            @(posedge clk);
            rready <= 0;
            @(posedge clk);
        end
    endtask

    // register offsets (must match config/trig_logger.json)
    localparam CONTROL = 8'h00, FRAME_LEN = 8'h04, FLUSH = 8'h08,
               LOG_AVG = 8'h0C, N_DELAY = 8'h10, TRIG_DEAD = 8'h14,
               THR_POS = 8'h18, THR_NEG = 8'h1C, TRIG_CFG = 8'h20,
               STATUS  = 8'h30, RDY_CNT = 8'h34, DROPPED = 8'h38,
               SNAP_LO = 8'h3C, SNAP_HI = 8'h40, EVT_LO = 8'h44,
               EVT_HI  = 8'h48, SKIPPED = 8'h4C, LIVE = 8'h50;

    reg [DW-1:0] d;
    integer i;

    initial begin
        $display("=== trig_logger_axi_wrap testbench ===");
        repeat (4) @(posedge clk);
        aresetn = 1;
        repeat (4) @(posedge clk);

        // ---- writable registers round-trip ----
        axi_write(FRAME_LEN, 32'd1234);  axi_read(FRAME_LEN, d);
        check(d[12:0] == 13'd1234, "frame_len round-trips");
        axi_write(FLUSH, 32'h0BEEF000);  axi_read(FLUSH, d);
        check(d == 32'h0BEEF000, "flush_ticks round-trips (full 32 bits)");
        axi_write(N_DELAY, 32'd125000);  axi_read(N_DELAY, d);
        check(d == 32'd125000, "n_delay round-trips");
        axi_write(TRIG_DEAD, 32'd999);   axi_read(TRIG_DEAD, d);
        check(d == 32'd999, "trig_dead round-trips");
        axi_write(THR_POS, 32'h00003000); axi_read(THR_POS, d);
        check(d[15:0] == 16'h3000, "dir_thr_pos round-trips");
        axi_write(THR_NEG, 32'h0000D000); axi_read(THR_NEG, d);
        check(d[15:0] == 16'hD000, "dir_thr_neg round-trips (negative)");
        axi_write(TRIG_CFG, 32'h0000001A); axi_read(TRIG_CFG, d);
        check(d[4:0] == 5'h1A, "trig_cfg round-trips (trig_sel=10, invert=1)");

        // ---- the top regs must reject writes (N_READONLY = 20) ----
        axi_read(STATUS, d); i = d;
        axi_write(STATUS, 32'hFFFFFFFF);
        axi_read(STATUS, d);
        check(d != 32'hFFFFFFFF, "status (regs[12]) rejects writes");
        axi_write(SKIPPED, 32'hFFFFFFFF);
        axi_read(SKIPPED, d);
        check(d == 32'd0, "skipped (regs[19]) rejects writes");
        axi_write(8'h7C, 32'hFFFFFFFF);          // regs[31], top of the bank
        axi_read(8'h7C, d);
        check(d == 32'd0, "regs[31] rejects writes");
        // regs[11] is the last writable one -- it must still accept
        axi_write(8'h2C, 32'hA5A5A5A5);
        axi_read(8'h2C, d);
        check(d == 32'hA5A5A5A5, "regs[11] is still writable (boundary)");

        // ---- byte strobes ----
        axi_write(N_DELAY, 32'h00000000);
        wstrb = 4'b0001;
        axi_write(N_DELAY, 32'hFFFFFF77);
        wstrb = 4'hF;
        axi_read(N_DELAY, d);
        check(d == 32'h00000077, "wstrb masks the write to one byte lane");

        // ---- configure for real and check the module responds ----
        axi_write(LOG_AVG,   32'd2);             // n_avg = 4
        axi_write(FRAME_LEN, 32'd4);
        axi_write(N_DELAY,   32'd10);
        axi_write(TRIG_DEAD, 32'd4);
        axi_write(THR_POS,   32'd100);
        axi_write(THR_NEG,   32'hFFFF_FF9C);     // -100
        axi_write(TRIG_CFG,  32'd0);             // trig_sel=0, no invert
        axi_write(FLUSH,     32'd0);

        x_in = 2000; dir_in = 500;
        repeat (40) @(posedge clk);
        axi_read(STATUS, d);
        check(d[5] == 1'b1, "status.avg_ready set once the boxcar primed");
        axi_read(LIVE, d);
        check(d[15:0] == 16'd2000, "live.energy_now == boxcar output");
        check(d[17:16] == 2'b01,   "live.dir_now == +1");

        dir_in = -500; repeat (4) @(posedge clk);
        axi_read(LIVE, d);
        check(d[17:16] == 2'b11, "live.dir_now == -1 after IN2 goes negative");

        trig_bus[0] = 1; repeat (3) @(posedge clk);
        axi_read(STATUS, d);
        check(d[6] == 1'b1, "status.trig_level follows the pin");
        trig_bus[0] = 0; repeat (3) @(posedge clk);
        axi_read(STATUS, d);
        check(d[6] == 1'b0, "status.trig_level clears with the pin");

        // ---- arm, trigger, and watch the counters move ----
        axi_write(CONTROL, 32'h1);                // arm
        repeat (10) @(posedge clk);
        trig_bus[0] = 1; repeat (3) @(posedge clk); trig_bus[0] = 0;
        repeat (60) @(posedge clk);
        axi_read(EVT_LO, d);
        check(d == 32'd1, "events_lo == 1 after one trigger");
        axi_read(DROPPED, d);
        check(d == 32'd0, "dropped == 0");
        axi_read(SKIPPED, d);
        check(d == 32'd0, "skipped == 0");

        // ---- snap latches a non-zero counter, and holds ----
        axi_write(CONTROL, 32'h1 | 32'h8);        // arm + snap
        repeat (2) @(posedge clk);
        axi_write(CONTROL, 32'h1);                // drop snap
        axi_read(SNAP_LO, d); i = d;
        check(d != 32'd0, "ts_snap_lo is non-zero");
        axi_read(SNAP_HI, d);
        check(d == 32'd0, "ts_snap_hi still 0 this early in the run");
        repeat (50) @(posedge clk);
        axi_read(SNAP_LO, d);
        check(d == i, "ts_snap holds until the next snap");

        // ---- disarm ----
        axi_write(CONTROL, 32'h0);
        repeat (5) @(posedge clk);
        axi_read(STATUS, d);
        check(d[4] == 1'b0, "busy clear once disarmed");

        $display("=== %0d error(s) ===", errors);
        if (errors == 0) $display("ALL CHECKS PASSED");
        $finish;
    end

    initial begin
        #500000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
