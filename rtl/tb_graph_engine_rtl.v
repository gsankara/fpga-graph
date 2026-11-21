// tb_graph_engine_rtl.v -- end-to-end testbench for the RTL kernel.
//
// Drives the kernel exactly as XRT does -- AXI4-Lite register writes, then
// ap_start, then poll 0x00 for ap_done -- against behavioural AXI memories,
// and checks BOTH outputs: part_out words and count_out popcounts.
//
// Expected values come from vectors.txt (graphgen/gen_rtl_or.py
// --emit-vectors, computed by reference.py), the same reference the HLS path
// is validated against. The testbench does NOT recompute the hop: a TB that
// reimplements the logic can agree with a bug in it.
//
// Two tops at the bottom run it with an always-ready slave and with a
// stalling one. Passing only the first is the standard way an AXI handshake
// bug reaches hardware.
`default_nettype none
`timescale 1ns/1ps

module tb_kernel_core #(
    parameter integer STALL = 0,
    parameter integer N     = 50,
    parameter integer MAXV  = 4096
);
    localparam integer WORD_BITS = 512;
    localparam integer TIMEOUT   = 2000000;

    // Byte bases inside each model's memory. Non-zero on purpose: a kernel
    // that ignores the base address passes at base 0 and fails on hardware.
    localparam [63:0] BASE_IN  = 64'h0000_0000_0000_1000;   // word 64
    localparam [63:0] BASE_OUT = 64'h0000_0000_0000_2000;   // word 128
    localparam [63:0] BASE_CNT = 64'h0000_0000_0000_0400;   // count 256

    reg clk = 1'b0, rst_n = 1'b0;
    always #1.665 clk = ~clk;          // ~300 MHz, the kernel's target

    // ---- AXI4-Lite control ----
    reg         awvalid = 1'b0, wvalid = 1'b0, bready = 1'b1;
    reg  [11:0] awaddr  = 12'd0;
    reg  [31:0] wdata   = 32'd0;
    reg         arvalid = 1'b0, rready = 1'b1;
    reg  [11:0] araddr  = 12'd0;
    wire        awready, wready, bvalid, arready, rvalid;
    wire [31:0] rdata;
    wire        irq;

    // ---- kernel <-> memories ----
    wire                   g0_awvalid, g0_wvalid, g0_wlast, g0_bready;
    wire                   g0_arvalid, g0_rready;
    wire [63:0]            g0_awaddr, g0_araddr;
    wire [7:0]             g0_awlen, g0_arlen;
    wire [WORD_BITS-1:0]   g0_wdata, g0_rdata;
    wire [WORD_BITS/8-1:0] g0_wstrb;
    wire                   g0_awready, g0_wready, g0_bvalid, g0_arready,
                           g0_rvalid, g0_rlast;

    wire                   g1_awvalid, g1_wvalid, g1_wlast, g1_bready;
    wire                   g1_arvalid, g1_rready;
    wire [63:0]            g1_awaddr, g1_araddr;
    wire [7:0]             g1_awlen, g1_arlen;
    wire [WORD_BITS-1:0]   g1_wdata, g1_rdata;
    wire [WORD_BITS/8-1:0] g1_wstrb;
    wire                   g1_awready, g1_wready, g1_bvalid, g1_arready,
                           g1_rvalid, g1_rlast;

    wire                   g2_awvalid, g2_wvalid, g2_wlast, g2_bready;
    wire                   g2_arvalid, g2_rready;
    wire [63:0]            g2_awaddr, g2_araddr;
    wire [7:0]             g2_awlen, g2_arlen;
    wire [31:0]            g2_wdata, g2_rdata;
    wire [3:0]             g2_wstrb;
    wire                   g2_awready, g2_wready, g2_bvalid, g2_arready,
                           g2_rvalid, g2_rlast;

    graph_engine_part #(.N(N), .WORD_BITS(WORD_BITS), .NW(1), .CHUNK(64),
                        .REG_EVERY(2), .GRAPH_OR_LATENCY(2)) dut (
        .ap_clk(clk), .ap_rst_n(rst_n),
        .s_axi_control_AWVALID(awvalid), .s_axi_control_AWREADY(awready),
        .s_axi_control_AWADDR(awaddr),
        .s_axi_control_WVALID(wvalid),   .s_axi_control_WREADY(wready),
        .s_axi_control_WDATA(wdata),     .s_axi_control_WSTRB(4'hF),
        .s_axi_control_BVALID(bvalid),   .s_axi_control_BREADY(bready),
        .s_axi_control_BRESP(),
        .s_axi_control_ARVALID(arvalid), .s_axi_control_ARREADY(arready),
        .s_axi_control_ARADDR(araddr),
        .s_axi_control_RVALID(rvalid),   .s_axi_control_RREADY(rready),
        .s_axi_control_RDATA(rdata),     .s_axi_control_RRESP(),
        .interrupt(irq),

        .m_axi_gmem0_AWVALID(g0_awvalid), .m_axi_gmem0_AWREADY(g0_awready),
        .m_axi_gmem0_AWADDR(g0_awaddr),   .m_axi_gmem0_AWID(),
        .m_axi_gmem0_AWLEN(g0_awlen),     .m_axi_gmem0_AWSIZE(),
        .m_axi_gmem0_AWBURST(),           .m_axi_gmem0_AWLOCK(),
        .m_axi_gmem0_AWCACHE(),           .m_axi_gmem0_AWPROT(),
        .m_axi_gmem0_AWQOS(),
        .m_axi_gmem0_WVALID(g0_wvalid),   .m_axi_gmem0_WREADY(g0_wready),
        .m_axi_gmem0_WDATA(g0_wdata),     .m_axi_gmem0_WSTRB(g0_wstrb),
        .m_axi_gmem0_WLAST(g0_wlast),
        .m_axi_gmem0_BVALID(g0_bvalid),   .m_axi_gmem0_BREADY(g0_bready),
        .m_axi_gmem0_BRESP(2'b00),
        .m_axi_gmem0_ARVALID(g0_arvalid), .m_axi_gmem0_ARREADY(g0_arready),
        .m_axi_gmem0_ARADDR(g0_araddr),   .m_axi_gmem0_ARID(),
        .m_axi_gmem0_ARLEN(g0_arlen),     .m_axi_gmem0_ARSIZE(),
        .m_axi_gmem0_ARBURST(),           .m_axi_gmem0_ARLOCK(),
        .m_axi_gmem0_ARCACHE(),           .m_axi_gmem0_ARPROT(),
        .m_axi_gmem0_ARQOS(),
        .m_axi_gmem0_RVALID(g0_rvalid),   .m_axi_gmem0_RREADY(g0_rready),
        .m_axi_gmem0_RDATA(g0_rdata),     .m_axi_gmem0_RLAST(g0_rlast),
        .m_axi_gmem0_RRESP(2'b00),

        .m_axi_gmem1_AWVALID(g1_awvalid), .m_axi_gmem1_AWREADY(g1_awready),
        .m_axi_gmem1_AWADDR(g1_awaddr),   .m_axi_gmem1_AWID(),
        .m_axi_gmem1_AWLEN(g1_awlen),     .m_axi_gmem1_AWSIZE(),
        .m_axi_gmem1_AWBURST(),           .m_axi_gmem1_AWLOCK(),
        .m_axi_gmem1_AWCACHE(),           .m_axi_gmem1_AWPROT(),
        .m_axi_gmem1_AWQOS(),
        .m_axi_gmem1_WVALID(g1_wvalid),   .m_axi_gmem1_WREADY(g1_wready),
        .m_axi_gmem1_WDATA(g1_wdata),     .m_axi_gmem1_WSTRB(g1_wstrb),
        .m_axi_gmem1_WLAST(g1_wlast),
        .m_axi_gmem1_BVALID(g1_bvalid),   .m_axi_gmem1_BREADY(g1_bready),
        .m_axi_gmem1_BRESP(2'b00),
        .m_axi_gmem1_ARVALID(g1_arvalid), .m_axi_gmem1_ARREADY(g1_arready),
        .m_axi_gmem1_ARADDR(g1_araddr),   .m_axi_gmem1_ARID(),
        .m_axi_gmem1_ARLEN(g1_arlen),     .m_axi_gmem1_ARSIZE(),
        .m_axi_gmem1_ARBURST(),           .m_axi_gmem1_ARLOCK(),
        .m_axi_gmem1_ARCACHE(),           .m_axi_gmem1_ARPROT(),
        .m_axi_gmem1_ARQOS(),
        .m_axi_gmem1_RVALID(g1_rvalid),   .m_axi_gmem1_RREADY(g1_rready),
        .m_axi_gmem1_RDATA(g1_rdata),     .m_axi_gmem1_RLAST(g1_rlast),
        .m_axi_gmem1_RRESP(2'b00),

        .m_axi_gmem2_AWVALID(g2_awvalid), .m_axi_gmem2_AWREADY(g2_awready),
        .m_axi_gmem2_AWADDR(g2_awaddr),   .m_axi_gmem2_AWID(),
        .m_axi_gmem2_AWLEN(g2_awlen),     .m_axi_gmem2_AWSIZE(),
        .m_axi_gmem2_AWBURST(),           .m_axi_gmem2_AWLOCK(),
        .m_axi_gmem2_AWCACHE(),           .m_axi_gmem2_AWPROT(),
        .m_axi_gmem2_AWQOS(),
        .m_axi_gmem2_WVALID(g2_wvalid),   .m_axi_gmem2_WREADY(g2_wready),
        .m_axi_gmem2_WDATA(g2_wdata),     .m_axi_gmem2_WSTRB(g2_wstrb),
        .m_axi_gmem2_WLAST(g2_wlast),
        .m_axi_gmem2_BVALID(g2_bvalid),   .m_axi_gmem2_BREADY(g2_bready),
        .m_axi_gmem2_BRESP(2'b00),
        .m_axi_gmem2_ARVALID(g2_arvalid), .m_axi_gmem2_ARREADY(g2_arready),
        .m_axi_gmem2_ARADDR(g2_araddr),   .m_axi_gmem2_ARID(),
        .m_axi_gmem2_ARLEN(g2_arlen),     .m_axi_gmem2_ARSIZE(),
        .m_axi_gmem2_ARBURST(),           .m_axi_gmem2_ARLOCK(),
        .m_axi_gmem2_ARCACHE(),           .m_axi_gmem2_ARPROT(),
        .m_axi_gmem2_ARQOS(),
        .m_axi_gmem2_RVALID(g2_rvalid),   .m_axi_gmem2_RREADY(g2_rready),
        .m_axi_gmem2_RDATA(g2_rdata),     .m_axi_gmem2_RLAST(g2_rlast),
        .m_axi_gmem2_RRESP(2'b00)
    );

    axi_mem_model #(.DATA_W(512), .DEPTH(1024), .STALL(STALL)) u_mem0 (
        .clk(clk), .rst_n(rst_n),
        .AWVALID(g0_awvalid), .AWREADY(g0_awready), .AWADDR(g0_awaddr),
        .AWLEN(g0_awlen), .WVALID(g0_wvalid), .WREADY(g0_wready),
        .WDATA(g0_wdata), .WSTRB(g0_wstrb), .WLAST(g0_wlast),
        .BVALID(g0_bvalid), .BREADY(g0_bready), .BRESP(),
        .ARVALID(g0_arvalid), .ARREADY(g0_arready), .ARADDR(g0_araddr),
        .ARLEN(g0_arlen), .RVALID(g0_rvalid), .RREADY(g0_rready),
        .RDATA(g0_rdata), .RLAST(g0_rlast), .RRESP());

    axi_mem_model #(.DATA_W(512), .DEPTH(1024), .STALL(STALL)) u_mem1 (
        .clk(clk), .rst_n(rst_n),
        .AWVALID(g1_awvalid), .AWREADY(g1_awready), .AWADDR(g1_awaddr),
        .AWLEN(g1_awlen), .WVALID(g1_wvalid), .WREADY(g1_wready),
        .WDATA(g1_wdata), .WSTRB(g1_wstrb), .WLAST(g1_wlast),
        .BVALID(g1_bvalid), .BREADY(g1_bready), .BRESP(),
        .ARVALID(g1_arvalid), .ARREADY(g1_arready), .ARADDR(g1_araddr),
        .ARLEN(g1_arlen), .RVALID(g1_rvalid), .RREADY(g1_rready),
        .RDATA(g1_rdata), .RLAST(g1_rlast), .RRESP());

    axi_mem_model #(.DATA_W(32), .DEPTH(4096), .STALL(STALL)) u_mem2 (
        .clk(clk), .rst_n(rst_n),
        .AWVALID(g2_awvalid), .AWREADY(g2_awready), .AWADDR(g2_awaddr),
        .AWLEN(g2_awlen), .WVALID(g2_wvalid), .WREADY(g2_wready),
        .WDATA(g2_wdata), .WSTRB(g2_wstrb), .WLAST(g2_wlast),
        .BVALID(g2_bvalid), .BREADY(g2_bready), .BRESP(),
        .ARVALID(g2_arvalid), .ARREADY(g2_arready), .ARADDR(g2_araddr),
        .ARLEN(g2_arlen), .RVALID(g2_rvalid), .RREADY(g2_rready),
        .RDATA(g2_rdata), .RLAST(g2_rlast), .RRESP());

    // ---- AXI4-Lite master tasks ----
    task axil_write(input [11:0] a, input [31:0] d);
    begin
        @(posedge clk);
        awaddr <= a; wdata <= d; awvalid <= 1'b1; wvalid <= 1'b1;
        @(posedge clk);
        while (!(awready && wready)) @(posedge clk);
        awvalid <= 1'b0; wvalid <= 1'b0;
        while (!bvalid) @(posedge clk);
        @(posedge clk);
    end
    endtask

    task axil_read(input [11:0] a, output [31:0] d);
    begin
        @(posedge clk);
        araddr <= a; arvalid <= 1'b1;
        @(posedge clk);
        while (!arready) @(posedge clk);
        arvalid <= 1'b0;
        while (!rvalid) @(posedge clk);
        d = rdata;
        @(posedge clk);
    end
    endtask

    // ---- vectors ----
    integer fd, code, nvec, i, j, errors, cycles;
    reg [N-1:0] vin_a  [0:MAXV-1];
    reg [N-1:0] vexp_a [0:MAXV-1];
    reg         hop_a  [0:MAXV-1];
    reg [N-1:0] vin, vexp;
    integer     hop_i, nsel, want_cnt, got_cnt;
    reg [N-1:0] got;
    reg [31:0]  rv;
    integer     sel [0:MAXV-1];

    function integer pop_n;
        input [N-1:0] v;
        integer k, acc;
        begin
            acc = 0;
            for (k = 0; k < N; k = k + 1) acc = acc + v[k];
            pop_n = acc;
        end
    endfunction

    // One pass: load the selected vectors, run, check both outputs.
    task run_pass(input integer want_hop);
    begin
        nsel = 0;
        for (i = 0; i < nvec; i = i + 1)
            if (hop_a[i] === want_hop[0:0]) begin
                sel[nsel] = i;
                nsel = nsel + 1;
            end
        if (nsel == 0) begin
            $display("  (no vectors with do_hop=%0d, pass skipped)", want_hop);
        end else begin
            for (i = 0; i < nsel; i = i + 1)
                u_mem0.mem[(BASE_IN >> 6) + i] =
                    {{(512-N){1'b0}}, vin_a[sel[i]]};
            for (i = 0; i < nsel; i = i + 1) begin
                u_mem1.mem[(BASE_OUT >> 6) + i] = {512{1'bx}};
                u_mem2.mem[(BASE_CNT >> 2) + i] = 32'hDEAD_BEEF;
            end

            axil_write(12'h010, BASE_IN[31:0]);
            axil_write(12'h014, BASE_IN[63:32]);
            axil_write(12'h018, BASE_OUT[31:0]);
            axil_write(12'h01C, BASE_OUT[63:32]);
            axil_write(12'h020, BASE_CNT[31:0]);
            axil_write(12'h024, BASE_CNT[63:32]);
            axil_write(12'h028, nsel);
            axil_write(12'h02C, want_hop);        // num_steps
            axil_write(12'h000, 32'h1);           // ap_start

            cycles = 0;
            rv = 32'd0;
            while (!rv[1] && cycles < TIMEOUT) begin
                axil_read(12'h000, rv);
                cycles = cycles + 1;
            end
            if (!rv[1]) begin
                $display("  FAIL do_hop=%0d: ap_done never asserted (timeout)",
                         want_hop);
                errors = errors + 1;
            end else begin
                for (i = 0; i < nsel; i = i + 1) begin
                    got      = u_mem1.mem[(BASE_OUT >> 6) + i][N-1:0];
                    got_cnt  = u_mem2.mem[(BASE_CNT >> 2) + i];
                    vexp     = vexp_a[sel[i]];
                    want_cnt = pop_n(vexp);
                    if (got !== vexp) begin
                        errors = errors + 1;
                        if (errors < 12)
                            $display("  FAIL state q=%0d do_hop=%0d: got %h want %h",
                                     i, want_hop, got, vexp);
                    end
                    if (got_cnt !== want_cnt) begin
                        errors = errors + 1;
                        if (errors < 12)
                            $display("  FAIL count q=%0d do_hop=%0d: got %0d want %0d",
                                     i, want_hop, got_cnt, want_cnt);
                    end
                    // Upper bits must be zero: the host ORs these words across
                    // cards, so any junk above bit N-1 corrupts the combine.
                    if (u_mem1.mem[(BASE_OUT >> 6) + i][511:N] !== {(512-N){1'b0}}) begin
                        errors = errors + 1;
                        if (errors < 12)
                            $display("  FAIL q=%0d: bits above %0d are not zero",
                                     i, N-1);
                    end
                end
                $display("  do_hop=%0d: %0d vectors checked", want_hop, nsel);
            end
        end
    end
    endtask

    initial begin
        errors = 0; nvec = 0;
        fd = $fopen("vectors.txt", "r");
        if (fd == 0) begin
            $display("TB_RESULT: FAIL (cannot open vectors.txt)");
            $finish;
        end
        while (!$feof(fd) && nvec < MAXV) begin
            code = $fscanf(fd, "%b %d %b\n", vin, hop_i, vexp);
            if (code != 3) begin
                if (code > 0)
                    $display("  NOTE: short read code=%0d after %0d vectors",
                             code, nvec);
            end else begin
                vin_a[nvec]  = vin;
                vexp_a[nvec] = vexp;
                hop_a[nvec]  = hop_i[0];
                nvec = nvec + 1;
            end
        end
        $fclose(fd);
        $display("tb_kernel (STALL=%0d): %0d vectors loaded", STALL, nvec);
        if (nvec == 0) begin
            $display("TB_RESULT: FAIL (no vectors)");
            $finish;
        end

        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (8) @(posedge clk);

        // nq == 0 must complete without touching memory, not hang.
        axil_write(12'h010, BASE_IN[31:0]);
        axil_write(12'h018, BASE_OUT[31:0]);
        axil_write(12'h020, BASE_CNT[31:0]);
        axil_write(12'h028, 32'd0);
        axil_write(12'h02C, 32'd1);
        axil_write(12'h000, 32'h1);
        cycles = 0; rv = 32'd0;
        while (!rv[1] && cycles < 1000) begin
            axil_read(12'h000, rv);
            cycles = cycles + 1;
        end
        if (!rv[1]) begin
            $display("  FAIL nq=0 did not complete");
            errors = errors + 1;
        end else begin
            $display("  nq=0 completed cleanly");
        end

        run_pass(1);     // the hop
        run_pass(0);     // pass-through

        if (errors == 0)
            $display("TB_RESULT: PASS (%0d vectors, STALL=%0d)", nvec, STALL);
        else
            $display("TB_RESULT: FAIL (%0d error(s), STALL=%0d)", errors, STALL);
        $finish;
    end

    // Hard stop, so a hung handshake fails the run instead of sitting in the
    // simulator until someone notices.
    initial begin
        #20000000;
        $display("TB_RESULT: FAIL (global timeout)");
        $finish;
    end
endmodule

module tb_graph_engine_rtl;
    tb_kernel_core #(.STALL(0)) u_core ();
endmodule

module tb_graph_engine_rtl_stall;
    tb_kernel_core #(.STALL(3)) u_core ();
endmodule

`default_nettype wire
