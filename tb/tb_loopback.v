// tb_loopback.v - TX output wired straight to RX input.
// Sends all 256 byte values in each parity mode (none / even / odd)
// and checks the received byte and the error flags.
`timescale 1ns/1ps
module tb_loopback;
    parameter DIV = 4;   // small divisor keeps the sim short

    reg        clk = 0, rst_n = 0;
    reg  [1:0] pmode = 2'b00;
    reg        tx_start = 0;
    reg  [7:0] tx_data = 0;
    wire       line, tx_busy, tx_done, rx_valid, parity_err, frame_err;
    wire [7:0] rx_data;

    integer m, b, pass_cnt, fail_cnt, t0;
    integer pass_mode [0:2];

    always #10 clk = ~clk;

    uart_core #(.DIV_W(16), .PARITY_SUPPORT(1)) dut (
        .clk(clk), .rst_n(rst_n), .divisor(DIV[15:0]), .parity_mode(pmode),
        .tx_start(tx_start), .tx_data(tx_data), .tx(line), .tx_busy(tx_busy), .tx_done(tx_done),
        .rx(line), .rx_data(rx_data), .rx_valid(rx_valid),
        .parity_err(parity_err), .frame_err(frame_err));

    // catch a framing error at any time
    always @(posedge clk) if (rst_n && frame_err) begin
        $display("ERROR: unexpected frame_err at %0t", $time);
        fail_cnt = fail_cnt + 1;
    end

    task send_and_check(input [7:0] val);
        begin
            @(negedge clk); tx_data = val; tx_start = 1;
            @(negedge clk); tx_start = 0;
            t0 = 0;
            while (!rx_valid && t0 < 20*16*DIV) begin @(posedge clk); #1; t0 = t0 + 1; end
            if (!rx_valid) begin
                $display("ERROR mode=%0d byte=%02h : timeout", pmode, val);
                fail_cnt = fail_cnt + 1;
            end else if (rx_data !== val || parity_err) begin
                $display("ERROR mode=%0d sent=%02h got=%02h perr=%b", pmode, val, rx_data, parity_err);
                fail_cnt = fail_cnt + 1;
            end else
                pass_cnt = pass_cnt + 1;
            while (tx_busy) @(posedge clk);
        end
    endtask

    initial begin
        $dumpfile("waves/tb_loopback.vcd");
        $dumpvars(0, tb_loopback);
        pass_cnt = 0; fail_cnt = 0;
        repeat (5) @(posedge clk); rst_n = 1;
        for (m = 0; m < 3; m = m + 1) begin
            pmode = m;
            pass_mode[m] = pass_cnt;
            for (b = 0; b < 256; b = b + 1) begin
                send_and_check(b[7:0]);
                if (m == 0 && b == 3) $dumpoff;   // keep the VCD small: first few frames of each mode
            end
            pass_mode[m] = pass_cnt - pass_mode[m];
            $display("parity_mode=%0d (%s): %0d/256 bytes OK", m,
                     m==0 ? "none" : (m==1 ? "even" : "odd"), pass_mode[m]);
            if (m < 2) $dumpon;
            if (m < 2) begin send_and_check(8'hA5); send_and_check(8'h3C); $dumpoff; end
        end
        $display("LOOPBACK_TEST frames_checked=%0d pass=%0d fail=%0d -> %s",
                 pass_cnt + fail_cnt, pass_cnt, fail_cnt, fail_cnt ? "FAIL" : "PASS");
        $finish;
    end
endmodule
