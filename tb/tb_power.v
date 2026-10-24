// tb_power.v - same traffic for LOWPWR_EN = 0 and 1, VCD used to count
// signal toggles (a rough activity / dynamic power proxy, not real power).
// Traffic: 40 bytes, each followed by a long idle gap (~20 frame times),
// which is what a UART on a sensor link mostly looks like.
`timescale 1ns/1ps
module tb_power;
    parameter LP  = 0;
    parameter DIV = 27;                 // 50 MHz / (16 * 115200)

    reg clk = 0, rst_n = 0, tx_start = 0;
    reg [7:0] tx_data = 0;
    reg phase_active = 0;               // 1 while a frame is on the line
    wire line, tx_busy, tx_done, rx_valid, perr, ferr;
    wire [7:0] rx_data;
    integer i, nrx = 0, nerr = 0;

    always #10 clk = ~clk;

    uart_core #(.DIV_W(16), .LOWPWR_EN(LP)) dut (
        .clk(clk), .rst_n(rst_n), .divisor(DIV[15:0]), .parity_mode(2'b01),
        .tx_start(tx_start), .tx_data(tx_data), .tx(line), .tx_busy(tx_busy), .tx_done(tx_done),
        .rx(line), .rx_data(rx_data), .rx_valid(rx_valid), .parity_err(perr), .frame_err(ferr),
        .abd_start(1'b0), .mon_clr(1'b0));

    always @(posedge clk) if (rx_valid) begin
        nrx = nrx + 1;
        if (perr) nerr = nerr + 1;
    end

    initial begin
        if (LP) $dumpfile("waves/power_lp1.vcd"); else $dumpfile("waves/power_lp0.vcd");
        $dumpvars(0, tb_power.dut);
        $dumpvars(0, tb_power.phase_active);
        repeat (5) @(posedge clk); rst_n = 1;
        for (i = 0; i < 40; i = i + 1) begin
            @(negedge clk) begin tx_data = i * 37 + 5; tx_start = 1; phase_active = 1; end
            @(negedge clk) tx_start = 0;
            @(posedge clk); while (tx_busy || dut.rx_busy_i) @(posedge clk);
            @(negedge clk) phase_active = 0;
            repeat (20 * 11 * 16 * DIV) @(posedge clk);
        end
        $display("POWER_TB LP=%0d bytes_received=%0d parity_errors=%0d", LP, nrx, nerr);
        $finish;
    end
endmodule
