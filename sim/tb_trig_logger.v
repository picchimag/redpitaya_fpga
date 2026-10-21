`timescale 1 ns / 1 ps
//
// Self-checking testbench for trig_logger.
// Checks: boxcar correctness + priming, direction coding, record packing,
// n_delay timing, trig_dead holdoff, skipped counting, ping-pong + ack.
//
module tb_trig_logger;

    localparam integer TSW   = 46;
    localparam integer AB    = 5;    // 32 record words -> 16 per buffer
    localparam integer MLA   = 4;    // max boxcar 16 samples (fast priming)
    localparam integer DW    = 16;

    reg clk = 0, rst = 1;
    always #4 clk = ~clk;            // 125 MHz

    reg                arm = 0, clear_ts = 0, snap = 0, ack = 0;
    reg [AB-1:0]       frame_len = 4;
    reg [31:0]         flush_ticks = 0;
    reg [3:0]          log_n_avg = 2;         // n_avg = 4
    reg [31:0]         n_delay = 10, trig_dead = 5;
    reg signed [DW-1:0] dir_thr_pos = 100, dir_thr_neg = -100;
    reg [3:0]          trig_sel = 0;
    reg                trig_invert = 0;
    reg signed [DW-1:0] x_in = 0, dir_in = 0;
    reg [15:0]         trig_bus = 0;

    wire [AB-1:0]  bram_addr;
    wire [63:0]    bram_din;
    wire           bram_en;
    wire [7:0]     bram_we;
    wire           ready, ready_buf, busy, avg_ready, trig_level;
    wire [AB-1:0]  ready_count;
    wire [31:0]    dropped, skipped;
    wire [TSW-1:0] ts_snap, total_events;
    wire signed [15:0] energy_now;
    wire [1:0]     dir_now;

    trig_logger #(
        .TS_WIDTH(TSW), .E_WIDTH(16), .DIR_WIDTH(2), .REC_WIDTH(64),
        .ADDR_BITS(AB), .DATA_WIDTH(DW), .MAX_LOG_AVG(MLA),
        .TRIG_BUS_W(16), .DLY_WIDTH(32)
    ) dut (
        .clk(clk), .rst(rst),
        .arm(arm), .clear_ts(clear_ts), .frame_len(frame_len),
        .flush_ticks(flush_ticks), .log_n_avg(log_n_avg),
        .n_delay(n_delay), .trig_dead(trig_dead),
        .dir_thr_pos(dir_thr_pos), .dir_thr_neg(dir_thr_neg),
        .trig_sel(trig_sel), .trig_invert(trig_invert),
        .snap(snap), .ack(ack),
        .x_in(x_in), .dir_in(dir_in), .trig_bus(trig_bus),
        .bram_addr(bram_addr), .bram_din(bram_din),
        .bram_en(bram_en), .bram_we(bram_we),
        .ready(ready), .ready_buf(ready_buf), .ready_count(ready_count),
        .dropped(dropped), .skipped(skipped),
        .ts_snap(ts_snap), .total_events(total_events),
        .busy(busy), .avg_ready(avg_ready), .trig_level(trig_level),
        .energy_now(energy_now), .dir_now(dir_now)
    );

    // ---- capture every BRAM write ----
    reg [63:0] cap_data [0:63];
    reg [AB-1:0] cap_addr [0:63];
    integer      cap_n = 0;
    always @(posedge clk) if (bram_en && bram_we[0]) begin
        cap_data[cap_n] = bram_din;
        cap_addr[cap_n] = bram_addr;
        cap_n = cap_n + 1;
    end

    integer errors = 0;
    task check(input cond, input [255:0] name);
        begin
            if (cond) $display("  PASS  %0s", name);
            else begin $display("  FAIL  %0s", name); errors = errors + 1; end
        end
    endtask

    // record field extractors (mirror of the host-side unpack)
    function [TSW-1:0] f_ts (input [63:0] r); f_ts = r[TSW-1:0]; endfunction
    function signed [2:0] f_dir(input [63:0] r);
        f_dir = (r[47:46] == 2'b01) ? 3'sd1 : ((r[47:46] == 2'b11) ? -3'sd1 : 3'sd0);
    endfunction
    function signed [15:0] f_e (input [63:0] r); f_e = r[63:48]; endfunction

    integer i;
    reg [TSW-1:0] t_edge;
    reg [31:0]    sk0;

    task pulse_trig; begin
        @(negedge clk) trig_bus[0] = 1;
        repeat (3) @(negedge clk);
        trig_bus[0] = 0;
    end endtask

    initial begin
        $display("=== trig_logger testbench ===");
        repeat (4) @(negedge clk);
        rst = 0;

        // ---------------------------------------------------------
        // 1. boxcar: constant input -> average equals it, after priming
        // ---------------------------------------------------------
        x_in = 1000;
        check(avg_ready === 1'b0, "avg_ready low right after reset");
        repeat (20) @(negedge clk);
        check(avg_ready === 1'b1, "avg_ready high after priming");
        check(energy_now === 16'sd1000, "boxcar of constant 1000 == 1000");

        // step to 2000: after 4 samples the window is all 2000
        x_in = 2000;
        repeat (3) @(negedge clk);        // partial window
        check(energy_now !== 16'sd2000, "boxcar still settling mid-step");
        repeat (10) @(negedge clk);
        check(energy_now === 16'sd2000, "boxcar of constant 2000 == 2000");

        // known 4-sample window: 100,200,300,400 -> 250.
        // The window is complete 3 cycles after the last sample is driven
        // (input register -> delay-line read -> sum update), and it has moved
        // on again one cycle later, so dump the neighbourhood to be sure.
        x_in = 100; @(negedge clk);
        x_in = 200; @(negedge clk);
        x_in = 300; @(negedge clk);
        x_in = 400; @(negedge clk);
        for (i = 1; i <= 6; i = i + 1) begin
            $display("    +%0d cycles after the last sample: energy_now = %0d",
                     i, energy_now);
            if (i == 3)
                check(energy_now === 16'sd250, "boxcar of 100/200/300/400 == 250");
            @(negedge clk);
        end

        // negative input (arithmetic shift, not logical)
        x_in = -800;
        repeat (10) @(negedge clk);
        check(energy_now === -16'sd800, "boxcar of -800 == -800 (arithmetic)");

        // ---------------------------------------------------------
        // 2. window change re-primes
        // ---------------------------------------------------------
        log_n_avg = 3;                    // n_avg = 8
        @(negedge clk);
        check(avg_ready === 1'b0, "log_n_avg change drops avg_ready");
        repeat (20) @(negedge clk);
        check(avg_ready === 1'b1, "avg_ready back after re-prime");
        check(energy_now === -16'sd800, "boxcar correct with n_avg=8");
        log_n_avg = 2;
        repeat (20) @(negedge clk);

        // clamp above MAX_LOG_AVG
        log_n_avg = 9;                    // > MLA=4, must clamp to 4
        repeat (40) @(negedge clk);
        check(dut.log_avg_reg === 4'd4, "log_n_avg clamped to MAX_LOG_AVG");
        check(energy_now === -16'sd800, "boxcar correct at clamped window");
        log_n_avg = 2;
        repeat (20) @(negedge clk);

        // ---------------------------------------------------------
        // 3. direction coding
        // ---------------------------------------------------------
        dir_in = 500;  @(negedge clk); check(dir_now === 2'b01, "dir +1 above dir_thr_pos");
        dir_in = -500; @(negedge clk); check(dir_now === 2'b11, "dir -1 below dir_thr_neg");
        dir_in = 0;    @(negedge clk); check(dir_now === 2'b00, "dir 0 inside the dead zone");
        dir_in = 100;  @(negedge clk); check(dir_now === 2'b01, "dir +1 exactly at dir_thr_pos");

        // ---------------------------------------------------------
        // 4. triggers while disarmed are ignored entirely
        // ---------------------------------------------------------
        x_in = 4000; dir_in = -500;
        repeat (10) @(negedge clk);
        pulse_trig;
        repeat (30) @(negedge clk);
        check(cap_n == 0,            "no record while disarmed");
        check(skipped === 32'd0,     "skipped not counted while disarmed");

        // ---------------------------------------------------------
        // 5. armed trigger -> one record, n_delay later, right fields
        // ---------------------------------------------------------
        arm = 1;
        repeat (5) @(negedge clk);
        @(negedge clk) trig_bus[0] = 1;
        t_edge = dut.ts;                  // counter around the edge
        repeat (3) @(negedge clk) ;
        trig_bus[0] = 0;
        repeat (40) @(negedge clk);

        check(cap_n == 1, "exactly one record for one trigger");
        check(f_e(cap_data[0])   === 16'sd4000, "record energy == boxcar value");
        check(f_dir(cap_data[0]) === -3'sd1,    "record direction == -1");
        check(f_ts(cap_data[0]) >= t_edge && f_ts(cap_data[0]) <= t_edge + 4,
              "record timestamp is the trigger instant, not the write instant");
        check(cap_addr[0] === 0, "first record at buffer 0 index 0");
        check(total_events === 1, "total_events == 1");

        // ---------------------------------------------------------
        // 6. a trigger during the n_delay wait is skipped, not logged
        // ---------------------------------------------------------
        sk0 = skipped;
        @(negedge clk) trig_bus[0] = 1;
        repeat (2) @(negedge clk);
        trig_bus[0] = 0;
        repeat (2) @(negedge clk);        // still inside n_delay = 10
        check(busy === 1'b1, "busy during the n_delay wait");
        trig_bus[0] = 1;                  // second edge, must be skipped
        repeat (2) @(negedge clk);
        trig_bus[0] = 0;
        repeat (40) @(negedge clk);
        check(cap_n == 2,                "re-trigger during the wait adds no record");
        check(skipped === sk0 + 1,       "re-trigger during the wait counted in skipped");

        // ---------------------------------------------------------
        // 7. energy is sampled at n_delay, not at the trigger
        // ---------------------------------------------------------
        x_in = 1024; repeat (20) @(negedge clk);
        n_delay = 60;                     // >> boxcar settling
        repeat (3) @(negedge clk);
        @(negedge clk) trig_bus[0] = 1;
        repeat (2) @(negedge clk);
        trig_bus[0] = 0;
        x_in = 8000;                      // changes well before the latch
        repeat (80) @(negedge clk);
        check(cap_n == 3, "third record written");
        check(f_e(cap_data[2]) === 16'sd8000,
              "energy latched n_delay after the trigger, not at the trigger");
        n_delay = 10;

        // ---------------------------------------------------------
        // 8. fill a buffer -> ready, ready_count, ack drains it
        // ---------------------------------------------------------
        check(ready === 1'b0, "not ready before frame_len records");
        trig_dead = 2;
        @(negedge clk) trig_bus[0] = 1; repeat (2) @(negedge clk); trig_bus[0] = 0;
        repeat (40) @(negedge clk);       // 4th record -> buffer full
        check(cap_n == 4, "fourth record written");
        check(ready === 1'b1, "ready after frame_len records");
        check(ready_count === 4, "ready_count == frame_len");
        check(ready_buf === 1'b0, "ready_buf == 0 for the first buffer");

        ack = 1; repeat (2) @(negedge clk); ack = 0;
        repeat (4) @(negedge clk);
        check(ready === 1'b0, "ack clears ready");

        // next record must land in buffer 1 (MSB of the address set)
        @(negedge clk) trig_bus[0] = 1; repeat (2) @(negedge clk); trig_bus[0] = 0;
        repeat (40) @(negedge clk);
        check(cap_n == 5, "fifth record written");
        check(cap_addr[4][AB-1] === 1'b1, "ping-pong swapped to buffer 1");
        check(dropped === 32'd0, "nothing dropped");

        // ---------------------------------------------------------
        // 9. snap gives a coherent counter read
        // ---------------------------------------------------------
        snap = 1; @(negedge clk); snap = 0;
        t_edge = ts_snap;
        repeat (10) @(negedge clk);
        check(ts_snap === t_edge, "ts_snap holds until the next snap");
        check(ts_snap !== 0,      "ts_snap is non-zero");

        // ---------------------------------------------------------
        // 10. trig_invert selects the falling edge
        // ---------------------------------------------------------
        trig_invert = 1; trig_bus[0] = 1;
        repeat (6) @(negedge clk);
        i = cap_n;
        @(negedge clk) trig_bus[0] = 0;   // falling edge on the pin
        repeat (40) @(negedge clk);
        check(cap_n == i + 1, "trig_invert triggers on the falling edge");
        trig_invert = 0; trig_bus[0] = 0;
        repeat (5) @(negedge clk);

        // ---------------------------------------------------------
        // 11. trig_sel picks another pin
        // ---------------------------------------------------------
        trig_sel = 7;
        repeat (5) @(negedge clk);
        i = cap_n;
        @(negedge clk) trig_bus[0] = 1; repeat (3) @(negedge clk); trig_bus[0] = 0;
        repeat (30) @(negedge clk);
        check(cap_n == i, "pin 0 ignored once trig_sel moved");
        @(negedge clk) trig_bus[7] = 1; repeat (3) @(negedge clk); trig_bus[7] = 0;
        repeat (40) @(negedge clk);
        check(cap_n == i + 1, "trig_sel=7 triggers on pin 7");

        // ---------------------------------------------------------
        // Dump every captured record so the host-side unpack() can be
        // checked against what the RTL actually packed (see
        // sim/check_records.py). This is the exact mismatch that bit the
        // event_logger v1/v2 record layout.
        // ---------------------------------------------------------
        begin : dump
            integer fd;
            fd = $fopen("records.hex", "w");
            for (i = 0; i < cap_n; i = i + 1)
                $fwrite(fd, "%016x\n", cap_data[i]);
            $fclose(fd);
            $display("wrote %0d records to records.hex", cap_n);
        end

        $display("=== %0d error(s) ===", errors);
        if (errors == 0) $display("ALL CHECKS PASSED");
        $finish;
    end

    initial begin
        #2000000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
