// uart_baud_gen.v
// Makes the 16x oversampling tick. divisor = CLK_FREQ / (BAUD * 16).
// divisor is a run-time input, so the baud rate can be changed without
// re-synthesising. clr restarts the count (TX uses it so every frame
// starts on a clean bit boundary). en=0 freezes the counter, which is
// how the low-power mode stops the oversampling logic when idle.
module uart_baud_gen #(
    parameter DIV_W = 16              // width of the divisor register
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             clr,
    input  wire             en,
    input  wire [DIV_W-1:0] divisor,   // must be >= 1
    output wire             tick
);
    reg [DIV_W-1:0] cnt;

    // tick is high for one clock every 'divisor' clocks
`ifdef INJECT_BUG_BAUD
    // deliberate bug for the negative assertion test: off-by-one divisor
    assign tick = en && (cnt == divisor);
`else
    assign tick = en && (cnt == divisor - 1'b1);
`endif

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            cnt <= {DIV_W{1'b0}};
        else if (clr || tick)
            cnt <= {DIV_W{1'b0}};
        else if (en)
            cnt <= cnt + 1'b1;
    end
endmodule
