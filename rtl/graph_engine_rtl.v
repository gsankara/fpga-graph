// graph_engine_rtl.v -- Vitis RTL kernel wrapping graph_or.v.
//
// Ask 2, the half that was never built: "only have input and output in hls,
// move rest as parameters into HLS/RTL code." RESULTS_ASK2_OR_TREE.md shipped
// the tree (rtl/or_tree.v) and the per-vertex wiring (gen_rtl_or.py ->
// graph_or.v), both verified in xsim, and stopped at "the remaining path is an
// RTL-kernel wrapper exposing only the AXI in/out". This is that wrapper.
//
// It presents the SAME kernel name and the SAME five arguments as the
// generated HLS kernel, so host/part_query.cpp, host/part_agent.cpp and
// sim/compare_part.py all drive it unchanged and the existing
// scripts/u280.cfg pins its three masters by name. Swapping this xclbin in
// for an HLS one is then a pure substitution: any difference measured is the
// reduction, not the harness.
//
//   graph_engine_part(const gw_word_t *state_in,   // nq*NW words, full state
//                     gw_word_t       *part_out,   // nq*NW words, result
//                     unsigned        *count_out,  // nq popcounts
//                     unsigned         nq,
//                     unsigned         num_steps)  // 0 = pass through
//
// WHAT THIS IS NOT: a performance design. Phases are strictly sequential --
// read a chunk, compute it, write it, write its counts -- with one outstanding
// burst at a time. That is ~4 passes over a chunk where a streaming design
// would overlap them. It is written this way because the first question is
// whether the RTL reduction is CORRECT in silicon on the same 11,032-query
// sweep every other arm runs; a kernel whose inner loop is 4x off the ideal is
// still conclusive about that, and the project's own measurements say the hop
// is dominated by ~97 us of fixed XRT per-call cost anyway
// (RESULTS_LATENCY_SPLIT.md section 11.2). Do not quote a latency from this
// build without saying it is the non-overlapped wrapper.
//
// Verilog-2001 on purpose, matching or_tree.v: xsim and Vivado both take it as
// plain .v with no language override.
`default_nettype none
`timescale 1ns/1ps

module graph_engine_part #(
    parameter integer N                = 50,   // graph vertices = state width
    parameter integer WORD_BITS        = 512,  // AXI data width for the state
    parameter integer NW               = 1,    // 512-bit words per state vector
    parameter integer CHUNK            = 64,   // queries per burst, <= 256
    parameter integer REG_EVERY        = 2,    // or_tree registering, see or_tree.v
    parameter integer GRAPH_OR_LATENCY = 2,    // cycles from in_valid to out_valid
    parameter integer C_ADDR_WIDTH     = 64,
    parameter integer C_CTRL_ADDR_W    = 12
) (
    input  wire                      ap_clk,
    input  wire                      ap_rst_n,

    // ---- AXI4-Lite control slave -----------------------------------------
    input  wire                      s_axi_control_AWVALID,
    output wire                      s_axi_control_AWREADY,
    input  wire [C_CTRL_ADDR_W-1:0]  s_axi_control_AWADDR,
    input  wire                      s_axi_control_WVALID,
    output wire                      s_axi_control_WREADY,
    input  wire [31:0]               s_axi_control_WDATA,
    input  wire [3:0]                s_axi_control_WSTRB,
    output wire                      s_axi_control_BVALID,
    input  wire                      s_axi_control_BREADY,
    output wire [1:0]                s_axi_control_BRESP,
    input  wire                      s_axi_control_ARVALID,
    output wire                      s_axi_control_ARREADY,
    input  wire [C_CTRL_ADDR_W-1:0]  s_axi_control_ARADDR,
    output wire                      s_axi_control_RVALID,
    input  wire                      s_axi_control_RREADY,
    output wire [31:0]               s_axi_control_RDATA,
    output wire [1:0]                s_axi_control_RRESP,
    output wire                      interrupt,

    // ---- gmem0: state_in, read ------------------------------------------
    output wire                      m_axi_gmem0_AWVALID,
    input  wire                      m_axi_gmem0_AWREADY,
    output wire [C_ADDR_WIDTH-1:0]   m_axi_gmem0_AWADDR,
    output wire [0:0]                m_axi_gmem0_AWID,
    output wire [7:0]                m_axi_gmem0_AWLEN,
    output wire [2:0]                m_axi_gmem0_AWSIZE,
    output wire [1:0]                m_axi_gmem0_AWBURST,
    output wire [1:0]                m_axi_gmem0_AWLOCK,
    output wire [3:0]                m_axi_gmem0_AWCACHE,
    output wire [2:0]                m_axi_gmem0_AWPROT,
    output wire [3:0]                m_axi_gmem0_AWQOS,
    output wire                      m_axi_gmem0_WVALID,
    input  wire                      m_axi_gmem0_WREADY,
    output wire [WORD_BITS-1:0]      m_axi_gmem0_WDATA,
    output wire [WORD_BITS/8-1:0]    m_axi_gmem0_WSTRB,
    output wire                      m_axi_gmem0_WLAST,
    input  wire                      m_axi_gmem0_BVALID,
    output wire                      m_axi_gmem0_BREADY,
    input  wire [1:0]                m_axi_gmem0_BRESP,
    output wire                      m_axi_gmem0_ARVALID,
    input  wire                      m_axi_gmem0_ARREADY,
    output wire [C_ADDR_WIDTH-1:0]   m_axi_gmem0_ARADDR,
    output wire [0:0]                m_axi_gmem0_ARID,
    output wire [7:0]                m_axi_gmem0_ARLEN,
    output wire [2:0]                m_axi_gmem0_ARSIZE,
    output wire [1:0]                m_axi_gmem0_ARBURST,
    output wire [1:0]                m_axi_gmem0_ARLOCK,
    output wire [3:0]                m_axi_gmem0_ARCACHE,
    output wire [2:0]                m_axi_gmem0_ARPROT,
    output wire [3:0]                m_axi_gmem0_ARQOS,
    input  wire                      m_axi_gmem0_RVALID,
    output wire                      m_axi_gmem0_RREADY,
    input  wire [WORD_BITS-1:0]      m_axi_gmem0_RDATA,
    input  wire                      m_axi_gmem0_RLAST,
    input  wire [1:0]                m_axi_gmem0_RRESP,

    // ---- gmem1: part_out, write -----------------------------------------
    output wire                      m_axi_gmem1_AWVALID,
    input  wire                      m_axi_gmem1_AWREADY,
    output wire [C_ADDR_WIDTH-1:0]   m_axi_gmem1_AWADDR,
    output wire [0:0]                m_axi_gmem1_AWID,
    output wire [7:0]                m_axi_gmem1_AWLEN,
    output wire [2:0]                m_axi_gmem1_AWSIZE,
    output wire [1:0]                m_axi_gmem1_AWBURST,
    output wire [1:0]                m_axi_gmem1_AWLOCK,
    output wire [3:0]                m_axi_gmem1_AWCACHE,
    output wire [2:0]                m_axi_gmem1_AWPROT,
    output wire [3:0]                m_axi_gmem1_AWQOS,
    output wire                      m_axi_gmem1_WVALID,
    input  wire                      m_axi_gmem1_WREADY,
    output wire [WORD_BITS-1:0]      m_axi_gmem1_WDATA,
    output wire [WORD_BITS/8-1:0]    m_axi_gmem1_WSTRB,
    output wire                      m_axi_gmem1_WLAST,
    input  wire                      m_axi_gmem1_BVALID,
    output wire                      m_axi_gmem1_BREADY,
    input  wire [1:0]                m_axi_gmem1_BRESP,
    output wire                      m_axi_gmem1_ARVALID,
    input  wire                      m_axi_gmem1_ARREADY,
    output wire [C_ADDR_WIDTH-1:0]   m_axi_gmem1_ARADDR,
    output wire [0:0]                m_axi_gmem1_ARID,
    output wire [7:0]                m_axi_gmem1_ARLEN,
    output wire [2:0]                m_axi_gmem1_ARSIZE,
    output wire [1:0]                m_axi_gmem1_ARBURST,
    output wire [1:0]                m_axi_gmem1_ARLOCK,
    output wire [3:0]                m_axi_gmem1_ARCACHE,
    output wire [2:0]                m_axi_gmem1_ARPROT,
    output wire [3:0]                m_axi_gmem1_ARQOS,
    input  wire                      m_axi_gmem1_RVALID,
    output wire                      m_axi_gmem1_RREADY,
    input  wire [WORD_BITS-1:0]      m_axi_gmem1_RDATA,
    input  wire                      m_axi_gmem1_RLAST,
    input  wire [1:0]                m_axi_gmem1_RRESP,

    // ---- gmem2: count_out, write, 32-bit --------------------------------
    output wire                      m_axi_gmem2_AWVALID,
    input  wire                      m_axi_gmem2_AWREADY,
    output wire [C_ADDR_WIDTH-1:0]   m_axi_gmem2_AWADDR,
    output wire [0:0]                m_axi_gmem2_AWID,
    output wire [7:0]                m_axi_gmem2_AWLEN,
    output wire [2:0]                m_axi_gmem2_AWSIZE,
    output wire [1:0]                m_axi_gmem2_AWBURST,
    output wire [1:0]                m_axi_gmem2_AWLOCK,
    output wire [3:0]                m_axi_gmem2_AWCACHE,
    output wire [2:0]                m_axi_gmem2_AWPROT,
    output wire [3:0]                m_axi_gmem2_AWQOS,
    output wire                      m_axi_gmem2_WVALID,
    input  wire                      m_axi_gmem2_WREADY,
    output wire [31:0]               m_axi_gmem2_WDATA,
    output wire [3:0]                m_axi_gmem2_WSTRB,
    output wire                      m_axi_gmem2_WLAST,
    input  wire                      m_axi_gmem2_BVALID,
    output wire                      m_axi_gmem2_BREADY,
    input  wire [1:0]                m_axi_gmem2_BRESP,
    output wire                      m_axi_gmem2_ARVALID,
    input  wire                      m_axi_gmem2_ARREADY,
    output wire [C_ADDR_WIDTH-1:0]   m_axi_gmem2_ARADDR,
    output wire [0:0]                m_axi_gmem2_ARID,
    output wire [7:0]                m_axi_gmem2_ARLEN,
    output wire [2:0]                m_axi_gmem2_ARSIZE,
    output wire [1:0]                m_axi_gmem2_ARBURST,
    output wire [1:0]                m_axi_gmem2_ARLOCK,
    output wire [3:0]                m_axi_gmem2_ARCACHE,
    output wire [2:0]                m_axi_gmem2_ARPROT,
    output wire [3:0]                m_axi_gmem2_ARQOS,
    input  wire                      m_axi_gmem2_RVALID,
    output wire                      m_axi_gmem2_RREADY,
    input  wire [31:0]               m_axi_gmem2_RDATA,
    input  wire                      m_axi_gmem2_RLAST,
    input  wire [1:0]                m_axi_gmem2_RRESP
);

    // NW > 1 is NOT implemented. The chunk buffers and the gather/scatter
    // below assume one 512-bit beat carries one whole state vector, which
    // holds for N <= 512 (ring50 and every n<=512 graph). An n1000 build
    // needs NW=2 and a two-beat gather; it would read as working and produce
    // garbage for the upper bits, so fail loudly at elaboration instead.
    initial begin
        if (NW != 1) begin
            $display("FATAL graph_engine_part: NW=%0d unsupported, only NW=1", NW);
            $finish;
        end
        if (N > WORD_BITS) begin
            $display("FATAL graph_engine_part: N=%0d > WORD_BITS=%0d", N, WORD_BITS);
            $finish;
        end
        if (CHUNK > 256) begin
            $display("FATAL graph_engine_part: CHUNK=%0d exceeds one AXI burst", CHUNK);
            $finish;
        end
    end

    localparam [2:0] SIZE_WIDE = (WORD_BITS == 512) ? 3'd6 :
                                 (WORD_BITS == 256) ? 3'd5 : 3'd4;
    localparam [8:0] CHUNK_9 = CHUNK;   // CHUNK as a 9-bit vector; a
                                        // bit-select of an integer
                                        // parameter is not portable.
    localparam integer CHUNK_W = (CHUNK <= 2)   ? 1 : (CHUNK <= 4)   ? 2 :
                                 (CHUNK <= 8)   ? 3 : (CHUNK <= 16)  ? 4 :
                                 (CHUNK <= 32)  ? 5 : (CHUNK <= 64)  ? 6 :
                                 (CHUNK <= 128) ? 7 : 8;

    // ======================= AXI4-Lite control ==========================
    // Standard XRT map. ap_done is clear-on-read of 0x00, which is what
    // xrt::run::wait() polls, so a missed clear hangs the host rather than
    // corrupting data -- worth getting exactly right.
    reg                      awready_r, wready_r, bvalid_r;
    reg                      arready_r, rvalid_r;
    reg [31:0]               rdata_r;
    reg [C_CTRL_ADDR_W-1:0]  waddr_r;
    reg                      waddr_valid;

    reg        ap_start, ap_done, ap_idle;
    reg        auto_restart;
    reg        gie, ier0, isr0;
    reg [63:0] arg_state_in, arg_part_out, arg_count_out;
    reg [31:0] arg_nq, arg_num_steps;

    assign s_axi_control_AWREADY = awready_r;
    assign s_axi_control_WREADY  = wready_r;
    assign s_axi_control_BVALID  = bvalid_r;
    assign s_axi_control_BRESP   = 2'b00;
    assign s_axi_control_ARREADY = arready_r;
    assign s_axi_control_RVALID  = rvalid_r;
    assign s_axi_control_RDATA   = rdata_r;
    assign s_axi_control_RRESP   = 2'b00;
    assign interrupt             = gie & ier0 & isr0;

    wire ctrl_write = waddr_valid & s_axi_control_WVALID & wready_r;

    always @(posedge ap_clk) begin
        if (!ap_rst_n) begin
            awready_r <= 1'b1; wready_r <= 1'b0; bvalid_r <= 1'b0;
            waddr_valid <= 1'b0; waddr_r <= {C_CTRL_ADDR_W{1'b0}};
        end else begin
            // Address phase: latch one address, then open the data phase.
            if (awready_r && s_axi_control_AWVALID) begin
                awready_r   <= 1'b0;
                waddr_r     <= s_axi_control_AWADDR;
                waddr_valid <= 1'b1;
                wready_r    <= 1'b1;
            end
            if (ctrl_write) begin
                wready_r    <= 1'b0;
                waddr_valid <= 1'b0;
                bvalid_r    <= 1'b1;
            end
            if (bvalid_r && s_axi_control_BREADY) begin
                bvalid_r  <= 1'b0;
                awready_r <= 1'b1;
            end
        end
    end

    always @(posedge ap_clk) begin
        if (!ap_rst_n) begin
            arready_r <= 1'b1; rvalid_r <= 1'b0; rdata_r <= 32'd0;
        end else begin
            if (arready_r && s_axi_control_ARVALID) begin
                arready_r <= 1'b0;
                rvalid_r  <= 1'b1;
                case (s_axi_control_ARADDR[7:0])
                    8'h00: rdata_r <= {24'd0, auto_restart, 3'd0,
                                       ap_done, ap_idle, ap_done, ap_start};
                    8'h04: rdata_r <= {31'd0, gie};
                    8'h08: rdata_r <= {31'd0, ier0};
                    8'h0C: rdata_r <= {31'd0, isr0};
                    8'h10: rdata_r <= arg_state_in[31:0];
                    8'h14: rdata_r <= arg_state_in[63:32];
                    8'h18: rdata_r <= arg_part_out[31:0];
                    8'h1C: rdata_r <= arg_part_out[63:32];
                    8'h20: rdata_r <= arg_count_out[31:0];
                    8'h24: rdata_r <= arg_count_out[63:32];
                    8'h28: rdata_r <= arg_nq;
                    8'h2C: rdata_r <= arg_num_steps;
                    default: rdata_r <= 32'd0;
                endcase
            end
            if (rvalid_r && s_axi_control_RREADY) begin
                rvalid_r  <= 1'b0;
                arready_r <= 1'b1;
            end
        end
    end

    // ======================= datapath state machine =====================
    localparam [3:0] S_IDLE    = 4'd0,  S_RD_ADDR = 4'd1,  S_RD_DATA = 4'd2,
                     S_COMPUTE = 4'd3,  S_WR_ADDR = 4'd4,  S_WR_DATA = 4'd5,
                     S_WR_RESP = 4'd6,  S_CT_ADDR = 4'd7,  S_CT_DATA = 4'd8,
                     S_CT_RESP = 4'd9,  S_NEXT    = 4'd10, S_DONE    = 4'd11;

    reg [3:0]  st;
    reg [31:0] q_base;                 // first query of the chunk in flight
    reg [8:0]  chunk_len;              // queries in this chunk, 1..CHUNK
    reg [8:0]  rd_ptr, feed_ptr, coll_ptr, wr_ptr;
    reg        do_hop_r;

    reg [WORD_BITS-1:0] rbuf [0:CHUNK-1];
    reg [N-1:0]         obuf [0:CHUNK-1];
    reg [31:0]          cbuf [0:CHUNK-1];

    // Chunk size for the burst about to be issued. nq is a host-supplied
    // 32-bit count; the min() keeps the last chunk short rather than reading
    // past the end of the buffer, which on HBM is a bus error, not a zero.
    wire [31:0] remaining  = arg_nq - q_base;
    wire [8:0]  next_len   = (remaining >= CHUNK) ? CHUNK_9 : remaining[8:0];

    // ---- the compute: one graph_or, fed one query per cycle -------------
    wire             go_in_valid  = (st == S_COMPUTE) && (feed_ptr < chunk_len);
    wire [N-1:0]     go_state_in  = rbuf[feed_ptr[CHUNK_W-1:0]][N-1:0];
    wire [N-1:0]     go_state_out;
    wire             go_out_valid;

    graph_or #(.N(N), .REG_EVERY(REG_EVERY)) u_graph_or (
        .clk       (ap_clk),
        .rst_n     (ap_rst_n),
        .in_valid  (go_in_valid),
        .do_hop    (do_hop_r),
        .state_in  (go_state_in),
        .state_out (go_state_out),
        .out_valid (go_out_valid)
    );

    // Population count of the result. The HLS kernel counts over the FULL
    // state width, including bits this partition does not own (they are 0),
    // so counting all N bits here matches it exactly.
    function [31:0] popcount_n;
        input [N-1:0] v;
        integer i;
        reg [31:0] acc;
        begin
            acc = 32'd0;
            for (i = 0; i < N; i = i + 1) acc = acc + {31'd0, v[i]};
            popcount_n = acc;
        end
    endfunction

    always @(posedge ap_clk) begin
        if (!ap_rst_n) begin
            st <= S_IDLE;
            ap_start <= 1'b0; ap_done <= 1'b0; ap_idle <= 1'b1;
            auto_restart <= 1'b0;
            gie <= 1'b0; ier0 <= 1'b0; isr0 <= 1'b0;
            arg_state_in <= 64'd0; arg_part_out <= 64'd0; arg_count_out <= 64'd0;
            arg_nq <= 32'd0; arg_num_steps <= 32'd0;
            q_base <= 32'd0; chunk_len <= 9'd0;
            rd_ptr <= 9'd0; feed_ptr <= 9'd0; coll_ptr <= 9'd0; wr_ptr <= 9'd0;
            do_hop_r <= 1'b0;
        end else begin
            // ---- control-register writes ------------------------------
            if (ctrl_write) begin
                case (waddr_r[7:0])
                    8'h00: begin
                        // ap_start is write-1-to-set and stays set until the
                        // run is accepted; writing 0 must not clear a run.
                        if (s_axi_control_WDATA[0]) ap_start <= 1'b1;
                        auto_restart <= s_axi_control_WDATA[7];
                    end
                    8'h04: gie  <= s_axi_control_WDATA[0];
                    8'h08: ier0 <= s_axi_control_WDATA[0];
                    8'h0C: if (s_axi_control_WDATA[0]) isr0 <= 1'b0;  // W1C
                    8'h10: arg_state_in[31:0]   <= s_axi_control_WDATA;
                    8'h14: arg_state_in[63:32]  <= s_axi_control_WDATA;
                    8'h18: arg_part_out[31:0]   <= s_axi_control_WDATA;
                    8'h1C: arg_part_out[63:32]  <= s_axi_control_WDATA;
                    8'h20: arg_count_out[31:0]  <= s_axi_control_WDATA;
                    8'h24: arg_count_out[63:32] <= s_axi_control_WDATA;
                    8'h28: arg_nq               <= s_axi_control_WDATA;
                    8'h2C: arg_num_steps        <= s_axi_control_WDATA;
                    default: ;
                endcase
            end
            // ap_done clears when the host reads 0x00, the XRT convention.
            if (arready_r && s_axi_control_ARVALID &&
                (s_axi_control_ARADDR[7:0] == 8'h00) && ap_done) begin
                ap_done <= 1'b0;
            end

            // ---- phases ----------------------------------------------
            case (st)
            S_IDLE: begin
                ap_idle <= 1'b1;
                if (ap_start) begin
                    ap_start <= 1'b0;
                    ap_idle  <= 1'b0;
                    q_base   <= 32'd0;
                    do_hop_r <= (arg_num_steps != 32'd0);
                    // nq == 0 is a legal no-op, not an empty burst.
                    st       <= (arg_nq == 32'd0) ? S_DONE : S_RD_ADDR;
                end
            end

            S_RD_ADDR: begin
                chunk_len <= next_len;
                rd_ptr    <= 9'd0;
                if (m_axi_gmem0_ARREADY) st <= S_RD_DATA;
            end

            S_RD_DATA: begin
                if (m_axi_gmem0_RVALID) begin
                    rbuf[rd_ptr[CHUNK_W-1:0]] <= m_axi_gmem0_RDATA;
                    rd_ptr <= rd_ptr + 9'd1;
                    if (m_axi_gmem0_RLAST) begin
                        feed_ptr <= 9'd0;
                        coll_ptr <= 9'd0;
                        st       <= S_COMPUTE;
                    end
                end
            end

            S_COMPUTE: begin
                // Feed and collect run concurrently; collection trails by the
                // tree's fixed latency and finishes chunk_len results after
                // the last feed. out_valid, not a counter, decides when a
                // result lands -- so REG_EVERY can change without touching
                // this logic.
                if (go_in_valid) feed_ptr <= feed_ptr + 9'd1;
                if (go_out_valid) begin
                    obuf[coll_ptr[CHUNK_W-1:0]] <= go_state_out;
                    cbuf[coll_ptr[CHUNK_W-1:0]] <= popcount_n(go_state_out);
                    coll_ptr <= coll_ptr + 9'd1;
                    if (coll_ptr + 9'd1 == chunk_len) begin
                        wr_ptr <= 9'd0;
                        st     <= S_WR_ADDR;
                    end
                end
            end

            S_WR_ADDR: begin
                if (m_axi_gmem1_AWREADY) st <= S_WR_DATA;
            end

            S_WR_DATA: begin
                if (m_axi_gmem1_WREADY) begin
                    wr_ptr <= wr_ptr + 9'd1;
                    if (wr_ptr + 9'd1 == chunk_len) st <= S_WR_RESP;
                end
            end

            S_WR_RESP: begin
                // Wait for BVALID before issuing the count burst: the two
                // masters are independent, and a host that sees count_out
                // land while part_out is still in flight would read a
                // consistent count beside stale state.
                if (m_axi_gmem1_BVALID) begin
                    wr_ptr <= 9'd0;
                    st     <= S_CT_ADDR;
                end
            end

            S_CT_ADDR: begin
                if (m_axi_gmem2_AWREADY) st <= S_CT_DATA;
            end

            S_CT_DATA: begin
                if (m_axi_gmem2_WREADY) begin
                    wr_ptr <= wr_ptr + 9'd1;
                    if (wr_ptr + 9'd1 == chunk_len) st <= S_CT_RESP;
                end
            end

            S_CT_RESP: begin
                if (m_axi_gmem2_BVALID) st <= S_NEXT;
            end

            S_NEXT: begin
                q_base <= q_base + {23'd0, chunk_len};
                st <= ((q_base + {23'd0, chunk_len}) >= arg_nq) ? S_DONE
                                                                : S_RD_ADDR;
            end

            S_DONE: begin
                ap_done <= 1'b1;
                ap_idle <= 1'b1;
                if (ier0) isr0 <= 1'b1;
                st <= S_IDLE;
            end

            default: st <= S_IDLE;
            endcase
        end
    end

    // ======================= AXI master wiring ==========================
    // gmem0: read only.
    assign m_axi_gmem0_ARVALID = (st == S_RD_ADDR);
    assign m_axi_gmem0_ARADDR  = arg_state_in + {{(C_ADDR_WIDTH-38){1'b0}},
                                                 q_base, 6'd0};
    assign m_axi_gmem0_ARLEN   = next_len[7:0] - 8'd1;
    assign m_axi_gmem0_ARSIZE  = SIZE_WIDE;
    assign m_axi_gmem0_ARBURST = 2'b01;
    assign m_axi_gmem0_ARID    = 1'b0;
    assign m_axi_gmem0_ARLOCK  = 2'b00;
    assign m_axi_gmem0_ARCACHE = 4'b0011;
    assign m_axi_gmem0_ARPROT  = 3'b000;
    assign m_axi_gmem0_ARQOS   = 4'b0000;
    assign m_axi_gmem0_RREADY  = (st == S_RD_DATA);
    assign m_axi_gmem0_AWVALID = 1'b0;
    assign m_axi_gmem0_AWADDR  = {C_ADDR_WIDTH{1'b0}};
    assign m_axi_gmem0_AWID    = 1'b0;
    assign m_axi_gmem0_AWLEN   = 8'd0;
    assign m_axi_gmem0_AWSIZE  = SIZE_WIDE;
    assign m_axi_gmem0_AWBURST = 2'b01;
    assign m_axi_gmem0_AWLOCK  = 2'b00;
    assign m_axi_gmem0_AWCACHE = 4'b0011;
    assign m_axi_gmem0_AWPROT  = 3'b000;
    assign m_axi_gmem0_AWQOS   = 4'b0000;
    assign m_axi_gmem0_WVALID  = 1'b0;
    assign m_axi_gmem0_WDATA   = {WORD_BITS{1'b0}};
    assign m_axi_gmem0_WSTRB   = {(WORD_BITS/8){1'b0}};
    assign m_axi_gmem0_WLAST   = 1'b0;
    assign m_axi_gmem0_BREADY  = 1'b1;

    // gmem1: write only, 512-bit. Bits N..511 are written as zero so the
    // host-side OR across partitions stays a plain OR.
    assign m_axi_gmem1_AWVALID = (st == S_WR_ADDR);
    assign m_axi_gmem1_AWADDR  = arg_part_out + {{(C_ADDR_WIDTH-38){1'b0}},
                                                 q_base, 6'd0};
    assign m_axi_gmem1_AWLEN   = chunk_len[7:0] - 8'd1;
    assign m_axi_gmem1_AWSIZE  = SIZE_WIDE;
    assign m_axi_gmem1_AWBURST = 2'b01;
    assign m_axi_gmem1_AWID    = 1'b0;
    assign m_axi_gmem1_AWLOCK  = 2'b00;
    assign m_axi_gmem1_AWCACHE = 4'b0011;
    assign m_axi_gmem1_AWPROT  = 3'b000;
    assign m_axi_gmem1_AWQOS   = 4'b0000;
    assign m_axi_gmem1_WVALID  = (st == S_WR_DATA);
    assign m_axi_gmem1_WDATA   = {{(WORD_BITS-N){1'b0}},
                                  obuf[wr_ptr[CHUNK_W-1:0]]};
    assign m_axi_gmem1_WSTRB   = {(WORD_BITS/8){1'b1}};
    assign m_axi_gmem1_WLAST   = (st == S_WR_DATA) &&
                                 (wr_ptr + 9'd1 == chunk_len);
    assign m_axi_gmem1_BREADY  = (st == S_WR_RESP);
    assign m_axi_gmem1_ARVALID = 1'b0;
    assign m_axi_gmem1_ARADDR  = {C_ADDR_WIDTH{1'b0}};
    assign m_axi_gmem1_ARID    = 1'b0;
    assign m_axi_gmem1_ARLEN   = 8'd0;
    assign m_axi_gmem1_ARSIZE  = SIZE_WIDE;
    assign m_axi_gmem1_ARBURST = 2'b01;
    assign m_axi_gmem1_ARLOCK  = 2'b00;
    assign m_axi_gmem1_ARCACHE = 4'b0011;
    assign m_axi_gmem1_ARPROT  = 3'b000;
    assign m_axi_gmem1_ARQOS   = 4'b0000;
    assign m_axi_gmem1_RREADY  = 1'b1;

    // gmem2: write only, 32-bit, one count per query.
    assign m_axi_gmem2_AWVALID = (st == S_CT_ADDR);
    assign m_axi_gmem2_AWADDR  = arg_count_out + {{(C_ADDR_WIDTH-34){1'b0}},
                                                  q_base, 2'd0};
    assign m_axi_gmem2_AWLEN   = chunk_len[7:0] - 8'd1;
    assign m_axi_gmem2_AWSIZE  = 3'd2;
    assign m_axi_gmem2_AWBURST = 2'b01;
    assign m_axi_gmem2_AWID    = 1'b0;
    assign m_axi_gmem2_AWLOCK  = 2'b00;
    assign m_axi_gmem2_AWCACHE = 4'b0011;
    assign m_axi_gmem2_AWPROT  = 3'b000;
    assign m_axi_gmem2_AWQOS   = 4'b0000;
    assign m_axi_gmem2_WVALID  = (st == S_CT_DATA);
    assign m_axi_gmem2_WDATA   = cbuf[wr_ptr[CHUNK_W-1:0]];
    assign m_axi_gmem2_WSTRB   = 4'b1111;
    assign m_axi_gmem2_WLAST   = (st == S_CT_DATA) &&
                                 (wr_ptr + 9'd1 == chunk_len);
    assign m_axi_gmem2_BREADY  = (st == S_CT_RESP);
    assign m_axi_gmem2_ARVALID = 1'b0;
    assign m_axi_gmem2_ARADDR  = {C_ADDR_WIDTH{1'b0}};
    assign m_axi_gmem2_ARID    = 1'b0;
    assign m_axi_gmem2_ARLEN   = 8'd0;
    assign m_axi_gmem2_ARSIZE  = 3'd2;
    assign m_axi_gmem2_ARBURST = 2'b01;
    assign m_axi_gmem2_ARLOCK  = 2'b00;
    assign m_axi_gmem2_ARCACHE = 4'b0011;
    assign m_axi_gmem2_ARPROT  = 3'b000;
    assign m_axi_gmem2_ARQOS   = 4'b0000;
    assign m_axi_gmem2_RREADY  = 1'b1;

endmodule

`default_nettype wire
