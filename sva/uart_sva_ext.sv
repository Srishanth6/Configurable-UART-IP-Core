// uart_sva_ext.sv - extra checks added after review: baud timing, RX
// mid-bit sampling, reset behaviour and parameter/divisor boundaries.
// Connected from tb/tb_edge.sv (base config, LOWPWR_EN=0).
module uart_sva_ext #(
    parameter DIV_W = 16
)(
    input logic             clk,
    input logic             rst_n,
    input logic [DIV_W-1:0] divisor,
    // baud generator (TX side)
    input logic             bg_tick,
    input logic             bg_clr,
    input logic             bg_en,
    // receiver internals
    input logic             rx_tick,
    input logic [2:0]       rx_state,
    input logic [3:0]       rx_tcnt,
    input logic [2:0]       rx_bit_no,
    // outputs that must be quiet during reset
    input logic             tx,
    input logic             tx_busy,
    input logic             rx_valid,
    input logic             frame_err,
    input logic             parity_err,
    input logic [2:0]       tx_state
);
    // B4a: elaboration-time parameter boundary
    initial begin
        if (DIV_W < 1 || DIV_W > 32) $fatal(1, "B4 DIV_W=%0d out of range 1..32", DIV_W);
    end

    // ---- B1: baud tick period == divisor clocks (when not cleared/frozen) ----
    int unsigned since_tick;
    bit          seen_tick;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin since_tick <= 0; seen_tick <= 0; end
        else if (bg_clr || !bg_en) begin since_tick <= 0; seen_tick <= 0; end
        else if (bg_tick) begin since_tick <= 1; seen_tick <= 1; end
        else since_tick <= since_tick + 1;
    end
    a_baud_period: assert property (@(posedge clk) disable iff (!rst_n)
        (bg_tick && seen_tick && !bg_clr && bg_en) |-> (since_tick == int'(divisor)))
        else $error("B1 baud tick period %0d clocks, expected divisor=%0d", since_tick, divisor);
    // B1b: tick never comes faster than every 'divisor' clocks, and can't stall
    a_baud_no_stall: assert property (@(posedge clk) disable iff (!rst_n || bg_clr || !bg_en)
        seen_tick |-> (since_tick <= int'(divisor)))
        else $error("B1b no baud tick for %0d clocks (divisor=%0d)", since_tick, divisor);

    // ---- B2: RX samples in the middle of each bit ----
    // start detected (IDLE->START) counts as tick 0 = start edge seen.
    // middle of start bit = 8 ticks later, data bit n at 8+16*(n+1).
    localparam logic [2:0] R_IDLE = 3'd0, R_START = 3'd1, R_DATA = 3'd2;
    int unsigned rx_ticks;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) rx_ticks <= 0;
        else if (rx_state == R_IDLE) rx_ticks <= 0;
        else if (rx_tick) rx_ticks <= rx_ticks + 1;
    end
    wire rx_sample = rx_tick && rx_tcnt == 4'd15;
    a_rx_mid_start: assert property (@(posedge clk) disable iff (!rst_n)
        (rx_sample && rx_state == R_START) |-> (rx_ticks + 1 == 8))
        else $error("B2 start bit sampled at tick %0d, expected 8", rx_ticks + 1);
    a_rx_mid_data: assert property (@(posedge clk) disable iff (!rst_n)
        (rx_sample && rx_state == R_DATA) |-> (rx_ticks + 1 == 8 + 16 * (int'(rx_bit_no) + 1)))
        else $error("B2 data bit %0d sampled at tick %0d, expected %0d", rx_bit_no, rx_ticks + 1, 8 + 16 * (int'(rx_bit_no) + 1));

    // ---- B3: reset behaviour (no disable iff on purpose) ----
    // checked from the 2nd clock of a reset, so a reset that is already low
    // at time 0 (no negedge seen) has had one edge to take effect
    logic rst_q;
    initial rst_q = 1'b1;
    always @(posedge clk) rst_q <= rst_n;
    a_reset_quiet: assert property (@(posedge clk)
        (!rst_n && !rst_q) |-> (tx && !tx_busy && !rx_valid && !frame_err && !parity_err && tx_state == 3'd0 && rx_state == 3'd0))
        else $error("B3 outputs/state not at reset values while rst_n=0");
    a_reset_release: assert property (@(posedge clk)
        $rose(rst_n) |-> (tx && !tx_busy && rx_state == 3'd0))
        else $error("B3 not idle on reset release");

    // ---- B4b: run-time divisor boundary (0 is illegal) ----
    a_div_nonzero: assert property (@(posedge clk) disable iff (!rst_n)
        divisor != 0)
        else $error("B4 divisor is 0 (illegal)");

    int hit_b1, hit_b2s, hit_b2d, hit_b3;
    initial begin hit_b1 = 0; hit_b2s = 0; hit_b2d = 0; hit_b3 = 0; end
    always @(posedge clk) begin
        if (rst_n && bg_tick && seen_tick && !bg_clr && bg_en) hit_b1++;
        if (rst_n && rx_sample && rx_state == R_START) hit_b2s++;
        if (rst_n && rx_sample && rx_state == R_DATA)  hit_b2d++;
        if (!rst_n) hit_b3++;
    end
    function void report();
        $display("SVA-ext antecedent hits: B1 tick_period=%0d B2 start_mid=%0d B2 data_mid=%0d B3 reset_cycles=%0d",
                 hit_b1, hit_b2s, hit_b2d, hit_b3);
    endfunction
endmodule
