// uart_secded_dec.v - SECDED(13,8) decoder, see uart_secded_enc.v for the bit map
module uart_secded_dec (
    input  wire [12:0] cw,
    output wire [7:0]  d,
    output wire        corrected,     // single error fixed
    output wire        uncorrectable  // double error (or bad syndrome)
);
    wire [12:1] h = cw[12:1];
    wire s1 = h[1] ^ h[3] ^ h[5] ^ h[7] ^ h[9]  ^ h[11];
    wire s2 = h[2] ^ h[3] ^ h[6] ^ h[7] ^ h[10] ^ h[11];
    wire s4 = h[4] ^ h[5] ^ h[6] ^ h[7] ^ h[12];
    wire s8 = h[8] ^ h[9] ^ h[10] ^ h[11] ^ h[12];
    wire [3:0] syn = {s8, s4, s2, s1};
    wire       ovp = ^cw;               // 0 when overall parity is fine

    // one-hot flip mask for a single error
    reg [12:1] fix;
    integer i;
    always @(*) begin
        fix = 12'd0;
        for (i = 1; i <= 12; i = i + 1)
            if (ovp && {28'd0, syn} == i) fix[i] = 1'b1;
    end
    wire [12:1] hc = h ^ fix;

    assign d = {hc[12], hc[11], hc[10], hc[9], hc[7], hc[6], hc[5], hc[3]};
    // ovp=1 & syn=0 -> the overall parity bit itself flipped (data fine)
    assign corrected     = ovp && (syn <= 4'd12);
    assign uncorrectable = (!ovp && syn != 4'd0) || (ovp && syn > 4'd12);
endmodule
