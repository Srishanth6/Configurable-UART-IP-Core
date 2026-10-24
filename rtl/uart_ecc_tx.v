// uart_ecc_tx.v - byte -> 13-bit codeword -> two UART frames
// frame A = cw[7:0], frame B = {3'b000, cw[12:8]}
module uart_ecc_tx (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,
    input  wire [7:0] data,
    output wire       busy,
    output reg        done,
    // to the frame transmitter
    output reg        f_start,
    output reg  [7:0] f_data,
    input  wire       f_busy,
    input  wire       f_done
);
    localparam E_IDLE = 2'd0, E_A = 2'd1, E_B = 2'd2;
    reg [1:0]  state;
    reg [4:0]  hi_part;
    wire [12:0] cw;

    uart_secded_enc u_enc (.d(data), .cw(cw));

    assign busy = (state != E_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= E_IDLE;
            done    <= 1'b0;
            f_start <= 1'b0;
            f_data  <= 8'd0;
            hi_part <= 5'd0;
        end else begin
            done    <= 1'b0;
            f_start <= 1'b0;
            case (state)
            E_IDLE: if (start) begin
                f_data  <= cw[7:0];
                hi_part <= cw[12:8];
                f_start <= 1'b1;
                state   <= E_A;
            end
            E_A: if (f_done) begin
                f_data  <= {3'b000, hi_part};
                f_start <= 1'b1;
                state   <= E_B;
            end
            E_B: if (f_done) begin
                done  <= 1'b1;
                state <= E_IDLE;
            end
            default: state <= E_IDLE;
            endcase
        end
    end
endmodule
