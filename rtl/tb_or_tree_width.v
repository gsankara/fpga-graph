// tb_or_tree_width.v -- does the failure track the REGISTERED STAGE width?
//
// Isolation showed 1000x512 passes combinationally and 1000x64 passes
// registered, but 1000x512 registered fails. The first registered level of
// REG_EVERY=3 holds ceil(1000/8)=125 nodes, so the stage is 125*WIDTH bits:
// 8,000 bits at WIDTH=64 (passes) vs 64,000 bits at WIDTH=512 (fails).
//
// Sweep two axes to tell a width limit from a logic error:
//   WIDTH at fixed REG_EVERY=3  -> 128 (16,000b), 256 (32,000b)
//   REG_EVERY at fixed WIDTH=512 -> 5 (first stage 32 nodes = 16,384b),
//                                   9 (first stage 2 nodes = 1,024b)
// If the deep-register variants of the SAME 1000x512 tree pass, the tree logic
// is right and the limit is the width of one registered stage.
`default_nettype none
`timescale 1ns/1ps

module tb_or_tree_width;
    reg clk = 1'b0, rst_n = 1'b0, go = 1'b0;
    always #2.5 clk = ~clk;

    wire        d0, d1, d2, d3, d4;
    wire [31:0] e0, e1, e2, e3, e4;

    or_tree_check #(.N_IN(1000), .WIDTH(128), .REG_EVERY(3), .NRAND(2),
                    .NAME("W128-reg3-stage16000b")) c0 (clk, rst_n, go, d0, e0);
    or_tree_check #(.N_IN(1000), .WIDTH(256), .REG_EVERY(3), .NRAND(2),
                    .NAME("W256-reg3-stage32000b")) c1 (clk, rst_n, go, d1, e1);
    or_tree_check #(.N_IN(1000), .WIDTH(512), .REG_EVERY(5), .NRAND(2),
                    .NAME("W512-reg5-stage16384b")) c2 (clk, rst_n, go, d2, e2);
    or_tree_check #(.N_IN(1000), .WIDTH(512), .REG_EVERY(9), .NRAND(2),
                    .NAME("W512-reg9-stage1024b"))  c3 (clk, rst_n, go, d3, e3);
    or_tree_check #(.N_IN(500),  .WIDTH(512), .REG_EVERY(3), .NRAND(2),
                    .NAME("N500-W512-reg3-32000b")) c4 (clk, rst_n, go, d4, e4);

    integer total;
    initial begin
        $display("tb_or_tree_width: starting");
        repeat (4) @(posedge clk); rst_n = 1'b1;
        repeat (4) @(posedge clk); go = 1'b1;
        wait (d0 && d1 && d2 && d3 && d4);
        repeat (4) @(posedge clk);
        total = e0 + e1 + e2 + e3 + e4;
        $display("tb_or_tree_width: %0d total error(s)", total);
        if (total == 0) $display("TB_RESULT: PASS"); else $display("TB_RESULT: FAIL");
        $finish;
    end
    initial begin
        #40_000_000;
        $display("tb_or_tree_width: TIMEOUT"); $display("TB_RESULT: FAIL"); $finish;
    end
endmodule
`default_nettype wire
