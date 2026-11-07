// tb_or_tree.v -- xsim testbench for or_tree.v
//
// Run on a Coder FPGA dev box (compile0/compile3), which has xsim:
//   xvlog rtl/or_tree.v rtl/tb_or_tree.v
//   xelab -debug typical tb_or_tree -s tb_or_tree_sim
//   xsim tb_or_tree_sim -runall
//
// What is actually being checked, and why each case is here:
//
//   1000 x 1b, comb      the headline ask -- 1000-entry OR to 1 entry
//   1000 x 1b, REG=2     same tree pipelined; proves registering a level does
//                        not change the VALUE, only the timing
//   1000 x 512b, REG=3   the fan-out / union-of-neighbours use: 1000 masks of
//                        512 bits each reduced to one mask
//     7 x 4b,  comb      NOT a power of two, so the odd-node carry path is
//                        exercised at several levels (7 -> 4 -> 2 -> 1)
//     3 x 1b,  comb      smallest odd case
//     1 x 8b,  comb      degenerate: LEVELS = 0, output must be the input
//
// Strategy: drive a vector, hold it stable for HOLD cycles, then check. HOLD is
// comfortably more than the deepest pipeline here (ceil(log2(1000)) = 10
// levels, so LATENCY <= 10), which means the checker never needs to know
// LATENCY or model the pipeline -- a stable input makes a stable output
// whatever the depth. That keeps the test independent of the parameter it is
// meant to be verifying.
`default_nettype none
`timescale 1ns/1ps

// ---------------------------------------------------------------- one config
module or_tree_check #(
    parameter integer N_IN      = 8,
    parameter integer WIDTH     = 1,
    parameter integer REG_EVERY = 0,
    parameter integer NRAND     = 8,
    parameter         NAME      = "cfg"
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        go,
    output reg         done,
    output reg [31:0]  errors
);
    localparam integer HOLD = 24;

    reg  [N_IN*WIDTH-1:0] din;
    reg                   in_valid;
    wire [WIDTH-1:0]      dout;
    wire                  out_valid;

    or_tree #(
        .N_IN(N_IN), .WIDTH(WIDTH), .REG_EVERY(REG_EVERY)
    ) dut (
        .clk(clk), .rst_n(rst_n), .in_valid(in_valid),
        .din(din), .dout(dout), .out_valid(out_valid)
    );

    // Behavioural reference: OR every entry together.
    function [WIDTH-1:0] expect_of;
        input [N_IN*WIDTH-1:0] v;
        integer k;
        reg [WIDTH-1:0] acc;
        begin
            acc = {WIDTH{1'b0}};
            for (k = 0; k < N_IN; k = k + 1)
                acc = acc | v[k*WIDTH +: WIDTH];
            expect_of = acc;
        end
    endfunction

    integer h;
    task apply_and_check;
        input [N_IN*WIDTH-1:0] v;
        input [255:0]          label;
        reg   [WIDTH-1:0]      exp;
        begin
            din      = v;
            in_valid = 1'b1;
            exp      = expect_of(v);
            for (h = 0; h < HOLD; h = h + 1) @(posedge clk);
            if (dout !== exp) begin
                errors = errors + 1;
                $display("  FAIL %0s / %0s: dout=%h expected=%h", NAME, label, dout, exp);
            end
            if (out_valid !== 1'b1) begin
                errors = errors + 1;
                $display("  FAIL %0s / %0s: out_valid low with in_valid held high", NAME, label);
            end
        end
    endtask

    // in_valid must fall LATENCY cycles before out_valid does; checking that it
    // eventually falls catches a valid chain that is stuck high (e.g. a
    // mis-sized shift register), which a value-only test would miss entirely.
    task check_valid_drops;
        begin
            in_valid = 1'b0;
            for (h = 0; h < HOLD; h = h + 1) @(posedge clk);
            if (out_valid !== 1'b0) begin
                errors = errors + 1;
                $display("  FAIL %0s: out_valid stuck high after in_valid dropped", NAME);
            end
            in_valid = 1'b1;
        end
    endtask

    integer vi, ei, wi;
    reg [N_IN*WIDTH-1:0] vec;
    initial begin
        done     = 1'b0;
        errors   = 32'd0;
        din      = {(N_IN*WIDTH){1'b0}};
        in_valid = 1'b0;
        wait (go === 1'b1);
        @(posedge clk);

        // all zeros
        apply_and_check({(N_IN*WIDTH){1'b0}}, "zeros");

        // all ones
        apply_and_check({(N_IN*WIDTH){1'b1}}, "ones");

        // exactly one entry set, at first / last / middle -- these are the
        // cases that catch a tree that drops a leaf, which an all-ones vector
        // cannot detect because every path carries a 1.
        vec = {(N_IN*WIDTH){1'b0}};
        vec[0 +: WIDTH] = {WIDTH{1'b1}};
        apply_and_check(vec, "only-first");

        vec = {(N_IN*WIDTH){1'b0}};
        vec[(N_IN-1)*WIDTH +: WIDTH] = {WIDTH{1'b1}};
        apply_and_check(vec, "only-last");

        if (N_IN > 2) begin
            vec = {(N_IN*WIDTH){1'b0}};
            vec[(N_IN/2)*WIDTH +: WIDTH] = {WIDTH{1'b1}};
            apply_and_check(vec, "only-middle");
        end

        // walk a single set bit through EVERY leaf: the strongest check that no
        // leaf is lost or duplicated. Only for small N_IN, else simulation time
        // explodes.
        if (N_IN <= 64) begin
            for (ei = 0; ei < N_IN; ei = ei + 1) begin
                vec = {(N_IN*WIDTH){1'b0}};
                vec[ei*WIDTH] = 1'b1;
                apply_and_check(vec, "walk-one");
            end
        end

        // random vectors
        for (vi = 0; vi < NRAND; vi = vi + 1) begin
            for (wi = 0; wi < N_IN*WIDTH; wi = wi + 32)
                vec[wi +: 32] = $random;
            apply_and_check(vec, "random");
        end

        check_valid_drops();

        if (errors == 0) $display("  PASS %0s (N_IN=%0d WIDTH=%0d REG_EVERY=%0d)",
                                  NAME, N_IN, WIDTH, REG_EVERY);
        else             $display("  ---- %0s had %0d error(s)", NAME, errors);
        done = 1'b1;
    end
endmodule

// --------------------------------------------------------------------- top
module tb_or_tree;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg go = 1'b0;

    always #2.5 clk = ~clk;      // 200 MHz, arbitrary -- no timing claim here

    wire        d0, d1, d2, d3, d4, d5;
    wire [31:0] e0, e1, e2, e3, e4, e5;

    or_tree_check #(.N_IN(1000), .WIDTH(1),   .REG_EVERY(0), .NRAND(16),
                    .NAME("fanin-1000x1-comb"))   c0 (clk, rst_n, go, d0, e0);
    or_tree_check #(.N_IN(1000), .WIDTH(1),   .REG_EVERY(2), .NRAND(16),
                    .NAME("fanin-1000x1-reg2"))   c1 (clk, rst_n, go, d1, e1);
    or_tree_check #(.N_IN(1000), .WIDTH(512), .REG_EVERY(3), .NRAND(3),
                    .NAME("fanout-1000x512-reg3"))c2 (clk, rst_n, go, d2, e2);
    or_tree_check #(.N_IN(7),    .WIDTH(4),   .REG_EVERY(0), .NRAND(8),
                    .NAME("odd-7x4-comb"))        c3 (clk, rst_n, go, d3, e3);
    or_tree_check #(.N_IN(3),    .WIDTH(1),   .REG_EVERY(0), .NRAND(8),
                    .NAME("odd-3x1-comb"))        c4 (clk, rst_n, go, d4, e4);
    or_tree_check #(.N_IN(1),    .WIDTH(8),   .REG_EVERY(0), .NRAND(4),
                    .NAME("degenerate-1x8"))      c5 (clk, rst_n, go, d5, e5);

    integer total;
    initial begin
        $display("tb_or_tree: starting");
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);
        go = 1'b1;

        wait (d0 && d1 && d2 && d3 && d4 && d5);
        repeat (4) @(posedge clk);

        total = e0 + e1 + e2 + e3 + e4 + e5;
        $display("tb_or_tree: %0d total error(s)", total);
        if (total == 0) $display("TB_RESULT: PASS");
        else            $display("TB_RESULT: FAIL");
        $finish;
    end

    // Never let a hung wait look like a pass.
    initial begin
        #20_000_000;
        $display("tb_or_tree: TIMEOUT");
        $display("TB_RESULT: FAIL");
        $finish;
    end
endmodule

`default_nettype wire
