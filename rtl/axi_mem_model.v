// axi_mem_model.v -- behavioural AXI4 slave with a backing memory, for xsim.
//
// Simulation only. Exists so the RTL kernel's masters can be exercised before
// a 2-hour v++ link: every protocol bug this catches is a P&R run not wasted.
//
// STALL != 0 deasserts READY/VALID on a fixed cycle pattern. A master that
// only works against an always-ready slave is the classic way an AXI bug
// reaches hardware, so the regression runs both STALL=0 and STALL=3.
`default_nettype none
`timescale 1ns/1ps

module axi_mem_model #(
    parameter integer DATA_W = 512,
    parameter integer ADDR_W = 64,
    parameter integer DEPTH  = 4096,   // words of DATA_W bits
    parameter integer STALL  = 0       // 0 = always ready; k = stall 1 in k
) (
    input  wire               clk,
    input  wire               rst_n,

    input  wire               AWVALID,
    output wire               AWREADY,
    input  wire [ADDR_W-1:0]  AWADDR,
    input  wire [7:0]         AWLEN,
    input  wire               WVALID,
    output wire               WREADY,
    input  wire [DATA_W-1:0]  WDATA,
    input  wire [DATA_W/8-1:0] WSTRB,
    input  wire               WLAST,
    output wire               BVALID,
    input  wire               BREADY,
    output wire [1:0]         BRESP,

    input  wire               ARVALID,
    output wire               ARREADY,
    input  wire [ADDR_W-1:0]  ARADDR,
    input  wire [7:0]         ARLEN,
    output wire               RVALID,
    input  wire               RREADY,
    output wire [DATA_W-1:0]  RDATA,
    output wire               RLAST,
    output wire [1:0]         RRESP
);
    localparam integer SHIFT = (DATA_W == 512) ? 6 : (DATA_W == 256) ? 5 :
                               (DATA_W == 128) ? 4 : (DATA_W == 64) ? 3 : 2;

    reg [DATA_W-1:0] mem [0:DEPTH-1];

    reg [31:0] tick;
    always @(posedge clk) tick <= rst_n ? tick + 32'd1 : 32'd0;
    wire allow = (STALL == 0) ? 1'b1 : ((tick % STALL) != 0);

    // ---- write side ----
    reg                 aw_busy;
    reg [ADDR_W-1:0]    aw_addr;
    reg [8:0]           w_left;
    reg                 b_valid;

    assign AWREADY = !aw_busy && allow;
    assign WREADY  = aw_busy && !b_valid && allow;
    assign BVALID  = b_valid;
    assign BRESP   = 2'b00;

    always @(posedge clk) begin
        if (!rst_n) begin
            aw_busy <= 1'b0; b_valid <= 1'b0; w_left <= 9'd0;
            aw_addr <= {ADDR_W{1'b0}};
        end else begin
            if (AWREADY && AWVALID) begin
                aw_busy <= 1'b1;
                aw_addr <= AWADDR;
                w_left  <= {1'b0, AWLEN} + 9'd1;
            end
            if (WREADY && WVALID) begin
                mem[aw_addr[ADDR_W-1:SHIFT] % DEPTH] <= WDATA;
                aw_addr <= aw_addr + (DATA_W/8);
                w_left  <= w_left - 9'd1;
                if (WLAST) begin
                    aw_busy <= 1'b0;
                    b_valid <= 1'b1;
                    if (w_left != 9'd1)
                        $display("[%0t] AXI_MEM ERROR: WLAST with %0d beats left",
                                 $time, w_left - 9'd1);
                end
            end
            if (b_valid && BREADY) b_valid <= 1'b0;
        end
    end

    // ---- read side ----
    reg              ar_busy;
    reg [ADDR_W-1:0] ar_addr;
    reg [8:0]        r_left;

    assign ARREADY = !ar_busy && allow;
    assign RVALID  = ar_busy && allow;
    assign RDATA   = mem[ar_addr[ADDR_W-1:SHIFT] % DEPTH];
    assign RLAST   = ar_busy && (r_left == 9'd1);
    assign RRESP   = 2'b00;

    always @(posedge clk) begin
        if (!rst_n) begin
            ar_busy <= 1'b0; r_left <= 9'd0; ar_addr <= {ADDR_W{1'b0}};
        end else begin
            if (ARREADY && ARVALID) begin
                ar_busy <= 1'b1;
                ar_addr <= ARADDR;
                r_left  <= {1'b0, ARLEN} + 9'd1;
            end else if (RVALID && RREADY) begin
                ar_addr <= ar_addr + (DATA_W/8);
                r_left  <= r_left - 9'd1;
                if (r_left == 9'd1) ar_busy <= 1'b0;
            end
        end
    end
endmodule

`default_nettype wire
