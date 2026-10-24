// uart_ecc_rx.v - pairs two received frames back into a codeword and
// runs the SECDED decoder. If the second frame does not show up within
// ~32 bit times (or a frame error happens) we drop the half codeword.
module uart_ecc_rx #(
    parameter DIV_W = 16
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire [DIV_W-1:0] divisor,
    input  wire             f_valid,
    input  wire [7:0]       f_data,
    input  wire             f_err,       // frame error from the RX
    output reg  [7:0]       data,
    output reg              valid,
    output reg              corrected,
    output reg              uncorrectable,
    output reg              dropped      // half codeword thrown away
);
    reg              have_a;
    reg [7:0]        part_a;
    reg [DIV_W+9:0]  tmo;
    wire [DIV_W+9:0] tmo_max = {1'b0, divisor, 9'd0};    // 512*div clocks = 32 bits

    wire [12:0] cw = {f_data[4:0], part_a};
    wire [7:0]  dec_d;
    wire        dec_c, dec_u;

    uart_secded_dec u_dec (.cw(cw), .d(dec_d), .corrected(dec_c), .uncorrectable(dec_u));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            have_a <= 1'b0; part_a <= 8'd0; tmo <= 0;
            data <= 8'd0; valid <= 1'b0; corrected <= 1'b0;
            uncorrectable <= 1'b0; dropped <= 1'b0;
        end else begin
            valid <= 1'b0; corrected <= 1'b0; uncorrectable <= 1'b0; dropped <= 1'b0;
            if (f_err) begin
                dropped <= have_a;
                have_a  <= 1'b0;
            end else if (f_valid) begin
                if (!have_a) begin
                    part_a <= f_data;
                    have_a <= 1'b1;
                    tmo    <= 0;
                end else begin
                    have_a        <= 1'b0;
                    data          <= dec_d;
                    valid         <= 1'b1;
                    corrected     <= dec_c;
                    uncorrectable <= dec_u;
                end
            end else if (have_a) begin
                tmo <= tmo + 1'b1;
                if (tmo >= tmo_max) begin
                    have_a  <= 1'b0;
                    dropped <= 1'b1;
                end
            end
        end
    end
endmodule
