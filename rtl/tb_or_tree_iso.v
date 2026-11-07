// tb_or_tree_iso.v -- isolation testbench.
//
// tb_or_tree.v showed fanin (WIDTH=1) passing at N_IN=1000 both combinational
// and pipelined, while fanout (N_IN=1000, WIDTH=512, REG_EVERY=3) returned
// all-zeros for every vector including all-ones. That pattern says "the wide
// path does not propagate", not "the reduction is wrong", so sweep the three
// independent suspects separately:
//
//   wide + NO registers      -> is WIDTH>1 itself broken?
//   narrow-ish + registers   -> is REG_EVERY>0 broken once WIDTH>1?
//   small N_IN + wide + reg  -> does it depend on the total bus width?
//   the exact failing config -> reproduce, to confirm the harness agrees
`default_nettype none
`timescale 1ns/1ps

module tb_or_tree_iso;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg go = 1'b0;
    always #2.5 clk = ~clk;

    wire        d0, d1, d2, d3, d4;
    wire [31:0] e0, e1, e2, e3, e4;

    // wide, no registers: tests WIDTH>1 alone
    or_tree_check #(.N_IN(1000), .WIDTH(512), .REG_EVERY(0), .NRAND(2),
                    .NAME("A-1000x512-comb")) c0 (clk, rst_n, go, d0, e0);
    // modest width, registered: tests REG_EVERY>0 with WIDTH>1
    or_tree_check #(.N_IN(1000), .WIDTH(8),   .REG_EVERY(3), .NRAND(2),
                    .NAME("B-1000x8-reg3"))   c1 (clk, rst_n, go, d1, e1);
    // small N_IN, wide, registered: tests registers on wide nodes w/o a huge bus
    or_tree_check #(.N_IN(8),    .WIDTH(512), .REG_EVERY(3), .NRAND(2),
                    .NAME("C-8x512-reg3"))    c2 (clk, rst_n, go, d2, e2);
    // mid width, registered, full N_IN
    or_tree_check #(.N_IN(1000), .WIDTH(64),  .REG_EVERY(3), .NRAND(2),
                    .NAME("D-1000x64-reg3"))  c3 (clk, rst_n, go, d3, e3);
    // the exact failing config
    or_tree_check #(.N_IN(1000), .WIDTH(512), .REG_EVERY(3), .NRAND(2),
                    .NAME("E-1000x512-reg3")) c4 (clk, rst_n, go, d4, e4);

    integer total;
    initial begin
        $display("tb_or_tree_iso: starting");
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);
        go = 1'b1;
        wait (d0 && d1 && d2 && d3 && d4);
        repeat (4) @(posedge clk);
        total = e0 + e1 + e2 + e3 + e4;
        $display("tb_or_tree_iso: %0d total error(s)", total);
        if (total == 0) $display("TB_RESULT: PASS"); else $display("TB_RESULT: FAIL");
        $finish;
    end
    initial begin
        #20_000_000;
        $display("tb_or_tree_iso: TIMEOUT");
        $display("TB_RESULT: FAIL");
        $finish;
    end
endmodule
`default_nettype wire
