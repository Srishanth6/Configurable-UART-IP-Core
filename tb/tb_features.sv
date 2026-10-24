// tb_features.sv - tests for the four optional features, all switched on:
// auto-baud, SECDED ECC, low-power gating and the line-quality monitor.
// +SEED=<n> sets the random seed, +CLK_NS=<real> the clock period.
`timescale 1ns/1ps
module tb_features;
    localparam int DIV_W = 16;
    localparam int DIV0  = 16;          // divisor before auto-baud
    real clk_ns = 20.0;

    logic clk = 0, rst_n = 0;
    initial begin
        void'($value$plusargs("CLK_NS=%f", clk_ns));
        forever #(clk_ns / 2.0) clk = ~clk;
    end

    logic [1:0] pmode = 2'b00;
    logic       tx_start = 0, abd_start = 0, mon_clr = 0;
    logic [7:0] tx_data = 0;
    logic       dut_tx, tx_busy, tx_done, rx_valid, parity_err, frame_err;
    logic       abd_busy, abd_locked, abd_err, ecc_corr, ecc_uncorr;
    logic [7:0] rx_data;
    logic [DIV_W-1:0] div_active;
    logic [15:0] m_frames, m_par, m_frm, m_corr, m_unc;
    logic signed [4:0] m_dlast;
    logic [3:0] m_dmax;
    logic [6:0] m_health;

    logic bfm_sel = 0, bfm_line = 1, flip = 0;
    wire  line = bfm_sel ? bfm_line : (dut_tx ^ flip);

    uart_core #(.DIV_W(DIV_W), .PARITY_SUPPORT(1), .AUTOBAUD_EN(1), .ECC_EN(1),
                .LOWPWR_EN(1), .LINEMON_EN(1)) dut (
        .clk(clk), .rst_n(rst_n), .divisor(DIV_W'(DIV0)), .parity_mode(pmode),
        .tx_start(tx_start), .tx_data(tx_data), .tx(dut_tx), .tx_busy(tx_busy), .tx_done(tx_done),
        .rx(line), .rx_data(rx_data), .rx_valid(rx_valid), .parity_err(parity_err), .frame_err(frame_err),
        .abd_start(abd_start), .abd_busy(abd_busy), .abd_locked(abd_locked), .abd_err(abd_err),
        .div_active(div_active), .ecc_corr(ecc_corr), .ecc_uncorr(ecc_uncorr),
        .mon_clr(mon_clr), .mon_frames(m_frames), .mon_parity(m_par), .mon_framing(m_frm),
        .mon_corr(m_corr), .mon_uncorr(m_unc), .mon_drift_last(m_dlast), .mon_drift_max(m_dmax),
        .mon_health(m_health));

    uart_sva #(.DIV_W(DIV_W), .LOWPWR_EN(1), .ECC_EN(1), .ABD_EN(1), .MON_EN(1)) chk (
        .clk(clk), .rst_n(rst_n), .div_active(div_active),
        .tx(dut_tx), .f_tx_busy(dut.f_tx_busy), .f_tx_done(dut.f_tx_done), .tx_go(dut.tx_go),
        .tx_par_en(dut.u_tx.par_en), .tx_tick(dut.tx_tick),
        .f_rx_valid(dut.f_rx_valid), .f_perr(dut.f_perr), .f_ferr(dut.f_ferr),
        .rx_busy(dut.rx_busy_i), .rx_bg_cnt(dut.u_bg_rx.cnt),
        .u_rx_valid(rx_valid), .ecc_corr(ecc_corr), .ecc_uncorr(ecc_uncorr),
        .abd_locked(abd_locked), .abd_lockp(dut.abd_lockp),
        .mon_clr(mon_clr), .mon_parity(m_par), .mon_framing(m_frm), .mon_health(m_health));

    // ---------------- random ----------------
    int unsigned rs;
    function automatic int unsigned rnd();
        rs ^= rs << 13; rs ^= rs >> 17; rs ^= rs << 5;
        return rs;
    endfunction
    function automatic int unsigned rrange(int unsigned lo, int unsigned hi);
        return lo + (rnd() % (hi - lo + 1));
    endfunction

    // ---------------- reference SECDED encoder (written separately from the RTL) ----------------
    function automatic logic [12:0] ref_encode(logic [7:0] d);
        logic [12:0] c;
        int dpos[8] = '{3, 5, 6, 7, 9, 10, 11, 12};
        c = '0;
        for (int i = 0; i < 8; i++) c[dpos[i]] = d[i];
        for (int p = 1; p <= 8; p = p * 2) begin
            logic x = 0;
            for (int pos = 1; pos <= 12; pos++) if ((pos & p) && pos != p) x ^= c[pos];
            c[p] = x;
        end
        c[0] = ^c[12:1];
        return c;
    endfunction

    // ---------------- receive log ----------------
    logic [7:0] got_q[$];
    logic       gotc_q[$], gotu_q[$];
    int n_ferr_seen = 0, n_perr_seen = 0;
    always @(posedge clk) if (rst_n) begin
        if (rx_valid) begin got_q.push_back(rx_data); gotc_q.push_back(ecc_corr); gotu_q.push_back(ecc_uncorr); end
        if (frame_err)  n_ferr_seen++;
        if (parity_err) n_perr_seen++;
    end
    function automatic void clear_log();
        got_q.delete(); gotc_q.delete(); gotu_q.delete();
        n_ferr_seen = 0; n_perr_seen = 0;
    endfunction

    // ---------------- BFM ----------------
    task automatic bfm_frame(logic [7:0] d, logic [1:0] m, real bit_ns, bit bad_par = 0, bit bad_stop = 0);
        logic p;
        p = ((m == 2'b10) ? ~(^d) : (^d)) ^ bad_par;
        bfm_line = 0; #(bit_ns);
        for (int i = 0; i < 8; i++) begin bfm_line = d[i]; #(bit_ns); end
        if (m == 2'b01 || m == 2'b10) begin bfm_line = p; #(bit_ns); end
        bfm_line = !bad_stop; #(bit_ns);
        bfm_line = 1;
        if (bad_stop) #(2 * bit_ns);
    endtask
    // one user byte = two frames carrying the codeword
    task automatic bfm_byte(logic [7:0] d, real bit_ns);
        logic [12:0] c;
        c = ref_encode(d);
        bfm_frame(c[7:0], 2'b00, bit_ns);
        bfm_frame({3'b000, c[12:8]}, 2'b00, bit_ns);
        #(bit_ns * 2);
    endtask

    task automatic do_reset();
        @(negedge clk) rst_n = 0;
        repeat (4) @(posedge clk);
        @(negedge clk) rst_n = 1;
        repeat (4) @(posedge clk);
    endtask

    task automatic dut_send(logic [7:0] d);
        @(negedge clk); tx_data = d; tx_start = 1;
        @(posedge clk); while (!(tx_start && !tx_busy)) @(posedge clk);
        @(negedge clk) tx_start = 0;
        @(posedge clk); while (tx_busy) @(posedge clk);
    endtask

    task automatic settle(int bits);
        repeat (bits * 16 * int'(div_active)) @(posedge clk);
    endtask

    int fails_total = 0;
    task automatic verdict(bit ok, string msg);
        $display("%s %s", ok ? "[PASS]" : "[FAIL]", msg);
        if (!ok) fails_total++;
    endtask

    // ================= F1: auto-baud =================
    task automatic autobaud_case(int baud);
        real clk_hz, ideal, bit_ns, rate_err;
        int nbytes, nok, lock_ok, d_got, t;
        bit must_work;
        logic [7:0] sent[$];
        sent.delete();
        clk_hz = 1.0e9 / clk_ns;
        ideal  = clk_hz / (16.0 * baud);
        bit_ns = 1.0e9 / baud;
        do_reset();
        clear_log();
        @(negedge clk) abd_start = 1; @(negedge clk) abd_start = 0;
        bfm_sel = 1;
        #(bit_ns * 2);
        bfm_frame(8'h55, 2'b00, bit_ns);
        #(bit_ns * 2);
        t = 0;
        while (abd_busy && t < 1000) begin @(posedge clk); t++; end
        lock_ok = abd_locked;
        d_got   = int'(div_active);
        rate_err = (lock_ok && d_got > 0) ? (clk_hz / (16.0 * d_got) - baud) / baud * 100.0 : 0.0;
        // data check: bytes sent by the BFM at the true baud rate
        nbytes = (baud < 20000) ? 10 : 40;
        nok = 0;
        if (lock_ok) begin
            for (int i = 0; i < nbytes; i++) begin
                logic [7:0] d;
                d = 8'(rnd());
                sent.push_back(d);
                bfm_byte(d, bit_ns);
            end
        end
        bfm_sel = 0;
        repeat (100) @(posedge clk);
        // count bytes that came back correct and in order
        nok = 0;
        for (int i = 0; i < got_q.size() && i < sent.size(); i++)
            if (got_q[i] == sent[i]) nok++;
        must_work = (rate_err < 2.0 && rate_err > -2.0);
        $display("  autobaud clk=%0.1fMHz baud=%0d ideal_div=%0.2f locked=%0d div=%0d rate_err=%0.2f%% bytes_rx=%0d/%0d",
                 clk_hz / 1e6, baud, ideal, lock_ok, d_got, rate_err, nok, nbytes);
        verdict(lock_ok && (real'(d_got) - ideal <= 0.55) && (ideal - real'(d_got) <= 0.55),
                $sformatf("F1 lock accuracy  baud=%0d clk=%0.1fMHz (|div-ideal|<=0.55)", baud, clk_hz / 1e6));
        if (must_work)
            verdict(nok == nbytes && got_q.size() == nbytes && n_ferr_seen == 0,
                    $sformatf("F1 data after lock baud=%0d (rate error %0.2f%% < 2%%)", baud, rate_err));
        else
            $display("[INFO] F1 data after lock baud=%0d: rate error %0.2f%% outside +-2%%, %0d/%0d bytes ok (not required)",
                     baud, rate_err, nok, nbytes);
    endtask

    // ================= F2: ECC with bit flips on the line =================
    // flip process: on each frame start, flip the chosen data bits for a whole bit time
    logic [12:0] flip_mask = '0;
    bit          frame_b = 0;
    always @(posedge clk) begin
        if (dut.tx_go) fork begin
            logic [7:0] m8;
            int bc;
            m8 = frame_b ? {3'b000, flip_mask[12:8]} : flip_mask[7:0];
            frame_b = !frame_b;
            bc = 16 * int'(div_active);
            // tx line changes on the clock after tx_go, line follows tx
            repeat (bc) @(posedge clk);                       // start bit
            for (int k = 0; k < 8; k++) begin
                flip <= m8[k];
                repeat (bc) @(posedge clk);
            end
            flip <= 0;
        end join_none
    end

    task automatic ecc_test(int n);
        int n0 = 0, n1 = 0, n2 = 0, ok0 = 0, ok1 = 0, det2 = 0, bad = 0;
        logic [7:0] sent[$];
        int kind[$];
        sent.delete(); kind.delete();
        do_reset();
        pmode = 2'b00;
        @(negedge clk) mon_clr = 1; @(negedge clk) mon_clr = 0;
        clear_log();
        frame_b = 0;
        for (int i = 0; i < n; i++) begin
            int r, a, b;
            logic [7:0] d;
            d = 8'(rnd());
            r = rrange(0, 9);
            a = rrange(0, 12);
            do b = rrange(0, 12); while (b == a);
            if (r < 4)      begin flip_mask = '0; kind.push_back(0); n0++; end
            else if (r < 8) begin flip_mask = 13'(1) << a; kind.push_back(1); n1++; end
            else            begin flip_mask = (13'(1) << a) | (13'(1) << b); kind.push_back(2); n2++; end
            sent.push_back(d);
            dut_send(d);
            settle(2);
        end
        settle(4);
        if (got_q.size() != n) begin
            $display("ERROR: ECC test got %0d bytes, expected %0d", got_q.size(), n);
            bad++;
        end else begin
            for (int i = 0; i < n; i++) begin
                case (kind[i])
                0: if (got_q[i] == sent[i] && !gotc_q[i] && !gotu_q[i]) ok0++; else bad++;
                1: if (got_q[i] == sent[i] &&  gotc_q[i] && !gotu_q[i]) ok1++; else bad++;
                2: if (gotu_q[i] && !gotc_q[i]) det2++; else bad++;
                endcase
            end
        end
        $display("  ECC: clean=%0d (ok %0d)  single-flip=%0d (corrected %0d)  double-flip=%0d (detected %0d)  mismatches=%0d",
                 n0, ok0, n1, ok1, n2, det2, bad);
        $display("  monitor: corr=%0d uncorr=%0d frames=%0d health=%0d", m_corr, m_unc, m_frames, m_health);
        verdict(bad == 0 && ok0 == n0 && ok1 == n1 && det2 == n2, $sformatf("F2 SECDED random flips (%0d bytes)", n));
        verdict(int'(m_corr) == n1 && int'(m_unc) == n2, "F4 monitor ECC counters match injected flips");
        flip_mask = '0;
    endtask

    // ================= F4: line monitor scenarios =================
    task automatic mon_scenario_clean();
        int n = 64;
        do_reset();
        @(negedge clk) mon_clr = 1; @(negedge clk) mon_clr = 0;
        for (int i = 0; i < n; i++) begin dut_send(8'(rnd())); settle(1); end
        settle(3);
        $display("  monitor clean: frames=%0d parity=%0d framing=%0d corr=%0d uncorr=%0d drift_max=%0d health=%0d",
                 m_frames, m_par, m_frm, m_corr, m_unc, m_dmax, m_health);
        verdict(m_par == 0 && m_frm == 0 && m_corr == 0 && m_unc == 0 && m_health == 100 && m_dmax <= 1,
                "F4 clean link -> no errors, drift<=1/16 bit, health=100");
    endtask

    task automatic mon_scenario_mismatch(real frac, output int dmax_out, output int health_out);
        real bit_ns;
        int dv;
        do_reset();
        dv = div_active;
        bit_ns = clk_ns * 16.0 * dv * (1.0 + frac);
        @(negedge clk) mon_clr = 1; @(negedge clk) mon_clr = 0;
        bfm_sel = 1;
        for (int i = 0; i < 40; i++) bfm_byte(8'(rnd()), bit_ns);
        bfm_sel = 0;
        settle(3);
        $display("  monitor baud %s%0.1f%%: frames=%0d framing=%0d corr=%0d uncorr=%0d drift_last=%0d drift_max=%0d health=%0d",
                 frac > 0 ? "+" : "", frac * 100, m_frames, m_frm, m_corr, m_unc, m_dlast, m_dmax, m_health);
        dmax_out = m_dmax; health_out = m_health;
    endtask

    task automatic mon_scenario_noise();
        int inj_p = 0, inj_f = 0;
        real bit_ns;
        int dv;
        do_reset();
        dv = div_active;
        bit_ns = clk_ns * 16.0 * dv;
        @(negedge clk) mon_clr = 1; @(negedge clk) mon_clr = 0;
        clear_log();
        pmode = 2'b01;
        bfm_sel = 1;
        for (int i = 0; i < 200; i++) begin
            int r; bit bp, bs;
            r = rrange(0, 9);
            bp = (r == 0 || r == 1);       // ~20% parity hits
            bs = (r == 2);                 // ~10% stop-bit hits
            inj_p += bp; inj_f += bs;
            bfm_frame(8'(rnd()), 2'b01, bit_ns, bp, bs);
            #(bit_ns);
        end
        bfm_sel = 0;
        settle(3);
        $display("  monitor noise: injected parity=%0d framing=%0d | seen pulses parity=%0d framing=%0d | counters parity=%0d framing=%0d frames=%0d health=%0d",
                 inj_p, inj_f, n_perr_seen, n_ferr_seen, m_par, m_frm, m_frames, m_health);
        verdict(int'(m_par) == inj_p && int'(m_frm) == inj_f && int'(m_par) == n_perr_seen && int'(m_frm) == n_ferr_seen,
                "F4 noise: monitor counters == injected == observed");
        verdict(m_health < 100, "F4 noise: health score dropped");
        pmode = 2'b00;
    endtask

    initial begin
        int unsigned seed;
        int bauds[$];
        int d2, h2, d3, h3, d6, h6;
        if (!$value$plusargs("SEED=%d", seed)) seed = 1;
        rs = (seed == 0) ? 32'hCAFE_F00D : seed;
        #1;
        $display("=== tb_features  SEED=%0d  CLK=%0.1f MHz ===", seed, 1000.0 / clk_ns);
        repeat (5) @(posedge clk);
        rst_n = 1;

        bauds = '{2400, 9600, 19200, 57600, 115200, 230400, 460800, 921600};
        foreach (bauds[i]) autobaud_case(bauds[i]);

        ecc_test(1500);

        mon_scenario_clean();
        mon_scenario_mismatch(0.0,  d0_, h0_);
        mon_scenario_mismatch(0.02, d2, h2);
        mon_scenario_mismatch(0.03, d3, h3);
        mon_scenario_mismatch(0.06, d6, h6);
        verdict(d3 > d0_ && d6 > d3, "F4 drift grows with baud mismatch (0% < 3% < 6%)");
        verdict(h6 < 100, "F4 health drops at 6% mismatch");
        mon_scenario_noise();

        chk.report();
        $display("RESULT SEED=%0d CLK=%0.1fMHz : %s (%0d failing checks)", seed, 1000.0 / clk_ns,
                 fails_total ? "FAIL" : "PASS", fails_total);
        if (fails_total) $fatal(1, "feature testbench reported failures");
        $finish;
    end
    int d0_, h0_;
endmodule
