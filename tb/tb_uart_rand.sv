// tb_uart_rand.sv - self-checking randomised testbench (base UART)
// Runs on Verilator (--timing --assert). Seed comes from +SEED=<n>.
// The DUT TX is looped back to its RX, except when the bus-functional
// model (BFM) takes over the line to inject bad frames, glitches or a
// different baud rate.
`timescale 1ns/1ps
module tb_uart_rand;
    localparam int DIV_W = 16;
    localparam int DIV   = 16;              // 16 clocks per tick
    localparam real CLK_NS = 20.0;          // 50 MHz
    localparam real BIT_NS = CLK_NS * 16 * DIV;
    parameter int LOWPWR_EN  = 0;
    parameter int LINEMON_EN = 0;

    logic clk = 0, rst_n = 0;
    always #(CLK_NS/2) clk = ~clk;

    logic [1:0] pmode = 2'b00;
    logic       tx_start = 0;
    logic [7:0] tx_data = 0;
    logic       dut_tx, tx_busy, tx_done;
    logic       rx_valid, parity_err, frame_err;
    logic [7:0] rx_data;
    logic       bfm_sel = 0, bfm_line = 1;
    wire        line = bfm_sel ? bfm_line : dut_tx;

    /* verilator lint_off PINMISSING */
    uart_core #(.DIV_W(DIV_W), .PARITY_SUPPORT(1), .LOWPWR_EN(LOWPWR_EN), .LINEMON_EN(LINEMON_EN)) dut (
        .clk(clk), .rst_n(rst_n), .divisor(DIV_W'(DIV)), .parity_mode(pmode),
        .tx_start(tx_start), .tx_data(tx_data), .tx(dut_tx), .tx_busy(tx_busy), .tx_done(tx_done),
        .rx(line), .rx_data(rx_data), .rx_valid(rx_valid), .parity_err(parity_err), .frame_err(frame_err),
        .abd_start(1'b0), .mon_clr(1'b0));
    /* verilator lint_on PINMISSING */

    uart_sva #(.DIV_W(DIV_W), .LOWPWR_EN(LOWPWR_EN)) chk (
        .clk(clk), .rst_n(rst_n), .div_active(dut.div_active),
        .tx(dut_tx), .f_tx_busy(dut.f_tx_busy), .f_tx_done(dut.f_tx_done), .tx_go(dut.tx_go),
        .tx_par_en(dut.u_tx.par_en), .tx_tick(dut.tx_tick),
        .f_rx_valid(dut.f_rx_valid), .f_perr(dut.f_perr), .f_ferr(dut.f_ferr),
        .rx_busy(dut.rx_busy_i), .rx_bg_cnt(dut.u_bg_rx.cnt),
        .u_rx_valid(rx_valid), .ecc_corr(1'b0), .ecc_uncorr(1'b0),
        .abd_locked(1'b0), .abd_lockp(1'b0),
        .mon_clr(1'b0), .mon_parity(dut.mon_parity), .mon_framing(dut.mon_framing),
        .mon_health(dut.mon_health));

    // ---------------- own random generator (xorshift32) ----------------
    int unsigned rs;
    function automatic int unsigned rnd();
        rs ^= rs << 13; rs ^= rs >> 17; rs ^= rs << 5;
        return rs;
    endfunction
    function automatic int unsigned rrange(int unsigned lo, int unsigned hi);
        return lo + (rnd() % (hi - lo + 1));
    endfunction

    // ---------------- scoreboard ----------------
    typedef struct packed { logic [7:0] d; logic perr; logic ferr; } exp_t;
    exp_t sb[$];
    bit   count_only = 0;       // big baud mismatch: just count errors
    int   n_ok, n_bad, n_obs_err;

    function automatic logic par_of(logic [7:0] d, logic [1:0] m);
        return (m == 2'b10) ? ~(^d) : (^d);
    endfunction

    always @(posedge clk) if (rst_n && (rx_valid || frame_err)) begin
        exp_t e;
        if (count_only) begin
            if (sb.size() > 0) e = sb.pop_front();
            if (frame_err || parity_err || (sb.size() >= 0 && rx_data !== e.d)) n_obs_err++;
            else n_ok++;
        end else if (sb.size() == 0) begin
            $display("ERROR %0t: unexpected receive data=%02h ferr=%b", $time, rx_data, frame_err);
            n_bad++;
        end else begin
            e = sb.pop_front();
            if (e.ferr) begin
                if (frame_err && !rx_valid) n_ok++;
                else begin n_bad++; $display("ERROR %0t: expected frame_err (byte %02h)", $time, e.d); end
            end else if (frame_err || rx_data !== e.d || parity_err !== e.perr) begin
                n_bad++;
                $display("ERROR %0t: exp %02h perr=%b got %02h perr=%b ferr=%b", $time, e.d, e.perr, rx_data, parity_err, frame_err);
            end else n_ok++;
        end
    end

    // ---------------- DUT transmit helpers ----------------
    task automatic dut_send(logic [7:0] d);
        @(negedge clk);
        tx_data  = d;
        tx_start = 1;
        @(posedge clk);
        while (!(dut.tx_go)) @(posedge clk);
        sb.push_back('{d: d, perr: 0, ferr: 0});
        @(negedge clk) tx_start = 0;
    endtask

    task automatic wait_idle();
        repeat (2) @(posedge clk);
        while (tx_busy || dut.rx_busy_i || bfm_sel) @(posedge clk);
        repeat (4 * 16 * DIV) @(posedge clk);
    endtask

    // ---------------- BFM: drives the line with its own bit time ----------------
    task automatic bfm_frame(logic [7:0] d, logic [1:0] m, real bit_ns, bit bad_par, bit bad_stop);
        logic p;
        p = par_of(d, m) ^ bad_par;
        bfm_line = 0; #(bit_ns);
        for (int i = 0; i < 8; i++) begin bfm_line = d[i]; #(bit_ns); end
        if (m == 2'b01 || m == 2'b10) begin bfm_line = p; #(bit_ns); end
        bfm_line = !bad_stop; #(bit_ns);
        bfm_line = 1;
        if (bad_stop) #(2 * bit_ns);       // give the RX a clean high after a break
    endtask

    // ---------------- test bookkeeping ----------------
    int fails_total = 0;
    task automatic report(string name, int frames, int expect_err_min = -1);
        wait_idle();
        if (expect_err_min < 0) begin
            if (n_bad == 0 && sb.size() == 0 && n_ok == frames)
                $display("[PASS] %-34s frames=%0d ok=%0d bad=%0d", name, frames, n_ok, n_bad);
            else begin
                $display("[FAIL] %-34s frames=%0d ok=%0d bad=%0d left_in_sb=%0d", name, frames, n_ok, n_bad, sb.size());
                fails_total++;
            end
        end else begin
            if (n_obs_err >= expect_err_min)
                $display("[PASS] %-34s frames=%0d clean=%0d with_errors=%0d (errors expected)", name, frames, n_ok, n_obs_err);
            else begin
                $display("[FAIL] %-34s frames=%0d clean=%0d with_errors=%0d (expected errors!)", name, frames, n_ok, n_obs_err);
                fails_total++;
            end
        end
        n_ok = 0; n_bad = 0; n_obs_err = 0; sb.delete(); count_only = 0;
    endtask

    // mismatch run: BFM sends 'n' frames at bit time scaled by (1+ppm)
    task automatic mismatch_run(real frac, int n, bit expect_errs);
        string nm;
        bfm_sel = 1;
        count_only = expect_errs;
        for (int i = 0; i < n; i++) begin
            logic [7:0] d; logic [1:0] m;
            d = 8'(rnd()); m = 2'(rrange(0, 2));
            @(negedge clk) pmode = m;
            if (!expect_errs) sb.push_back('{d: d, perr: 0, ferr: 0});
            else sb.push_back('{d: d, perr: 0, ferr: 0});
            bfm_frame(d, m, BIT_NS * (1.0 + frac), 0, 0);
            #(BIT_NS * rrange(1, 3));
        end
        bfm_sel = 0;
        nm = $sformatf("T5 baud mismatch %s%0.1f%%", frac > 0 ? "+" : "", frac * 100.0);
        report(nm, n, expect_errs ? 1 : -1);
    endtask

    initial begin
        int unsigned seed;
        int n;
        if (!$value$plusargs("SEED=%d", seed)) seed = 1;
        rs = (seed == 0) ? 32'h1234_5678 : seed;
        $display("=== tb_uart_rand  SEED=%0d  DIV=%0d  LOWPWR_EN=%0d LINEMON_EN=%0d ===", seed, DIV, LOWPWR_EN, LINEMON_EN);
        n_ok = 0; n_bad = 0; n_obs_err = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;

        // T1: random bytes, random idle gaps, parity mode changed every 250 frames
        n = 3000;
        for (int i = 0; i < n; i++) begin
            if (i % 250 == 0) begin wait_idle(); pmode = 2'(rrange(0, 2)); end
            dut_send(8'(rnd()));
            repeat (rrange(0, 3 * 16 * DIV)) @(posedge clk);
            while (tx_busy) @(posedge clk);
        end
        report("T1 random bytes + random gaps", n);

        // T2: back-to-back frames, tx_start held high
        n = 500;
        pmode = 2'b01;
        for (int i = 0; i < n; i++) dut_send(8'(rnd()));
        report("T2 back-to-back (even parity)", n);

        // T3: parity error injection (BFM)
        n = 400;
        bfm_sel = 1;
        for (int i = 0; i < n; i++) begin
            logic [7:0] d; bit bad;
            d = 8'(rnd()); bad = rnd() % 2;
            @(negedge clk) pmode = (rnd() % 2) ? 2'b01 : 2'b10;
            sb.push_back('{d: d, perr: bad, ferr: 0});
            bfm_frame(d, pmode, BIT_NS, bad, 0);
            #(BIT_NS * rrange(0, 2));
        end
        bfm_sel = 0;
        report("T3 parity error injection", n);

        // T4: corrupted stop bit -> framing error, no rx_valid
        n = 400;
        bfm_sel = 1;
        for (int i = 0; i < n; i++) begin
            logic [7:0] d; bit bad;
            d = 8'(rnd()); bad = rnd() % 2;
            @(negedge clk) pmode = 2'(rrange(0, 2));
            sb.push_back('{d: d, perr: 0, ferr: bad});
            bfm_frame(d, pmode, BIT_NS, 0, bad);
            #(BIT_NS * rrange(0, 2));
        end
        bfm_sel = 0;
        report("T4 stop bit corruption", n);

        // T5: baud mismatch, small (should work) and large (should fail)
        mismatch_run( 0.02, 500, 0);
        mismatch_run(-0.02, 500, 0);
        mismatch_run( 0.03, 500, 0);
        mismatch_run(-0.03, 500, 0);
        mismatch_run( 0.08, 300, 1);
        mismatch_run(-0.08, 300, 1);

        // T6: glitches on an idle line must not produce anything
        n = 300;
        bfm_sel = 1;
        for (int i = 0; i < n; i++) begin
            bfm_line = 0;
            #(CLK_NS * DIV * rrange(1, 5));      // 1..5 ticks, well under half a bit
            bfm_line = 1;
            #(BIT_NS * 2);
        end
        bfm_sel = 0;
        // then one good frame to prove the RX is still alive
        pmode = 2'b00;
        dut_send(8'hC3);
        report("T6 start-bit glitch rejection", 1);

        // T7: reset in the middle of a frame, then normal traffic
        n = 0;
        for (int i = 0; i < 50; i++) begin
            int cut, ok_before;
            pmode = 2'(rrange(0, 2));
            ok_before = n_ok;
            dut_send(8'(rnd()));
            cut = rrange(1, 10 * 16 * DIV - 2);
            repeat (cut) @(posedge clk);
            @(negedge clk) rst_n = 0;
            // if the cut lands after the mid-stop sample the RX already
            // delivered the byte (correctly) - count it as a sent frame
            n += n_ok - ok_before;
            sb.delete();
            repeat (3) @(posedge clk);
            if (dut_tx !== 1'b1 || tx_busy !== 1'b0) begin
                $display("ERROR: after reset tx=%b busy=%b", dut_tx, tx_busy);
                n_bad++;
            end
            @(negedge clk) rst_n = 1;
            repeat (2 * 16 * DIV) @(posedge clk);
            for (int k = 0; k < 4; k++) begin dut_send(8'(rnd())); n++; end
            wait_idle();
        end
        report("T7 reset mid-frame + recovery", n);

        chk.report();
        if (LINEMON_EN != 0)
            $display("Monitor after run: frames=%0d parity=%0d framing=%0d drift_max=%0d health=%0d",
                     dut.mon_frames, dut.mon_parity, dut.mon_framing, dut.mon_drift_max, dut.mon_health);
        $display("RESULT SEED=%0d : %s (%0d failing test groups)", seed, fails_total ? "FAIL" : "PASS", fails_total);
        if (fails_total) $fatal(1, "testbench reported failures");
        $finish;
    end
endmodule
