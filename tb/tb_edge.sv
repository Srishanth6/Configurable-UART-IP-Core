// tb_edge.sv - directed edge-case tests added after review (base UART):
//  E1 divisor boundary values (DIV set with -GDIV=..., plus FRAMES)
//  E2 reset asserted in every TX state (START, DATA, PAR, STOP)
//  E3 reset asserted in every RX state (START, DATA, PAR, STOP, BREAK)
//  E4 back-to-back frames in all four parity_mode codes (00,01,10,11)
//  E5 malformed frames: short start glitches, bad stop bit, bad parity
// Checked by a scoreboard plus sva/uart_sva.sv (A1-A7) and
// sva/uart_sva_ext.sv (B1-B4). Exits non-zero on any failure.
`timescale 1ns/1ps
module tb_edge;
    localparam int DIV_W = 16;
    parameter int DIV    = 4;      // clocks per 1/16 bit
    parameter int FRAMES = 32;     // frames per back-to-back mode
    parameter int FULL   = 1;      // 0: only E1/E4 (used for very large DIV)
    localparam int BITC  = 16 * DIV;

    logic clk = 0, rst_n = 0;
    always #10 clk = ~clk;

    logic [1:0] pmode = 0;
    logic tx_start = 0; logic [7:0] tx_data = 0;
    logic dut_tx, tx_busy, tx_done, rx_valid, parity_err, frame_err;
    logic [7:0] rx_data;
    logic bfm_sel = 0, bfm_line = 1;
    wire  line = bfm_sel ? bfm_line : dut_tx;

    /* verilator lint_off PINMISSING */
    uart_core #(.DIV_W(DIV_W), .PARITY_SUPPORT(1)) dut (
        .clk(clk), .rst_n(rst_n), .divisor(DIV_W'(DIV)), .parity_mode(pmode),
        .tx_start(tx_start), .tx_data(tx_data), .tx(dut_tx), .tx_busy(tx_busy), .tx_done(tx_done),
        .rx(line), .rx_data(rx_data), .rx_valid(rx_valid), .parity_err(parity_err), .frame_err(frame_err),
        .abd_start(1'b0), .mon_clr(1'b0));
    /* verilator lint_on PINMISSING */

    uart_sva #(.DIV_W(DIV_W)) chk (
        .clk(clk), .rst_n(rst_n), .div_active(dut.div_active),
        .tx(dut_tx), .f_tx_busy(dut.f_tx_busy), .f_tx_done(dut.f_tx_done), .tx_go(dut.tx_go),
        .tx_par_en(dut.u_tx.par_en), .tx_tick(dut.tx_tick),
        .f_rx_valid(dut.f_rx_valid), .f_perr(dut.f_perr), .f_ferr(dut.f_ferr),
        .rx_busy(dut.rx_busy_i), .rx_bg_cnt(dut.u_bg_rx.cnt),
        .u_rx_valid(rx_valid), .ecc_corr(1'b0), .ecc_uncorr(1'b0),
        .abd_locked(1'b0), .abd_lockp(1'b0),
        .mon_clr(1'b0), .mon_parity(16'd0), .mon_framing(16'd0), .mon_health(7'd0));

    uart_sva_ext #(.DIV_W(DIV_W)) chk2 (
        .clk(clk), .rst_n(rst_n), .divisor(dut.div_active),
        .bg_tick(dut.tx_tick), .bg_clr(dut.tx_go), .bg_en(1'b1),
        .rx_tick(dut.rx_tick), .rx_state(dut.u_rx.state), .rx_tcnt(dut.u_rx.tcnt), .rx_bit_no(dut.u_rx.bit_no),
        .tx(dut_tx), .tx_busy(tx_busy), .rx_valid(rx_valid), .frame_err(frame_err),
        .parity_err(parity_err), .tx_state(dut.u_tx.state));

    // ---------------- receive event log ----------------
    typedef struct packed { logic [7:0] d; logic v; logic pe; logic fe; } ev_t;
    ev_t evq[$];
    always @(posedge clk) if (rst_n && (rx_valid || frame_err))
        evq.push_back('{rx_data, rx_valid, parity_err, frame_err});

    int fails = 0, groups_fail = 0;
    task automatic chk_(bit ok, string msg);
        if (!ok) begin fails++; $display("ERROR %0t: %s", $time, msg); end
    endtask
    task automatic group(string name, int f0);
        if (fails != f0) groups_fail++;
        $display("%-44s : %s", name, (fails == f0) ? "PASS" : "FAIL");
    endtask

    function automatic logic par_of(logic [7:0] d, logic [1:0] m);
        return (m == 2'b10) ? ~(^d) : (^d);
    endfunction
    function automatic bit has_par(logic [1:0] m);
        return m == 2'b01 || m == 2'b10;
    endfunction

    task automatic do_reset(int cyc = 3);
        @(negedge clk) rst_n = 0;
        repeat (cyc) @(posedge clk);
        @(negedge clk) rst_n = 1;
        repeat (2) @(posedge clk);
    endtask
    task automatic dut_send(logic [7:0] d);
        @(negedge clk); tx_data = d; tx_start = 1;
        @(negedge clk); tx_start = 0;
    endtask
    task automatic idle_bits(int n); repeat (n * BITC) @(posedge clk); endtask
    task automatic wait_tx_idle(); while (tx_busy) @(posedge clk); endtask
    // BFM: drive one bit for 'clocks' clocks
    task automatic drv(logic b, int clocks);
        @(negedge clk) bfm_line = b;
        repeat (clocks - 1) @(negedge clk);
    endtask
    task automatic bfm_frame(logic [7:0] d, logic [1:0] m, bit bad_par = 0, bit bad_stop = 0, bit hold = 0);
        drv(0, BITC);
        for (int i = 0; i < 8; i++) drv(d[i], BITC);
        if (has_par(m)) drv(par_of(d, m) ^ bad_par, BITC);
        drv(!bad_stop, BITC);
        if (hold) drv(0, 2 * BITC);   // keep the line low (break) after a bad stop
        @(negedge clk) bfm_line = 1;
    endtask
    // one good frame through loopback, must be received intact
    task automatic check_recovery(string tag);
        evq.delete();
        dut_send(8'hA5); wait_tx_idle(); idle_bits(2);
        chk_(evq.size() == 1 && evq[0].v && evq[0].d == 8'hA5 && !evq[0].pe && !evq[0].fe,
             $sformatf("%s: recovery frame wrong (n=%0d)", tag, evq.size()));
    endtask

`ifdef DUMP
    // top-level signals only (keeps the file small); used for waves/*.png
    initial begin string f; if (!$value$plusargs("vcd=%s", f)) f = "waves/tb_edge_err.vcd"; $dumpfile(f); $dumpvars(1, tb_edge); end
`endif
    initial begin
        int f0;
        $display("tb_edge: DIV=%0d FRAMES=%0d FULL=%0d", DIV, FRAMES, FULL);
        do_reset();

        // ---- E4 (+E1 at this DIV): back-to-back, every parity code ----
        for (int m = 0; m < 4; m++) begin
            logic [7:0] sent[$];
            f0 = fails; pmode = 2'(m); evq.delete(); sent.delete();
            @(negedge clk); tx_start = 1;
            for (int i = 0; i < FRAMES; i++) begin
                tx_data = 8'(i * 37 + m * 11 + (i == 0 ? 8'hFF : 0));
                sent.push_back(tx_data);
                @(posedge clk); while (!dut.tx_go) @(posedge clk);
                @(negedge clk);
            end
            tx_start = 0; wait_tx_idle(); idle_bits(2);
            chk_(evq.size() == FRAMES, $sformatf("mode %0d: got %0d frames, sent %0d", m, evq.size(), FRAMES));
            for (int i = 0; i < evq.size() && i < FRAMES; i++)
                chk_(evq[i].v && !evq[i].pe && !evq[i].fe && evq[i].d == sent[i],
                     $sformatf("mode %0d frame %0d: exp %02h got %02h pe=%b fe=%b", m, i, sent[i], evq[i].d, evq[i].pe, evq[i].fe));
            group($sformatf("E4 back-to-back DIV=%0d parity_mode=%0d%0d", DIV, m[1], m[0]), f0);
        end

        if (FULL) begin
            // ---- E2: reset in every TX state ----
            for (int st = 1; st <= 4; st++) begin
                f0 = fails; pmode = 2'b01;
                dut_send(8'h3C);
                while (dut.u_tx.state != 3'(st)) @(posedge clk);
                repeat (BITC / 2) @(posedge clk);
                @(negedge clk) rst_n = 0;
                @(posedge clk); #1;
                chk_(dut_tx === 1 && tx_busy === 0 && dut.u_tx.state == 0, $sformatf("TX st %0d: not idle in reset", st));
                @(negedge clk) rst_n = 1; idle_bits(12);
                check_recovery($sformatf("TX st %0d", st));
                group($sformatf("E2 reset during TX state %0d", st), f0);
            end
            // ---- E3: reset in every RX state (BFM drives line) ----
            for (int st = 1; st <= 5; st++) begin
                f0 = fails; pmode = 2'b01; bfm_sel = 1;
                fork
                    begin bfm_frame(8'h5A, 2'b01, 0, st == 5, st == 5); #1; @(negedge clk); end
                    begin
                        while (dut.u_rx.state != 3'(st)) @(posedge clk);
                        repeat (st == 1 ? 2 : BITC / 4) @(posedge clk);
                        evq.delete();
                        @(negedge clk) rst_n = 0;
                        @(posedge clk); #1;
                        chk_(dut.u_rx.state == 0 && !rx_valid && !frame_err, $sformatf("RX st %0d: not idle in reset", st));
                        @(negedge clk) rst_n = 1;
                        // the line driver stops with the reset (line back to idle)
                        @(negedge clk) bfm_line = 1;
                    end
                join_any
                disable fork;
                bfm_line = 1;
                idle_bits(2);
                // a reset frame must not produce a byte (it may produce nothing at all)
                chk_(evq.size() == 0,
                     $sformatf("RX st %0d: %0d unexpected events after reset", st, evq.size()));
                bfm_sel = 0; idle_bits(12);
                check_recovery($sformatf("RX st %0d", st));
                group($sformatf("E3 reset during RX state %0d", st), f0);
            end
            // ---- E5a: start glitches shorter than half a bit ----
            begin
                int lens[4] = '{1, BITC / 8, BITC / 4, BITC / 2 - 2 * DIV - 2};
                f0 = fails; bfm_sel = 1; evq.delete();
                foreach (lens[i]) if (lens[i] > 0) begin drv(0, lens[i]); drv(1, 3 * BITC); end
                idle_bits(12);
                chk_(evq.size() == 0, $sformatf("glitches gave %0d events", evq.size()));
                bfm_sel = 0; check_recovery("glitch");
                group("E5a start glitch (< half bit) rejected", f0);
            end
            // ---- E5b: bad stop bit in every parity code ----
            for (int m = 0; m < 4; m++) begin
                f0 = fails; pmode = 2'(m); bfm_sel = 1; evq.delete();
                $display("MARK E5b_mode%0d %0t", m, $time);
                bfm_frame(8'hC9, 2'(m), 0, 1, 1);   // bad stop, line held low (break)
                idle_bits(12);
                chk_(evq.size() == 1 && evq[0].fe && !evq[0].v, $sformatf("bad stop mode %0d: n=%0d", m, evq.size()));
                bfm_sel = 0; check_recovery("bad stop");
                group($sformatf("E5b bad stop -> frame_err, parity_mode=%0d%0d", m[1], m[0]), f0);
            end
            // ---- E5c: wrong parity bit (even and odd) ----
            for (int m = 1; m <= 2; m++) begin
                f0 = fails; pmode = 2'(m); bfm_sel = 1; evq.delete();
                $display("MARK E5c_mode%0d %0t", m, $time);
                bfm_frame(8'h96, 2'(m), 1, 0); idle_bits(2);
                bfm_frame(8'h97, 2'(m), 0, 0); idle_bits(2);
                chk_(evq.size() == 2 && evq[0].v && evq[0].pe && evq[0].d == 8'h96 &&
                     evq[1].v && !evq[1].pe && evq[1].d == 8'h97, $sformatf("parity mode %0d wrong (n=%0d)", m, evq.size()));
                bfm_sel = 0;
                group($sformatf("E5c parity error detect, parity_mode=%0d", m), f0);
            end
        end

        chk.report();
        chk2.report();
        $display("RESULT tb_edge DIV=%0d : %s (%0d failing groups, %0d errors)", DIV,
                 groups_fail ? "FAIL" : "PASS", groups_fail, fails);
        if (groups_fail) $fatal(1, "tb_edge failures");
        $finish;
    end
endmodule
