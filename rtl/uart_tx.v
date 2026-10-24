// uart_tx.v
// Frame: start(0) | d0..d7 (LSB first) | [parity] | stop(1)
// parity_mode: 00 = none, 01 = even, 10 = odd (11 treated as none)
// Each bit lasts 16 ticks of the oversampling clock.
module uart_tx #(
    parameter PARITY_SUPPORT = 1      // 0 -> parity hardware removed
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       tick,
    input  wire       tx_start,
    input  wire [7:0] tx_data,
    input  wire [1:0] parity_mode,
    output reg        tx,
    output wire       tx_busy,
    output reg        tx_done,      // 1-clock pulse at end of stop bit
    output wire       start_accept  // high in the cycle a new byte is taken
);
    localparam ST_IDLE  = 3'd0,
               ST_START = 3'd1,
               ST_DATA  = 3'd2,
               ST_PAR   = 3'd3,
               ST_STOP  = 3'd4;

    reg [2:0] state;
    reg [3:0] tcnt;      // counts 16 ticks per bit
    reg [2:0] bit_no;
    reg [7:0] shreg;
    reg       par_en;
    reg       par_bit;

    wire [1:0] pmode   = (PARITY_SUPPORT != 0) ? parity_mode : 2'b00;
    wire       bit_end = tick && (tcnt == 4'd15);

    assign tx_busy      = (state != ST_IDLE);
    assign start_accept = tx_start && (state == ST_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= ST_IDLE;
            tx      <= 1'b1;
            tx_done <= 1'b0;
            tcnt    <= 4'd0;
            bit_no  <= 3'd0;
            shreg   <= 8'd0;
            par_en  <= 1'b0;
            par_bit <= 1'b0;
        end else begin
            tx_done <= 1'b0;
            if (tick && state != ST_IDLE)
                tcnt <= tcnt + 1'b1;   // wraps 15 -> 0 by itself

            case (state)
            ST_IDLE: begin
                tx <= 1'b1;
                if (tx_start) begin
                    shreg   <= tx_data;
                    par_en  <= (pmode == 2'b01) || (pmode == 2'b10);
                    par_bit <= (pmode == 2'b10) ? ~(^tx_data) : (^tx_data);
                    tcnt    <= 4'd0;
                    tx      <= 1'b0;          // start bit
                    state   <= ST_START;
                end
            end
            ST_START: if (bit_end) begin
                bit_no <= 3'd0;
                tx     <= shreg[0];
                state  <= ST_DATA;
            end
            ST_DATA: if (bit_end) begin
                if (bit_no == 3'd7) begin
                    if (par_en) begin
                        tx    <= par_bit;
                        state <= ST_PAR;
                    end else begin
                        tx    <= 1'b1;
                        state <= ST_STOP;
                    end
                end else begin
                    bit_no <= bit_no + 1'b1;
                    tx     <= shreg[bit_no + 1'b1];
                end
            end
            ST_PAR: if (bit_end) begin
                tx    <= 1'b1;
                state <= ST_STOP;
            end
`ifdef INJECT_BUG_TX
            // deliberate bug for the negative test: stop bit one tick short
            ST_STOP: if (tick && tcnt == 4'd14) begin
`else
            ST_STOP: if (bit_end) begin
`endif
                tx      <= 1'b1;
                tx_done <= 1'b1;
                state   <= ST_IDLE;
            end
            default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
