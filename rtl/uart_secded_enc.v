// uart_secded.v
// Hamming(12,8) + one overall parity bit = SECDED(13,8).
// codeword index: cw[0] = overall parity, cw[1..12] = Hamming positions
// parity bits at positions 1,2,4,8, data d0..d7 at 3,5,6,7,9,10,11,12.
module uart_secded_enc (
    input  wire [7:0]  d,
    output wire [12:0] cw
);
    wire p1 = d[0] ^ d[1] ^ d[3] ^ d[4] ^ d[6];   // pos 3,5,7,9,11
    wire p2 = d[0] ^ d[2] ^ d[3] ^ d[5] ^ d[6];   // pos 3,6,7,10,11
    wire p4 = d[1] ^ d[2] ^ d[3] ^ d[7];          // pos 5,6,7,12
    wire p8 = d[4] ^ d[5] ^ d[6] ^ d[7];          // pos 9,10,11,12
    wire [12:1] h = {d[7], d[6], d[5], d[4], p8, d[3], d[2], d[1], p4, d[0], p2, p1};
    assign cw = {h, ^h};
endmodule

