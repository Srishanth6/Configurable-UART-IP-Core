// uart_rx.v
// 2-FF synchroniser on rx, start bit detected on a low sample at a tick,
// re-checked 8 ticks later (middle of start bit) to throw away glitches,
// then every bit sampled 16 ticks apart (middle of each bit).
// rx_valid  : 1-clock pulse, only when stop bit was 1
// parity_err: pulses together with rx_valid when parity is wrong
// frame_err : 1-clock pulse when stop bit was 0 (no rx_valid then)
// LOWPWR = 1: the baud counter is stopped while idle, so the start bit is
// picked up straight from the synchronised line (no tick needed) and the
// counter is restarted from zero at that moment.
// edge_pulse/edge_drift: every time the line changes inside a frame we
// note where it happened compared with the ideal bit boundary
// (in 1/16 bit units, signed). Used by the line-quality monitor.
module uart_rx #(
    parameter PARITY_SUPPORT = 1,
    parameter LOWPWR         = 0
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       tick,
    input  wire       rx,
    input  wire [1:0] parity_mode,
    output reg  [7:0] rx_data,
    output reg        rx_valid,
    output reg        parity_err,
    output reg        frame_err,
    output wire       rx_busy,
    output reg        edge_pulse,
    output reg signed [4:0] edge_drift
);
    localparam SR_IDLE  = 3'd0,
               SR_START = 3'd1,
               SR_DATA  = 3'd2,
               SR_PAR   = 3'd3,
               SR_STOP  = 3'd4,
               SR_BREAK = 3'd5;   // wait for line to go high after a bad stop

    reg       rx_m, rx_s;          // synchroniser flops
    reg       rx_prev;             // for edge detection inside a frame
    reg [2:0] state;
    reg [3:0] tcnt;
    reg [2:0] bit_no;
    reg [7:0] shreg;
    reg       par_en, par_odd, par_rcv;
`ifdef INJECT_BUG
    reg       bug_hold;
    initial   bug_hold = 1'b0;
`endif

    wire [1:0] pmode   = (PARITY_SUPPORT != 0) ? parity_mode : 2'b00;
    wire       mid_bit = tick && (tcnt == 4'd15);
    wire       wake    = (LOWPWR != 0) ? !rx_s : (tick && !rx_s);
    wire       in_bits = (state == SR_DATA) || (state == SR_PAR) || (state == SR_STOP);

    assign rx_busy = (state != SR_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_m    <= 1'b1;
            rx_s    <= 1'b1;
            rx_prev <= 1'b1;
        end else begin
            rx_m    <= rx;
            rx_s    <= rx_m;
            rx_prev <= rx_s;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= SR_IDLE;
            tcnt       <= 4'd0;
            bit_no     <= 3'd0;
            shreg      <= 8'd0;
            rx_data    <= 8'd0;
            rx_valid   <= 1'b0;
            parity_err <= 1'b0;
            frame_err  <= 1'b0;
            par_en     <= 1'b0;
            par_odd    <= 1'b0;
            par_rcv    <= 1'b0;
            edge_pulse <= 1'b0;
            edge_drift <= 5'sd0;
        end else begin
            // ideal bit boundary is when tcnt steps 7 -> 8
            edge_pulse <= in_bits && (rx_s != rx_prev);
            if (in_bits && (rx_s != rx_prev))
                edge_drift <= $signed({1'b0, tcnt}) - 5'sd8;
            rx_valid   <= 1'b0;
`ifdef INJECT_BUG
            // deliberate bug for the negative assertion test:
            // rx_valid is stretched to two clocks
            if (rx_valid && !bug_hold) begin
                rx_valid <= 1'b1;
                bug_hold <= 1'b1;
            end else
                bug_hold <= 1'b0;
`endif
            parity_err <= 1'b0;
            frame_err  <= 1'b0;
            if (tick && state != SR_IDLE && state != SR_BREAK)
                tcnt <= tcnt + 1'b1;

            case (state)
            SR_IDLE: if (wake) begin
                tcnt    <= 4'd8;              // 8 more ticks -> middle of start bit
                par_en  <= (pmode == 2'b01) || (pmode == 2'b10);
                par_odd <= (pmode == 2'b10);
                state   <= SR_START;
            end
            SR_START: if (mid_bit) begin
                if (!rx_s) begin
                    bit_no <= 3'd0;
                    state  <= SR_DATA;
                end else begin
                    state  <= SR_IDLE;        // glitch, not a real start bit
                end
            end
            SR_DATA: if (mid_bit) begin
                shreg <= {rx_s, shreg[7:1]};  // LSB arrives first
                if (bit_no == 3'd7)
                    state <= par_en ? SR_PAR : SR_STOP;
                else
                    bit_no <= bit_no + 1'b1;
            end
            SR_PAR: if (mid_bit) begin
                par_rcv <= rx_s;
                state   <= SR_STOP;
            end
            SR_STOP: if (mid_bit) begin
                if (rx_s) begin
                    rx_data    <= shreg;
                    rx_valid   <= 1'b1;
                    parity_err <= par_en && (par_rcv != (par_odd ? ~(^shreg) : (^shreg)));
                    state      <= SR_IDLE;
                end else begin
                    frame_err  <= 1'b1;
                    state      <= SR_BREAK;
                end
            end
            SR_BREAK: if (rx_s) state <= SR_IDLE;
            default: state <= SR_IDLE;
            endcase
        end
    end

endmodule
