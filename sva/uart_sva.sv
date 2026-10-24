// uart_sva.sv - assertion checker, hooked onto the DUT from the testbench.
// Every property also has a small "hit" counter so we can show at the end
// that the assertions were really exercised and did not just pass vacuously.
module uart_sva #(
    parameter DIV_W     = 16,
    parameter LOWPWR_EN = 0,
    parameter ECC_EN    = 0,
    parameter ABD_EN    = 0,
    parameter MON_EN    = 0
)(
    input logic             clk,
    input logic             rst_n,
    input logic [DIV_W-1:0] div_active,
    // frame transmitter
    input logic             tx,
    input logic             f_tx_busy,
    input logic             f_tx_done,
    input logic             tx_go,
    input logic             tx_par_en,
    input logic             tx_tick,
    // frame receiver
    input logic             f_rx_valid,
    input logic             f_perr,
    input logic             f_ferr,
    input logic             rx_busy,
    input logic [DIV_W-1:0] rx_bg_cnt,
    // ecc
    input logic             u_rx_valid,
    input logic             ecc_corr,
    input logic             ecc_uncorr,
    // auto-baud
    input logic             abd_locked,
    input logic             abd_lockp,
    // monitor
    input logic             mon_clr,
    input logic [15:0]      mon_parity,
    input logic [15:0]      mon_framing,
    input logic [6:0]       mon_health
);
    // ---- frame length bookkeeping for the tx_busy check ----
    int busy_len;
    int exp_len;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) busy_len <= 0;
        else if (tx_go) busy_len <= 0;
        else if (f_tx_busy) busy_len <= busy_len + 1;
    end
    // tx_par_en is the latched parity enable of the frame in flight
    assign exp_len = (tx_par_en ? 11 : 10) * 16 * int'(div_active);

    int hit_idle, hit_len, hit_done, hit_start, hit_vpulse, hit_ferr, hit_perr;
    int hit_lp_rx, hit_lp_tx, hit_ecc, hit_abd, hit_mon;

    // A1: line idles high whenever the transmitter is not busy
    a_tx_idle_high: assert property (@(posedge clk) disable iff (!rst_n)
        !f_tx_busy |-> tx)
        else $error("A1 tx not high while idle");

    // A2: tx_busy lasts exactly one frame (10 or 11 bits * 16 * divisor clocks)
    a_busy_len: assert property (@(posedge clk) disable iff (!rst_n)
        $fell(f_tx_busy) |-> (busy_len == exp_len))
        else $error("A2 tx_busy length %0d, expected %0d", busy_len, exp_len);

    // A3: tx_done is a one-clock pulse exactly when busy drops
    a_done_fell: assert property (@(posedge clk) disable iff (!rst_n)
        f_tx_done |-> $fell(f_tx_busy))
        else $error("A3 tx_done without end of frame");

    // A4: accepting a byte drives the start bit on the next clock
    a_start_bit: assert property (@(posedge clk) disable iff (!rst_n)
        tx_go |=> !tx)
        else $error("A4 no start bit after accept");

    // A5: rx_valid is a single clock pulse
    a_rx_valid_pulse: assert property (@(posedge clk) disable iff (!rst_n)
        f_rx_valid |=> !f_rx_valid)
        else $error("A5 rx_valid longer than one clock");

    // A6: no rx_valid together with a framing error
    a_no_valid_on_ferr: assert property (@(posedge clk) disable iff (!rst_n)
        f_ferr |-> !f_rx_valid)
        else $error("A6 rx_valid with frame_err");

    // A7: parity error is only reported with a received byte
    a_perr_with_valid: assert property (@(posedge clk) disable iff (!rst_n)
        f_perr |-> f_rx_valid)
        else $error("A7 parity_err without rx_valid");

    generate if (LOWPWR_EN != 0) begin : g_lp
        // A8: RX oversampling counter is parked at 0 while the RX is idle
        a_lp_rx_parked: assert property (@(posedge clk) disable iff (!rst_n)
            (!rx_busy && !$past(rx_busy)) |-> (rx_bg_cnt == 0))
            else $error("A8 rx counter running while idle");
        // A9: no TX ticks while the transmitter is idle
        a_lp_tx_quiet: assert property (@(posedge clk) disable iff (!rst_n)
            (!f_tx_busy && !tx_go) |-> !tx_tick)
            else $error("A9 tx tick while idle");
    end endgenerate

    generate if (ECC_EN != 0) begin : g_ecc
        // A10: ECC flags only come with a decoded byte and never both at once
        a_ecc_flags: assert property (@(posedge clk) disable iff (!rst_n)
            (ecc_corr || ecc_uncorr) |-> (u_rx_valid && !(ecc_corr && ecc_uncorr)))
            else $error("A10 bad ECC flag combination");
    end endgenerate

    generate if (ABD_EN != 0) begin : g_abd
        // A11: a lock always gives a usable (non-zero) divisor
        a_abd_div: assert property (@(posedge clk) disable iff (!rst_n)
            abd_lockp |=> (abd_locked && div_active != 0))
            else $error("A11 lock with zero divisor");
    end endgenerate

    generate if (MON_EN != 0) begin : g_mon
        // A12: health stays in 0..100 and error counters never go down
        a_mon_health: assert property (@(posedge clk) disable iff (!rst_n)
            mon_health <= 7'd100)
            else $error("A12 health > 100");
        a_mon_mono: assert property (@(posedge clk) disable iff (!rst_n || mon_clr)
            (mon_parity >= $past(mon_parity)) && (mon_framing >= $past(mon_framing)))
            else $error("A12 monitor counter went down");
    end endgenerate

    // ---- antecedent hit counters (how often each check really fired) ----
    logic busy_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy_q <= 1'b0;
        end else begin
            busy_q <= f_tx_busy;
            if (!f_tx_busy)             hit_idle   <= hit_idle + 1;
            if (busy_q && !f_tx_busy)   hit_len    <= hit_len + 1;
            if (f_tx_done)              hit_done   <= hit_done + 1;
            if (tx_go)                  hit_start  <= hit_start + 1;
            if (f_rx_valid)             hit_vpulse <= hit_vpulse + 1;
            if (f_ferr)                 hit_ferr   <= hit_ferr + 1;
            if (f_perr)                 hit_perr   <= hit_perr + 1;
            if (!rx_busy)               hit_lp_rx  <= hit_lp_rx + 1;
            if (!f_tx_busy && !tx_go)   hit_lp_tx  <= hit_lp_tx + 1;
            if (ecc_corr || ecc_uncorr) hit_ecc    <= hit_ecc + 1;
            if (abd_lockp)              hit_abd    <= hit_abd + 1;
            if (mon_parity != 0)        hit_mon    <= hit_mon + 1;
        end
    end
    initial begin
        hit_idle = 0; hit_len = 0; hit_done = 0; hit_start = 0; hit_vpulse = 0;
        hit_ferr = 0; hit_perr = 0; hit_lp_rx = 0; hit_lp_tx = 0; hit_ecc = 0;
        hit_abd = 0; hit_mon = 0;
    end

    function void report();
        $display("SVA antecedent hits: A1 idle=%0d A2 frame_end=%0d A3 done=%0d A4 accept=%0d A5 rx_valid=%0d A6 frame_err=%0d A7 parity_err=%0d",
                 hit_idle, hit_len, hit_done, hit_start, hit_vpulse, hit_ferr, hit_perr);
        if (LOWPWR_EN != 0) $display("SVA hits (low power): A8 rx_idle=%0d A9 tx_idle=%0d", hit_lp_rx, hit_lp_tx);
        if (ECC_EN != 0)    $display("SVA hits (ecc): A10=%0d", hit_ecc);
        if (ABD_EN != 0)    $display("SVA hits (auto-baud): A11=%0d", hit_abd);
        if (MON_EN != 0)    $display("SVA hits (monitor): A12 cycles with parity count>0 = %0d", hit_mon);
    endfunction
endmodule
