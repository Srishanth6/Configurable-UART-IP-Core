// uart_autobaud.v
// Auto-baud: the other side sends 0x55 once after 'start'.
// 0x55 on the line (LSB first) = start 0,1,0,1,0,1,0,1,0, stop 1
// so there is a falling edge at bit times 0,2,4,6,8. The time from the
// first fall to the 5th fall is exactly 8 bit times = 128 ticks, so
//      divisor = round(T / 128) = (T + 64) >> 7      (no divider needed)
// The RX is kept away from the line (masked by the core) until the
// sync character is over and the line is back high.
module uart_autobaud #(
    parameter DIV_W = 16
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             start,        // pulse: begin a measurement
    input  wire             rx,           // raw line
    output wire             busy,
    output reg              locked,       // stays high once a value is found
    output reg              lock_pulse,   // 1 clock when locked goes high
    output reg              lock_err,     // 1 clock: measurement overflow / too fast
    output reg  [DIV_W-1:0] div_out
);
    localparam CW = DIV_W + 8;            // enough for T up to 128*2^DIV_W

    localparam AB_IDLE = 3'd0, AB_HIGH = 3'd1, AB_FALL = 3'd2,
               AB_MEAS = 3'd3, AB_POST = 3'd4;

    reg [2:0]    state;
    reg          r1, r2, r3;              // sync + one more flop for edges
    reg [CW-1:0] cnt;
    reg [2:0]    nfall;

    wire fall = r3 & ~r2;
    wire [CW-1:0] t_total = cnt + 1'b1;
    wire [CW-1:0] rounded = (t_total + 64) >> 7;

    assign busy = (state != AB_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r1 <= 1'b1; r2 <= 1'b1; r3 <= 1'b1;
        end else begin
            r1 <= rx; r2 <= r1; r3 <= r2;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= AB_IDLE;
            locked     <= 1'b0;
            lock_pulse <= 1'b0;
            lock_err   <= 1'b0;
            div_out    <= {DIV_W{1'b0}};
            cnt        <= {CW{1'b0}};
            nfall      <= 3'd0;
        end else begin
            lock_pulse <= 1'b0;
            lock_err   <= 1'b0;
            case (state)
            AB_IDLE: if (start) begin
                locked <= 1'b0;
                state  <= AB_HIGH;
            end
            AB_HIGH: if (r2) state <= AB_FALL;      // line must be idle first
            AB_FALL: if (fall) begin
                cnt   <= {CW{1'b0}};
                nfall <= 3'd0;
                state <= AB_MEAS;
            end
            AB_MEAS: begin
                cnt <= cnt + 1'b1;
                if (&cnt) begin                       // way too slow
                    lock_err <= 1'b1;
                    state    <= AB_POST;
                end else if (fall) begin
                    nfall <= nfall + 1'b1;
                    if (nfall == 3'd3) begin          // this is the 5th fall overall
                        if (rounded == 0 || rounded[CW-1:DIV_W] != 0) begin
                            lock_err <= 1'b1;
                        end else begin
                            div_out    <= rounded[DIV_W-1:0];
                            locked     <= 1'b1;
                            lock_pulse <= 1'b1;
                        end
                        state <= AB_POST;
                    end
                end
            end
            AB_POST: if (r2) state <= AB_IDLE;      // wait for stop bit
            default: state <= AB_IDLE;
            endcase
        end
    end
endmodule
