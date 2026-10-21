/**
 * @module trig_logger
 * @brief Digital-triggered 3-channel event logger (ping-pong BRAM)
 *
 * Reads three inputs and, on every accepted digital trigger, writes one
 * 64-bit record into the active BRAM buffer:
 *
 *     record[45:0]   = timestamp  (clock cycles, 8 ns at 125 MHz)
 *     record[47:46]  = direction  (signed 2-bit: 00 = 0, 01 = +1, 11 = -1)
 *     record[63:48]  = energy     (signed 16-bit boxcar average)
 *
 *   TS_WIDTH + DIR_WIDTH + E_WIDTH = 46 + 2 + 16 = 64, exactly one BRAM word.
 *
 * Inputs
 *   x_in     fast ADC channel A (IN1) -- energy signal, signed 16-bit
 *   dir_in   fast ADC channel B (IN2) -- piezo direction, signed 16-bit
 *   trig_bus expansion-connector digital pins; trig_sel picks one bit
 *
 * Energy path: boxcar moving average of the last n_avg = 2^log_n_avg samples
 * of x_in. Running sum plus a BRAM delay line, so the divide is a right shift
 * (exact, no divider). The window is primed after reset and after log_n_avg
 * changes: x_old is forced to 0 for the first n_avg samples, so the sum is a
 * true n_avg-sample sum once avg_ready rises. Triggers before avg_ready are
 * rejected, so no record ever carries a half-filled window.
 *
 * Time base: one free-running TS_WIDTH-bit counter at the processing clock,
 * i.e. the timestamp IS the clock-cycle count (8 ns ticks at 125 MHz). No
 * prescaler. 2^46 cycles = 5.6e5 s = 6.5 days before wrap, so a run longer
 * than that needs the host to unwrap the rollover (the tie-point stream makes
 * that unambiguous). Do NOT assert clear_ts mid-run.
 *
 * Trigger: trig_bus[trig_sel] is XORed with trig_invert, 2FF-synchronised and
 * rising-edge detected. On an accepted edge the module latches the timestamp
 * and the direction code immediately, then counts n_delay clock cycles and
 * latches the boxcar output; the record is written on that cycle. Edges
 * arriving during the n_delay wait, or during the trig_dead holdoff that
 * follows a write, are ignored and counted in skipped -- n_delay + trig_dead
 * is therefore the dead time of the module.
 *
 * Reconfiguration: n_delay and trig_dead are sampled continuously, so
 * shrinking either one while the FSM is counting against it would make the
 * counter run to its 32-bit wrap (~34 s) before escaping. Disarm first --
 * !arm forces S_IDLE -- which is what TrigLogger.configure() does.
 *
 * Note on when the energy is really sampled: the boxcar costs 3 clock cycles
 * of pipeline (input register, delay-line read, sum update), so the latched
 * value is the average of the n_avg samples ending ~3 cycles before the
 * n_delay deadline. Fold that into n_delay if it matters at your pulse shape.
 *
 * Direction: dir_in is compared against two thresholds -- at or above
 * dir_thr_pos gives +1, at or below dir_thr_neg gives -1, anything between
 * gives 0 (pos wins if the two thresholds are crossed over). Both reset to 0,
 * so the default behaviour is a hard sign test with no dead zone around zero.
 *
 * Ping-pong: two buffers share one BRAM (buffer = MSB of the write address).
 * While one fills, the PS drains the other; on fill (or flush timeout) they
 * swap, so capture never stops. A full buffer whose predecessor has not yet
 * been acked is held, not overwritten; only records arriving while BOTH
 * buffers are occupied are lost, and those are counted in dropped.
 *
 * Tie-points: writing snap=1 latches the live counter into ts_snap, so the PS
 * can read a coherent 46-bit value (no 32-bit read tearing) and pair it with
 * its NTP wall-clock time to calibrate absolute time and crystal drift
 * offline. Same scheme as event_logger -- the host keeps writing tiepoints.csv.
 */

`timescale 1 ns / 1 ps

module trig_logger #(
    parameter integer TS_WIDTH    = 46,   // cycle counter width (2^46 cycles ~ 6.5 days @125 MHz)
    parameter integer E_WIDTH     = 16,   // stored energy width (signed boxcar average)
    parameter integer DIR_WIDTH   = 2,    // direction code width
    parameter integer REC_WIDTH   = 64,   // BRAM word = TS_WIDTH + DIR_WIDTH + E_WIDTH = 64
    parameter integer ADDR_BITS   = 13,   // total record BRAM depth = 2^ADDR_BITS words (2 buffers)
    parameter integer DATA_WIDTH  = 16,   // ADC sample width
    parameter integer MAX_LOG_AVG = 11,   // log_n_avg ceiling (11 -> 2048 samples, 16.4 us)
    parameter integer TRIG_BUS_W  = 16,   // digital trigger candidates (exp_p[7:0] ++ exp_n[7:0])
    parameter integer DLY_WIDTH   = 32    // width of n_delay / trig_dead
)(
    input  wire                       clk,        // processing clock (= s_axi_aclk, 125 MHz)
    input  wire                       rst,        // active-high reset

    // ---- control (from AXI regs) ----
    input  wire                       arm,        // 1 = logging enabled
    input  wire                       clear_ts,   // reset the cycle counter
    input  wire [ADDR_BITS-1:0]       frame_len,  // records per buffer before swap (1..2^(ADDR_BITS-1);
                                                  // last_idx = frame_len-1 truncated to IDX_BITS, so the
                                                  // maximum 4096 and 0 both mean "fill the buffer")
    input  wire [31:0]                flush_ticks,// clock cycles before a forced swap of a partial buffer (0 = never)
    input  wire [3:0]                 log_n_avg,  // n_avg = 2^log_n_avg, clamped to MAX_LOG_AVG
    input  wire [DLY_WIDTH-1:0]       n_delay,    // clock cycles from trigger to energy latch
    input  wire [DLY_WIDTH-1:0]       trig_dead,  // holdoff cycles after a record is written
    input  wire signed [DATA_WIDTH-1:0] dir_thr_pos, // dir_in at or above this -> +1
    input  wire signed [DATA_WIDTH-1:0] dir_thr_neg, // dir_in at or below this -> -1
    input  wire [3:0]                 trig_sel,   // which trig_bus bit is the trigger
    input  wire                       trig_invert,// 1 = trigger on the falling edge of the pin
    input  wire                       snap,       // rising edge latches counter into ts_snap
    input  wire                       ack,        // PS acknowledges it has drained ready_buf

    // ---- data inputs ----
    input  wire signed [DATA_WIDTH-1:0] x_in,     // IN1, energy
    input  wire signed [DATA_WIDTH-1:0] dir_in,   // IN2, piezo direction
    input  wire [TRIG_BUS_W-1:0]      trig_bus,   // digital inputs (asynchronous)

    // ---- BRAM Port-B (Port-A -> AXI BRAM Ctrl / CDMA source for PS reads) ----
    output reg  [ADDR_BITS-1:0]       bram_addr,  // {buffer, index}
    output reg  [REC_WIDTH-1:0]       bram_din,
    output reg                        bram_en,
    output reg  [(REC_WIDTH/8)-1:0]   bram_we,

    // ---- status (to AXI readonly regs) ----
    output reg                        ready,       // a full buffer is waiting for the PS
    output reg                        ready_buf,   // which buffer (0/1) is ready
    output reg  [ADDR_BITS-1:0]       ready_count, // valid records in the ready buffer
    output reg  [31:0]                dropped,     // records lost (both buffers occupied)
    output reg  [31:0]                skipped,     // triggers ignored (busy / dead / not primed)
    output reg  [TS_WIDTH-1:0]        ts_snap,     // latched counter (tie-point read)
    output reg  [TS_WIDTH-1:0]        total_events,// lifetime written-record count
    output wire                       busy,        // in the n_delay wait or the holdoff
    output wire                       avg_ready,   // boxcar window is primed
    output wire                       trig_level,  // synchronised trigger pin state
    output wire signed [E_WIDTH-1:0]  energy_now,  // live boxcar output
    output wire [DIR_WIDTH-1:0]       dir_now      // live direction code
);

    localparam integer BYTE_LANES = REC_WIDTH/8;
    localparam integer IDX_BITS   = ADDR_BITS - 1;            // per-buffer index width
    // The delay line is one power of two deeper than the largest window, so the
    // read pointer can never land on the address being written this cycle --
    // no reliance on inferred-BRAM read-before-write behaviour.
    localparam integer LINE_BITS  = MAX_LOG_AVG + 1;
    localparam integer LINE_DEPTH = (1 << LINE_BITS);
    localparam integer SUM_WIDTH  = DATA_WIDTH + MAX_LOG_AVG; // |sum| <= 2^(W-1) * n_avg

    // ---- register control inputs (timing) ----
    reg [IDX_BITS-1:0]          last_idx;          // frame_len-1, per buffer
    reg signed [DATA_WIDTH-1:0] thr_pos_reg, thr_neg_reg;
    reg [3:0]                   log_avg_reg;
    reg [LINE_BITS-1:0]         n_avg_reg;         // 2^log_avg_reg
    reg [3:0]                   trig_sel_reg;
    reg                         trig_inv_reg;
    reg [DLY_WIDTH-1:0]         n_delay_reg, trig_dead_reg;

    wire [3:0] log_avg_clamped = (log_n_avg > MAX_LOG_AVG) ? MAX_LOG_AVG[3:0] : log_n_avg;
    // Changing the window length invalidates the running sum -> re-prime.
    wire       avg_clr         = (log_avg_clamped != log_avg_reg);

    always @(posedge clk) begin
        if (rst) begin
            last_idx      <= {IDX_BITS{1'b0}};
            thr_pos_reg   <= {DATA_WIDTH{1'b0}};
            thr_neg_reg   <= {DATA_WIDTH{1'b0}};
            log_avg_reg   <= 4'd0;
            n_avg_reg     <= {{(LINE_BITS-1){1'b0}}, 1'b1};
            trig_sel_reg  <= 4'd0;
            trig_inv_reg  <= 1'b0;
            n_delay_reg   <= {DLY_WIDTH{1'b0}};
            trig_dead_reg <= {DLY_WIDTH{1'b0}};
        end else begin
            last_idx      <= frame_len[IDX_BITS-1:0] - 1'b1;
            thr_pos_reg   <= dir_thr_pos;
            thr_neg_reg   <= dir_thr_neg;
            log_avg_reg   <= log_avg_clamped;
            n_avg_reg     <= {{(LINE_BITS-1){1'b0}}, 1'b1} << log_avg_clamped;
            trig_sel_reg  <= trig_sel;
            trig_inv_reg  <= trig_invert;
            n_delay_reg   <= n_delay;
            trig_dead_reg <= trig_dead;
        end
    end

    // ---- free-running cycle counter (the timestamp itself) ----
    reg [TS_WIDTH-1:0] ts;
    always @(posedge clk) begin
        if (rst || clear_ts) ts <= {TS_WIDTH{1'b0}};
        else                 ts <= ts + 1'b1;
    end

    // ---- snapshot for a coherent 46-bit tie-point read ----
    reg snap_d;
    always @(posedge clk) begin
        if (rst) begin snap_d <= 1'b0; ts_snap <= {TS_WIDTH{1'b0}}; end
        else begin
            snap_d <= snap;
            if (snap & ~snap_d) ts_snap <= ts;   // rising edge latches
        end
    end

    // ---------------------------------------------------------------
    // Boxcar moving average of x_in over n_avg = 2^log_avg_reg samples
    //
    //   k   : x_s registered; line[wr_ptr] <= x_s; x_old <= line[rd_ptr]
    //   k+1 : x_old = x_s(k - n_avg), x_s_d = x_s(k)
    //   k+2 : sum  += x_s_d - x_old
    //
    // While priming (the first n_avg samples after reset or a window change)
    // x_old is forced to 0, so the sum fills up to a complete window instead
    // of subtracting stale delay-line contents.
    // ---------------------------------------------------------------
    reg signed [DATA_WIDTH-1:0] line [0:LINE_DEPTH-1];
    reg signed [DATA_WIDTH-1:0] x_s, x_s_d, x_old;
    reg        [LINE_BITS-1:0]  wr_ptr;
    reg signed [SUM_WIDTH-1:0]  sum;
    reg        [LINE_BITS:0]    prime_cnt;
    reg                         prime_d;
    reg        [1:0]            rdy_sr;

    wire [LINE_BITS-1:0] rd_ptr  = wr_ptr - n_avg_reg;
    wire                 priming = (prime_cnt < {1'b0, n_avg_reg});

    always @(posedge clk) begin
        x_s          <= x_in;
        x_old        <= line[rd_ptr];
        line[wr_ptr] <= x_s;
    end

    always @(posedge clk) begin
        if (rst || avg_clr) begin
            x_s_d     <= {DATA_WIDTH{1'b0}};
            wr_ptr    <= {LINE_BITS{1'b0}};
            sum       <= {SUM_WIDTH{1'b0}};
            prime_cnt <= {(LINE_BITS+1){1'b0}};
            prime_d   <= 1'b1;
            rdy_sr    <= 2'b00;
        end else begin
            x_s_d   <= x_s;
            wr_ptr  <= wr_ptr + 1'b1;
            prime_d <= priming;
            rdy_sr  <= {rdy_sr[0], ~priming};
            if (priming) prime_cnt <= prime_cnt + 1'b1;
            sum <= sum + x_s_d - (prime_d ? {DATA_WIDTH{1'b0}} : x_old);
        end
    end

    assign avg_ready = rdy_sr[1];                      // matches the 2-cycle sum pipeline

    // sum >>> log_avg_reg always fits in DATA_WIDTH bits, so this cannot clip
    wire signed [SUM_WIDTH-1:0] avg_full = sum >>> log_avg_reg;
    assign energy_now = avg_full[E_WIDTH-1:0];

    // ---- direction code (00 = 0, 01 = +1, 11 = -1; read as a signed 2-bit) ----
    wire dir_is_pos = (dir_in >= thr_pos_reg);
    wire dir_is_neg = (dir_in <= thr_neg_reg);
    assign dir_now  = dir_is_pos ? 2'b01 : (dir_is_neg ? 2'b11 : 2'b00);

    // ---- trigger: mux, polarity, 2FF sync, rising-edge detect ----
    wire trig_pin = trig_bus[trig_sel_reg] ^ trig_inv_reg;
    reg  trig_m, trig_sync, trig_sync_d;
    always @(posedge clk) begin
        if (rst) begin trig_m <= 1'b0; trig_sync <= 1'b0; trig_sync_d <= 1'b0; end
        else begin trig_m <= trig_pin; trig_sync <= trig_m; trig_sync_d <= trig_sync; end
    end
    wire trig_edge = trig_sync & ~trig_sync_d;
    assign trig_level = trig_sync;

    // ---- ack edge (level pulse from PS control bit) ----
    reg ack_d;
    always @(posedge clk) begin
        if (rst) ack_d <= 1'b0; else ack_d <= ack;
    end
    wire ack_edge = ack & ~ack_d;

    // ---------------------------------------------------------------
    // Front end: trigger -> n_delay wait -> record, then trig_dead holdoff
    // ---------------------------------------------------------------
    localparam [1:0] S_IDLE = 2'd0, S_WAIT = 2'd1, S_DEAD = 2'd2;

    reg [1:0]            state;
    reg [DLY_WIDTH-1:0]  dly_cnt;
    reg [TS_WIDTH-1:0]   ts_trig;
    reg [DIR_WIDTH-1:0]  dir_trig;
    reg                  rec_valid;                 // 1-cycle: a record is ready to store
    reg [REC_WIDTH-1:0]  rec_data;

    wire can_trigger = arm && avg_ready && (state == S_IDLE);

    assign busy = (state != S_IDLE);

    always @(posedge clk) begin
        if (rst) begin
            state     <= S_IDLE;
            dly_cnt   <= {DLY_WIDTH{1'b0}};
            ts_trig   <= {TS_WIDTH{1'b0}};
            dir_trig  <= {DIR_WIDTH{1'b0}};
            rec_valid <= 1'b0;
            rec_data  <= {REC_WIDTH{1'b0}};
            skipped   <= 32'd0;
        end else begin
            rec_valid <= 1'b0;

            if (!arm) begin
                state   <= S_IDLE;
                dly_cnt <= {DLY_WIDTH{1'b0}};
            end else begin
                // count every edge we could not act on
                if (trig_edge && !can_trigger) skipped <= skipped + 1'b1;

                case (state)
                S_IDLE: if (trig_edge && avg_ready) begin
                            ts_trig  <= ts;            // timestamp at the trigger edge
                            dir_trig <= dir_now;       // direction at the trigger edge
                            dly_cnt  <= {DLY_WIDTH{1'b0}};
                            if (n_delay_reg == {DLY_WIDTH{1'b0}}) begin
                                rec_data  <= { energy_now, dir_now, ts };
                                rec_valid <= 1'b1;
                                state     <= (trig_dead_reg == {DLY_WIDTH{1'b0}}) ? S_IDLE : S_DEAD;
                            end else begin
                                state <= S_WAIT;
                            end
                        end

                S_WAIT: if (dly_cnt >= n_delay_reg - 1'b1) begin
                            rec_data  <= { energy_now, dir_trig, ts_trig };
                            rec_valid <= 1'b1;
                            dly_cnt   <= {DLY_WIDTH{1'b0}};
                            state     <= (trig_dead_reg == {DLY_WIDTH{1'b0}}) ? S_IDLE : S_DEAD;
                        end else begin
                            dly_cnt <= dly_cnt + 1'b1;
                        end

                S_DEAD: if (dly_cnt >= trig_dead_reg - 1'b1) begin
                            dly_cnt <= {DLY_WIDTH{1'b0}};
                            state   <= S_IDLE;
                        end else begin
                            dly_cnt <= dly_cnt + 1'b1;
                        end

                default: state <= S_IDLE;
                endcase
            end
        end
    end

    // ---------------------------------------------------------------
    // Ping-pong writer (same structure as event_logger)
    // ---------------------------------------------------------------
    reg                wr_buf;              // buffer currently being filled
    reg [IDX_BITS-1:0] wr_idx;              // index within the current buffer
    reg                held_full;           // current buffer full but predecessor not yet acked
    reg [31:0]         flush_cnt;           // clock cycles since last swap
    wire               at_last = (wr_idx == last_idx);

    always @(posedge clk) begin
        if (rst) begin
            bram_addr   <= {ADDR_BITS{1'b0}};
            bram_din    <= {REC_WIDTH{1'b0}};
            bram_en     <= 1'b0;
            bram_we     <= {BYTE_LANES{1'b0}};
            ready       <= 1'b0;
            ready_buf   <= 1'b0;
            ready_count <= {ADDR_BITS{1'b0}};
            dropped     <= 32'd0;
            total_events<= {TS_WIDTH{1'b0}};
            wr_buf      <= 1'b0;
            wr_idx      <= {IDX_BITS{1'b0}};
            held_full   <= 1'b0;
            flush_cnt   <= 32'd0;
        end else begin
            // defaults
            bram_en <= 1'b0;
            bram_we <= {BYTE_LANES{1'b0}};

            // ack frees the ready buffer
            if (ack_edge) ready <= 1'b0;

            // flush timer (counts only while a partial buffer is actually open)
            if (arm && wr_idx != {IDX_BITS{1'b0}}) flush_cnt <= flush_cnt + 1'b1;

            if (!arm) begin
                // idle: do not capture, keep counters/state but let ack drain
                flush_cnt <= 32'd0;
            end else if (held_full) begin
                // buffer full, waiting for predecessor to be acked
                if (rec_valid) dropped <= dropped + 1'b1;   // nowhere to store
                if (!ready) begin
                    // predecessor drained -> publish the held buffer, swap
                    ready       <= 1'b1;
                    ready_buf   <= wr_buf;
                    ready_count <= {1'b0, last_idx} + 1'b1;   // == frame_len
                    wr_buf      <= ~wr_buf;
                    wr_idx      <= {IDX_BITS{1'b0}};
                    held_full   <= 1'b0;
                    flush_cnt   <= 32'd0;
                end
            end else if (rec_valid) begin
                // write one record
                bram_din  <= rec_data;
                bram_addr <= { wr_buf, wr_idx };
                bram_en   <= 1'b1;
                bram_we   <= {BYTE_LANES{1'b1}};
                total_events <= total_events + 1'b1;

                if (at_last) begin
                    if (!ready) begin
                        ready       <= 1'b1;
                        ready_buf   <= wr_buf;
                        ready_count <= {1'b0, last_idx} + 1'b1;
                        wr_buf      <= ~wr_buf;
                        wr_idx      <= {IDX_BITS{1'b0}};
                        flush_cnt   <= 32'd0;
                    end else begin
                        held_full <= 1'b1;   // hold; predecessor not yet drained
                    end
                end else begin
                    wr_idx <= wr_idx + 1'b1;
                end
            end else if (flush_ticks != 32'd0 && flush_cnt >= flush_ticks
                         && wr_idx != {IDX_BITS{1'b0}} && !ready) begin
                // low-rate flush: publish a partial buffer so data isn't stuck
                ready       <= 1'b1;
                ready_buf   <= wr_buf;
                ready_count <= {{(ADDR_BITS-IDX_BITS){1'b0}}, wr_idx};  // partial count
                wr_buf      <= ~wr_buf;
                wr_idx      <= {IDX_BITS{1'b0}};
                flush_cnt   <= 32'd0;
            end
        end
    end

endmodule
