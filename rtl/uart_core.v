// uart_core.v - top level of the UART IP
//
// Base UART = baud generators + uart_tx + uart_rx. The four extras are
// switched on with parameters, so with all of them at 0 you get the
// plain UART back (unused logic is not generated):
//   AUTOBAUD_EN : divisor can be measured from a 0x55 sync character
//   ECC_EN      : every user byte is sent as a SECDED(13,8) codeword
//                 split over two frames, RX corrects 1-bit errors
//   LOWPWR_EN   : oversampling counters only run while a frame is active
//   LINEMON_EN  : error counters, bit-timing drift and a health score
module uart_core #(
    parameter DIV_W          = 16,
    parameter PARITY_SUPPORT = 1,
    parameter AUTOBAUD_EN    = 0,
    parameter ECC_EN         = 0,
    parameter LOWPWR_EN      = 0,
    parameter LINEMON_EN     = 0
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire [DIV_W-1:0] divisor,      // CLK_FREQ/(BAUD*16), used until auto-baud locks
    input  wire [1:0]       parity_mode,  // 00 none, 01 even, 10 odd
    // transmit side (user bytes)
    input  wire             tx_start,
    input  wire [7:0]       tx_data,
    output wire             tx,
    output wire             tx_busy,
    output wire             tx_done,
    // receive side (user bytes)
    input  wire             rx,
    output wire [7:0]       rx_data,
    output wire             rx_valid,
    output wire             parity_err,
    output wire             frame_err,
    // auto-baud
    input  wire             abd_start,
    output wire             abd_busy,
    output wire             abd_locked,
    output wire             abd_err,
    output wire [DIV_W-1:0] div_active,   // divisor actually in use
    // ECC status
    output wire             ecc_corr,
    output wire             ecc_uncorr,
    // line monitor
    input  wire             mon_clr,
    output wire [15:0]      mon_frames,
    output wire [15:0]      mon_parity,
    output wire [15:0]      mon_framing,
    output wire [15:0]      mon_corr,
    output wire [15:0]      mon_uncorr,
    output wire signed [4:0] mon_drift_last,
    output wire [3:0]       mon_drift_max,
    output wire [6:0]       mon_health
);
    // ---------------- auto-baud ----------------
    wire [DIV_W-1:0] abd_div;
    wire             abd_lockp;
    generate if (AUTOBAUD_EN != 0) begin : g_abd
        uart_autobaud #(.DIV_W(DIV_W)) u_abd (
            .clk(clk), .rst_n(rst_n), .start(abd_start), .rx(rx),
            .busy(abd_busy), .locked(abd_locked), .lock_pulse(abd_lockp),
            .lock_err(abd_err), .div_out(abd_div));
        assign div_active = abd_locked ? abd_div : divisor;
    end else begin : g_no_abd
        assign abd_busy   = 1'b0;
        assign abd_locked = 1'b0;
        assign abd_err    = 1'b0;
        assign abd_lockp  = 1'b0;
        assign abd_div    = {DIV_W{1'b0}};
        assign div_active = divisor;
    end endgenerate

    // RX does not see the sync character
    wire rx_line = abd_busy ? 1'b1 : rx;

    // ---------------- frame level TX / RX ----------------
    wire       f_tx_start, f_tx_busy, f_tx_done, tx_go;
    wire [7:0] f_tx_data;
    wire       f_rx_valid, f_perr, f_ferr, rx_busy_i, edge_p;
    wire [7:0] f_rx_data;
    wire signed [4:0] edge_d;
    wire       tx_tick, rx_tick;

    // low power: counters frozen while idle, RX counter held at 0 until
    // a start bit wakes the receiver up
    wire tx_bg_en = (LOWPWR_EN != 0) ? (f_tx_busy | tx_go) : 1'b1;
    wire rx_bg_en = (LOWPWR_EN != 0) ? rx_busy_i : 1'b1;
    wire rx_bg_clr = (LOWPWR_EN != 0) ? ~rx_busy_i : 1'b0;

    uart_baud_gen #(.DIV_W(DIV_W)) u_bg_tx (
        .clk(clk), .rst_n(rst_n), .clr(tx_go), .en(tx_bg_en),
        .divisor(div_active), .tick(tx_tick));

    uart_baud_gen #(.DIV_W(DIV_W)) u_bg_rx (
        .clk(clk), .rst_n(rst_n), .clr(rx_bg_clr), .en(rx_bg_en),
        .divisor(div_active), .tick(rx_tick));

    uart_tx #(.PARITY_SUPPORT(PARITY_SUPPORT)) u_tx (
        .clk(clk), .rst_n(rst_n), .tick(tx_tick),
        .tx_start(f_tx_start), .tx_data(f_tx_data), .parity_mode(parity_mode),
        .tx(tx), .tx_busy(f_tx_busy), .tx_done(f_tx_done), .start_accept(tx_go));

    uart_rx #(.PARITY_SUPPORT(PARITY_SUPPORT), .LOWPWR(LOWPWR_EN)) u_rx (
        .clk(clk), .rst_n(rst_n), .tick(rx_tick), .rx(rx_line),
        .parity_mode(parity_mode), .rx_data(f_rx_data), .rx_valid(f_rx_valid),
        .parity_err(f_perr), .frame_err(f_ferr), .rx_busy(rx_busy_i),
        .edge_pulse(edge_p), .edge_drift(edge_d));

    assign parity_err = f_perr;
    assign frame_err  = f_ferr;

    // ---------------- ECC layer ----------------
    generate if (ECC_EN != 0) begin : g_ecc
        uart_ecc_tx u_etx (
            .clk(clk), .rst_n(rst_n), .start(tx_start), .data(tx_data),
            .busy(tx_busy), .done(tx_done),
            .f_start(f_tx_start), .f_data(f_tx_data),
            .f_busy(f_tx_busy), .f_done(f_tx_done));
        /* verilator lint_off PINCONNECTEMPTY */
        uart_ecc_rx #(.DIV_W(DIV_W)) u_erx (
            .clk(clk), .rst_n(rst_n), .divisor(div_active),
            .f_valid(f_rx_valid), .f_data(f_rx_data), .f_err(f_ferr),
            .data(rx_data), .valid(rx_valid), .corrected(ecc_corr),
            .uncorrectable(ecc_uncorr), .dropped());
        /* verilator lint_on PINCONNECTEMPTY */
    end else begin : g_no_ecc
        assign f_tx_start = tx_start;
        assign f_tx_data  = tx_data;
        assign tx_busy    = f_tx_busy;
        assign tx_done    = f_tx_done;
        assign rx_data    = f_rx_data;
        assign rx_valid   = f_rx_valid;
        assign ecc_corr   = 1'b0;
        assign ecc_uncorr = 1'b0;
    end endgenerate

    // ---------------- line monitor ----------------
    generate if (LINEMON_EN != 0) begin : g_mon
        uart_linemon u_mon (
            .clk(clk), .rst_n(rst_n), .clr(mon_clr),
            .frame_ok(f_rx_valid), .parity_err(f_perr), .frame_err(f_ferr),
            .ecc_corr(ecc_corr), .ecc_uncorr(ecc_uncorr),
            .edge_pulse(edge_p), .edge_drift(edge_d),
            .cnt_frames(mon_frames), .cnt_parity(mon_parity),
            .cnt_framing(mon_framing), .cnt_corr(mon_corr),
            .cnt_uncorr(mon_uncorr), .drift_last(mon_drift_last),
            .drift_max(mon_drift_max), .health(mon_health));
    end else begin : g_no_mon
        assign mon_frames = 0; assign mon_parity = 0; assign mon_framing = 0;
        assign mon_corr = 0;   assign mon_uncorr = 0; assign mon_drift_last = 0;
        assign mon_drift_max = 0; assign mon_health = 7'd100;
    end endgenerate

    // keep lint quiet about things only used in some configurations
    wire unused_ok = &{1'b0, abd_lockp, edge_p, edge_d, mon_clr, abd_start};
endmodule
