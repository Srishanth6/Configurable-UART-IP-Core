// uart_linemon.v - line quality monitor
// Saturating event counters, bit-edge drift tracking and a simple
// 0..100 "health" score worked out every 32 received frames:
//   penalty = 4 * (errors in window) + 8 * max(0, |drift|max - 2)
//   health  = 100 - penalty (clamped at 0)
// errors = parity + framing + uncorrectable ECC (+1 per corrected ECC)
module uart_linemon (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              clr,          // clears all counters
    input  wire              frame_ok,     // rx_valid from the frame RX
    input  wire              parity_err,
    input  wire              frame_err,
    input  wire              ecc_corr,
    input  wire              ecc_uncorr,
    input  wire              edge_pulse,
    input  wire signed [4:0] edge_drift,
    output reg  [15:0]       cnt_frames,
    output reg  [15:0]       cnt_parity,
    output reg  [15:0]       cnt_framing,
    output reg  [15:0]       cnt_corr,
    output reg  [15:0]       cnt_uncorr,
    output reg signed [4:0]  drift_last,
    output reg  [3:0]        drift_max,    // worst |drift| since clear
    output reg  [6:0]        health
);
    reg [4:0] win_frames;
    reg [7:0] win_errs;
    reg [3:0] win_dmax;

    wire       any_frame = frame_ok | frame_err;
    wire [3:0] abs_d     = edge_drift[4] ? (~edge_drift[3:0] + 1'b1) : edge_drift[3:0];
    wire [2:0] new_errs  = {2'b00, parity_err} + {2'b00, frame_err} + {2'b00, ecc_corr} + {2'b00, ecc_uncorr};
    wire [8:0] errs_now  = {1'b0, win_errs} + {6'd0, new_errs};
    wire [3:0] dmax_now  = (edge_pulse && abs_d > win_dmax) ? abs_d : win_dmax;
    wire [10:0] pen_e    = {errs_now, 2'b00};
    wire [10:0] pen_d    = (dmax_now > 4'd2) ? {4'd0, dmax_now - 4'd2, 3'b000} : 11'd0;
    wire [11:0] penalty  = pen_e + pen_d;

    function [15:0] sat_inc(input [15:0] v, input en);
        sat_inc = (en && v != 16'hFFFF) ? v + 1'b1 : v;
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt_frames <= 0; cnt_parity <= 0; cnt_framing <= 0;
            cnt_corr <= 0; cnt_uncorr <= 0;
            drift_last <= 0; drift_max <= 0; health <= 7'd100;
            win_frames <= 0; win_errs <= 0; win_dmax <= 0;
        end else if (clr) begin
            cnt_frames <= 0; cnt_parity <= 0; cnt_framing <= 0;
            cnt_corr <= 0; cnt_uncorr <= 0;
            drift_last <= 0; drift_max <= 0; health <= 7'd100;
            win_frames <= 0; win_errs <= 0; win_dmax <= 0;
        end else begin
            cnt_frames  <= sat_inc(cnt_frames,  any_frame);
            cnt_parity  <= sat_inc(cnt_parity,  parity_err);
            cnt_framing <= sat_inc(cnt_framing, frame_err);
            cnt_corr    <= sat_inc(cnt_corr,    ecc_corr);
            cnt_uncorr  <= sat_inc(cnt_uncorr,  ecc_uncorr);
            if (edge_pulse) begin
                drift_last <= edge_drift;
                if (abs_d > drift_max) drift_max <= abs_d;
            end
            if (any_frame && win_frames == 5'd31) begin
                health     <= (penalty >= 12'd100) ? 7'd0 : 7'd100 - penalty[6:0];
                win_frames <= 0;
                win_errs   <= 0;
                win_dmax   <= 0;
            end else begin
                if (any_frame) win_frames <= win_frames + 1'b1;
                win_errs <= errs_now[8] ? 8'hFF : errs_now[7:0];
                win_dmax <= dmax_now;
            end
        end
    end
endmodule
