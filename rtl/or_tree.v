// or_tree.v -- parameterized balanced binary OR-reduction tree.
//
// Collaborator ask 2: "use RTL for 1000 entry OR to 1 entry using binary tree
// of OR gates. only have input and output in hls, move rest as parameters into
// HLS/RTL code."
//
// Why this exists
// ---------------
// The generated HLS kernel emits each vertex's fan-in as ONE FLAT expression:
//
//     res[0] = do_hop ? (s[0] | s[1] | s[49]) : s[0];
//
// and leaves the tree shape to Vivado. At N=50 that is three terms; at N=1000 a
// high-fan-in vertex is a single basic block with up to 1000 terms. That flat
// block is what makes csynth time out -- 9 min -> 86 min -> timeout across two
// 2x size steps, at only ~6% LUT -- which caps the design at ~20,000 OR terms
// (CAPACITY.md), which is what keeps it below its own break-even point against
// one CPU core (RESULTS_CPU_BASELINE.md).
//
// Replacing that flat block with an explicit balanced tree turns an
// uncontrolled combinational depth into a PARAMETER. Depth is ceil(log2(N_IN))
// levels regardless of how the source is written, and REG_EVERY decides how
// much of it is registered, so depth trades against latency explicitly instead
// of at the synthesiser's discretion.
//
// Both reductions in the design, one module
// ----------------------------------------
// Per the clarification, this serves the fan-in AND the fan-out:
//
//   * FAN-IN, per target vertex:  WIDTH=1, N_IN=fan-in of that vertex.
//     Reduces up to 1000 one-bit neighbour states to the vertex's next state.
//
//   * FAN-OUT / union of neighbours:  WIDTH=N (or 512), N_IN=number of
//     contributing vertices. Reduces that many WIDTH-bit neighbour MASKS to one
//     mask. Identical tree, wider nodes -- a bitwise OR is bit-independent, so
//     one module covers both and there is no second thing to verify.
//
// Interface notes
// ---------------
// `din` is the flattened input bus: entry i occupies din[i*WIDTH +: WIDTH].
// Flattened rather than a 2D port so the module instantiates cleanly from
// Verilog-2001, from a Vitis RTL kernel wrapper, and from an HLS blackbox,
// without the port shape changing per flow.
//
// REG_EVERY = 0 makes the tree purely combinational and `out_valid` is just
// `in_valid`. REG_EVERY = k registers the output of every k-th level, giving
// LATENCY registered stages; `out_valid` is `in_valid` delayed by exactly that,
// so a consumer never needs to know the parameter values. LATENCY is exposed as
// a localparam for the testbench and for generators to read.
//
// Verilog-2001 on purpose: arrays of nets and constant functions only, no
// SystemVerilog, so Vivado/xsim accept the file as plain .v with no per-file
// language override.
`default_nettype none
// xsim refuses to elaborate a design where some modules declare a timescale and
// others do not ("doesn't have a timescale but at least one module in design
// has a timescale"), so declare one here too. Synthesis ignores it; it only
// affects simulation time units.
`timescale 1ns/1ps

module or_tree #(
    parameter integer N_IN      = 1000,  // number of entries to reduce
    parameter integer WIDTH     = 1,     // bits per entry (1 = fan-in, N = fan-out mask)
    parameter integer REG_EVERY = 0      // 0 = combinational; k = register every k levels
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  in_valid,
    input  wire [N_IN*WIDTH-1:0] din,
    output wire [WIDTH-1:0]      dout,
    output wire                  out_valid
);

    // ---------------------------------------------------------------- helpers
    // $clog2 is Verilog-2005; spell it out so this file needs no dialect flag.
    function integer clog2_f;
        input integer value;
        integer v;
        integer r;
        begin
            v = value - 1;
            r = 0;
            while (v > 0) begin
                v = v >> 1;
                r = r + 1;
            end
            clog2_f = r;
        end
    endfunction

    function integer cdiv2;
        input integer a;
        begin
            cdiv2 = (a + 1) / 2;
        end
    endfunction

    // Nodes alive at a given level: level 0 is the leaves, halving (rounded up)
    // each level. An odd node at a level is carried up unchanged.
    function integer cnt_at;
        input integer lvl;
        integer i;
        integer c;
        begin
            c = N_IN;
            for (i = 0; i < lvl; i = i + 1) c = cdiv2(c);
            cnt_at = c;
        end
    endfunction

    // Is the output of level `lvl` (1..LEVELS) registered?
    function integer is_reg_level;
        input integer lvl;
        begin
            if (REG_EVERY <= 0) is_reg_level = 0;
            else if ((lvl % REG_EVERY) == 0) is_reg_level = 1;
            else is_reg_level = 0;
        end
    endfunction

    function integer count_reg_levels;
        input integer levels;
        integer i;
        integer c;
        begin
            c = 0;
            for (i = 1; i <= levels; i = i + 1) c = c + is_reg_level(i);
            count_reg_levels = c;
        end
    endfunction

    localparam integer LEVELS  = (N_IN <= 1) ? 0 : clog2_f(N_IN);
    localparam integer LATENCY = count_reg_levels(LEVELS);

    // ------------------------------------------------------------------- tree
    // Every level is held in a full-width bus for uniformity; only the low
    // cnt_at(L)*WIDTH bits of level L are meaningful, and synthesis drops the
    // rest because nothing reads it.
    localparam integer BUSW = (N_IN < 1) ? WIDTH : N_IN*WIDTH;

    wire [BUSW-1:0] lvl      [0:LEVELS];   // value entering level L
    wire [BUSW-1:0] lvl_comb [0:LEVELS];   // combinational result of level L

    assign lvl[0] = din;

    genvar L, i, j;
    generate
        for (L = 0; L < LEVELS; L = L + 1) begin : g_level
            localparam integer NCUR  = cnt_at(L);
            localparam integer NNEXT = cnt_at(L+1);

            // Pair up: node i of the next level is nodes 2i and 2i+1 of this
            // one. When NCUR is odd the last node has no partner and passes
            // through -- OR with a constant 0 would be the same thing, but
            // passing through keeps the LUT count honest in reports.
            for (i = 0; i < NNEXT; i = i + 1) begin : g_node
                if ((2*i + 1) < NCUR) begin : g_pair
                    assign lvl_comb[L+1][i*WIDTH +: WIDTH] =
                           lvl[L][(2*i)*WIDTH   +: WIDTH] |
                           lvl[L][(2*i+1)*WIDTH +: WIDTH];
                end else begin : g_carry
                    assign lvl_comb[L+1][i*WIDTH +: WIDTH] =
                           lvl[L][(2*i)*WIDTH +: WIDTH];
                end
            end

            // Unused high bits of this level: tie off so the net is driven and
            // simulation does not propagate X into a comparison.
            if (NNEXT*WIDTH < BUSW) begin : g_tie
                assign lvl_comb[L+1][BUSW-1 : NNEXT*WIDTH] = {(BUSW - NNEXT*WIDTH){1'b0}};
            end

            // Register this level's output, or pass it straight on.
            //
            // One register PER NODE, deliberately -- not one monolithic
            // `reg [NNEXT*WIDTH-1:0]` for the whole level. The monolithic form
            // is what a first draft writes and it is functionally identical,
            // but it silently breaks above a 2^14-bit vector: measured
            // 2026-11-07 with xsim 2023.2, a level registered as one vector
            // gives the right answer at 16,000 bits and all-zeros at 16,384,
            // with no error -- only a wrong result. The sweep that found it:
            //
            //   N_IN=1000 WIDTH=128 REG_EVERY=3  stage 16,000 b  PASS
            //   N_IN=1000 WIDTH=512 REG_EVERY=5  stage 16,384 b  FAIL
            //   N_IN=1000 WIDTH=256 REG_EVERY=3  stage 32,000 b  FAIL
            //   N_IN=1000 WIDTH=512 REG_EVERY=9  stage  1,024 b  PASS
            //
            // Per-node registers cap every vector at WIDTH bits, so the limit
            // cannot be reached however N_IN and REG_EVERY are set. Synthesis
            // sees the same flip-flops either way.
            if (is_reg_level(L+1) != 0) begin : g_reg
                for (j = 0; j < NNEXT; j = j + 1) begin : g_node_reg
                    reg [WIDTH-1:0] stage;
                    always @(posedge clk) begin
                        if (!rst_n) stage <= {WIDTH{1'b0}};
                        else        stage <= lvl_comb[L+1][j*WIDTH +: WIDTH];
                    end
                    assign lvl[L+1][j*WIDTH +: WIDTH] = stage;
                end
                if (NNEXT*WIDTH < BUSW) begin : g_tie2
                    assign lvl[L+1][BUSW-1 : NNEXT*WIDTH] = {(BUSW - NNEXT*WIDTH){1'b0}};
                end
            end else begin : g_comb
                assign lvl[L+1] = lvl_comb[L+1];
            end
        end
    endgenerate

    assign dout = lvl[LEVELS][WIDTH-1:0];

    // ------------------------------------------------------------ valid chain
    // Delayed by exactly LATENCY so the consumer does not need to recompute it
    // from the parameters.
    generate
        if (LATENCY == 0) begin : g_v_comb
            assign out_valid = in_valid;
        end else if (LATENCY == 1) begin : g_v_one
            // LATENCY==1 must be its own case: {vsr[LATENCY-2:0], in_valid}
            // degenerates to vsr[-1:0], which xelab flags as
            // "select index -1 ... is out of bounds" and whose behaviour is not
            // something to rely on.
            reg v1;
            always @(posedge clk) begin
                if (!rst_n) v1 <= 1'b0;
                else        v1 <= in_valid;
            end
            assign out_valid = v1;
        end else begin : g_v_pipe
            reg [LATENCY-1:0] vsr;
            always @(posedge clk) begin
                if (!rst_n) vsr <= {LATENCY{1'b0}};
                else        vsr <= {vsr[LATENCY-2:0], in_valid};
            end
            assign out_valid = vsr[LATENCY-1];
        end
    endgenerate

endmodule

`default_nettype wire
