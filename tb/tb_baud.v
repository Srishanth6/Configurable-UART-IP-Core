// tb_baud.v - checks that the tick period equals the divisor
`timescale 1ns/1ps
module tb_baud;
    reg clk = 0, rst_n = 0, clr = 0;
    reg [15:0] div;
    wire tick;
    integer period, last, now, k, n, errs, checks;
    integer divs [0:3];

    always #10 clk = ~clk;   // 50 MHz

    uart_baud_gen #(.DIV_W(16)) dut (.clk(clk), .rst_n(rst_n), .clr(clr), .en(1'b1), .divisor(div), .tick(tick));

    initial begin
        $dumpfile("waves/tb_baud.vcd");
        $dumpvars(0, tb_baud);
        // 4 = fast sim value, 27 = 50MHz @115200, 163 = 50MHz @19200, 326 = 50MHz @9600
        divs[0] = 4; divs[1] = 27; divs[2] = 163; divs[3] = 326;
        errs = 0; checks = 0;
        for (k = 0; k < 4; k = k + 1) begin
            div = divs[k];
            rst_n = 0; repeat (3) @(posedge clk); rst_n = 1;
            @(posedge clk); while (!tick) @(posedge clk);
            last = $time;
            for (n = 0; n < 50; n = n + 1) begin
                @(posedge clk); while (!tick) @(posedge clk);
                now = $time;
                period = (now - last) / 20;
                checks = checks + 1;
                if ((now - last) / 20 != div) begin
                    errs = errs + 1;
                    $display("ERROR div=%0d measured period=%0d clks", div, (now-last)/20);
                end
                last = now;
            end
            $display("divisor=%0d : last measured tick period = %0d clocks (expected %0d), 50 periods checked", div, period, div);
        end
        // clr restarts the count: first tick must come exactly div clocks after clr
        div = 27;
        @(posedge clk); #1 clr = 1; @(posedge clk); #1 clr = 0; last = $time;
        n = 0;
        while (!tick) begin @(posedge clk); #1; n = n + 1; end
        checks = checks + 1;
        if (n != 26) begin errs = errs + 1; $display("ERROR clr: tick %0d clks after clr released", n); end
        else $display("clr check: first tick seen %0d clocks after the clr edge (expected 26 = div-1)", n);
        $display("BAUD_TEST checks=%0d errors=%0d -> %s", checks, errs, errs ? "FAIL" : "PASS");
        $finish;
    end
endmodule
