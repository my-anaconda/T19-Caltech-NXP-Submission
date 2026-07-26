`timescale 1ns/1ps
// Functional test: THREE routers, verifying real X-then-Y multi-hop
// forwarding (not just a single hop). Topology:
//   A (0,0) --East/West-- B (1,0) --North/South-- C (1,1)
// A injects a WRITE destined for node (1,1). At A: dest_x(1) > NODE_X(0)
// -> go_east -> forwarded to B over the A<->B East/West link (same link
// wiring already proven in tb_router_forward.v). At B: dest_x(1) ==
// NODE_X(1) and dest_y(1) > NODE_Y(0) -> go_north -> forwarded to C over
// a SEPARATE B<->C North/South link (B's p0 <-> C's p1). At C: dest_x(1)
// == NODE_X(1) and dest_y(1) == NODE_Y(1) -> go_local -> delivered to
// C's own SRAM. This is the doc's own worked "X then Y" example, and is
// the first real test that a packet re-forwarded by an intermediate
// router (B) - not just originated - is handled correctly.
module tb_router_2hop;
    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    wire [2:0] z3=0; wire[2:0] z3b=0; wire z1=0; wire[31:0]z32=0; wire[7:0]z8=0; wire[63:0]z64=0;

    // ================= Router A (0,0) =================
    reg  [2:0] a_loc_a_opcode, a_loc_a_param, a_loc_a_size;
    reg  [3:0] a_loc_a_source;
    reg  [31:0] a_loc_a_addr;
    reg  [7:0] a_loc_a_mask;
    reg  [63:0] a_loc_a_data;
    reg  a_loc_a_valid;
    wire a_loc_a_ready;
    wire a_loc_d_valid;
    reg  a_loc_d_ready;

    wire a_sram_awvalid, a_sram_wvalid, a_sram_arvalid, a_sram_bready, a_sram_rready;
    wire [31:0] a_sram_awaddr, a_sram_araddr;
    wire [63:0] a_sram_wdata;
    wire [7:0] a_sram_wstrb;

    // A<->B link (A's East p2 <-> B's West p3)
    wire [2:0] ab_e_opcode, ab_e_param, ab_e_size; wire [3:0] ab_e_source;
    wire [31:0] ab_e_addr; wire [7:0] ab_e_mask; wire [63:0] ab_e_data; wire ab_e_valid, ab_e_ready;
    wire [2:0] ab_ed_opcode; wire [1:0] ab_ed_param; wire [2:0] ab_ed_size; wire [3:0] ab_ed_source;
    wire [63:0] ab_ed_data; wire ab_ed_valid, ab_ed_ready;

    u_router_a #(.NODE_X(0), .NODE_Y(0), .DATA_W(64), .ADDR_W(32)) ra (
        .clk(clk), .rst_n(rst_n),
        .loc_a_opcode(a_loc_a_opcode), .loc_a_param(a_loc_a_param), .loc_a_size(a_loc_a_size),
        .loc_a_source(a_loc_a_source), .loc_a_addr(a_loc_a_addr), .loc_a_mask(a_loc_a_mask),
        .loc_a_data(a_loc_a_data), .loc_a_valid(a_loc_a_valid), .loc_a_ready(a_loc_a_ready),
        .loc_d_opcode(), .loc_d_param(), .loc_d_size(), .loc_d_source(), .loc_d_data(),
        .loc_d_valid(a_loc_d_valid), .loc_d_ready(a_loc_d_ready),
        .sram_awaddr(a_sram_awaddr), .sram_awvalid(a_sram_awvalid), .sram_awready(1'b0),
        .sram_wdata(a_sram_wdata), .sram_wstrb(a_sram_wstrb), .sram_wvalid(a_sram_wvalid), .sram_wready(1'b0),
        .sram_bresp(2'b0), .sram_bvalid(1'b0), .sram_bready(a_sram_bready),
        .sram_araddr(a_sram_araddr), .sram_arvalid(a_sram_arvalid), .sram_arready(1'b0),
        .sram_rdata(64'b0), .sram_rresp(2'b0), .sram_rvalid(1'b0), .sram_rready(a_sram_rready),
        // North (p0) - no neighbour
        .p0_s_a_opcode(z3), .p0_s_a_param(z3b), .p0_s_a_size(z3), .p0_s_a_source(z3b),
        .p0_s_a_addr(z32), .p0_s_a_mask(z8), .p0_s_a_data(z64), .p0_s_a_valid(z1), .p0_s_a_ready(),
        .p0_s_d_opcode(), .p0_s_d_param(), .p0_s_d_size(), .p0_s_d_source(), .p0_s_d_data(), .p0_s_d_valid(), .p0_s_d_ready(1'b0),
        .p0_m_a_opcode(), .p0_m_a_param(), .p0_m_a_size(), .p0_m_a_source(), .p0_m_a_addr(), .p0_m_a_mask(), .p0_m_a_data(), .p0_m_a_valid(), .p0_m_a_ready(1'b0),
        .p0_m_d_opcode(z3), .p0_m_d_param(2'b0), .p0_m_d_size(z3), .p0_m_d_source(z3b), .p0_m_d_data(z64), .p0_m_d_valid(z1), .p0_m_d_ready(),
        // South (p1) - no neighbour
        .p1_s_a_opcode(z3), .p1_s_a_param(z3b), .p1_s_a_size(z3), .p1_s_a_source(z3b),
        .p1_s_a_addr(z32), .p1_s_a_mask(z8), .p1_s_a_data(z64), .p1_s_a_valid(z1), .p1_s_a_ready(),
        .p1_s_d_opcode(), .p1_s_d_param(), .p1_s_d_size(), .p1_s_d_source(), .p1_s_d_data(), .p1_s_d_valid(), .p1_s_d_ready(1'b0),
        .p1_m_a_opcode(), .p1_m_a_param(), .p1_m_a_size(), .p1_m_a_source(), .p1_m_a_addr(), .p1_m_a_mask(), .p1_m_a_data(), .p1_m_a_valid(), .p1_m_a_ready(1'b0),
        .p1_m_d_opcode(z3), .p1_m_d_param(2'b0), .p1_m_d_size(z3), .p1_m_d_source(z3b), .p1_m_d_data(z64), .p1_m_d_valid(z1), .p1_m_d_ready(),
        // East (p2) -> B's West
        .p2_s_a_opcode(z3), .p2_s_a_param(z3b), .p2_s_a_size(z3), .p2_s_a_source(z3b),
        .p2_s_a_addr(z32), .p2_s_a_mask(z8), .p2_s_a_data(z64), .p2_s_a_valid(z1), .p2_s_a_ready(),
        .p2_s_d_opcode(), .p2_s_d_param(), .p2_s_d_size(), .p2_s_d_source(), .p2_s_d_data(), .p2_s_d_valid(), .p2_s_d_ready(1'b0),
        .p2_m_a_opcode(ab_e_opcode), .p2_m_a_param(ab_e_param), .p2_m_a_size(ab_e_size), .p2_m_a_source(ab_e_source),
        .p2_m_a_addr(ab_e_addr), .p2_m_a_mask(ab_e_mask), .p2_m_a_data(ab_e_data), .p2_m_a_valid(ab_e_valid), .p2_m_a_ready(ab_e_ready),
        .p2_m_d_opcode(ab_ed_opcode), .p2_m_d_param(ab_ed_param), .p2_m_d_size(ab_ed_size), .p2_m_d_source(ab_ed_source),
        .p2_m_d_data(ab_ed_data), .p2_m_d_valid(ab_ed_valid), .p2_m_d_ready(ab_ed_ready),
        // West (p3) - no neighbour
        .p3_s_a_opcode(z3), .p3_s_a_param(z3b), .p3_s_a_size(z3), .p3_s_a_source(z3b),
        .p3_s_a_addr(z32), .p3_s_a_mask(z8), .p3_s_a_data(z64), .p3_s_a_valid(z1), .p3_s_a_ready(),
        .p3_s_d_opcode(), .p3_s_d_param(), .p3_s_d_size(), .p3_s_d_source(), .p3_s_d_data(), .p3_s_d_valid(), .p3_s_d_ready(1'b0),
        .p3_m_a_opcode(), .p3_m_a_param(), .p3_m_a_size(), .p3_m_a_source(), .p3_m_a_addr(), .p3_m_a_mask(), .p3_m_a_data(), .p3_m_a_valid(), .p3_m_a_ready(1'b0),
        .p3_m_d_opcode(z3), .p3_m_d_param(2'b0), .p3_m_d_size(z3), .p3_m_d_source(z3b), .p3_m_d_data(z64), .p3_m_d_valid(z1), .p3_m_d_ready()
    );

    // ================= Router B (1,0) - the PASS-THROUGH node =================
    wire [2:0] bc_n_opcode, bc_n_param, bc_n_size; wire [3:0] bc_n_source;
    wire [31:0] bc_n_addr; wire [7:0] bc_n_mask; wire [63:0] bc_n_data; wire bc_n_valid, bc_n_ready;
    wire [2:0] bc_nd_opcode; wire [1:0] bc_nd_param; wire [2:0] bc_nd_size; wire [3:0] bc_nd_source;
    wire [63:0] bc_nd_data; wire bc_nd_valid, bc_nd_ready;

    u_router_b #(.NODE_X(1), .NODE_Y(0), .DATA_W(64), .ADDR_W(32)) rb (
        .clk(clk), .rst_n(rst_n),
        .loc_a_opcode(3'b0), .loc_a_param(3'b0), .loc_a_size(3'b0), .loc_a_source(4'b0),
        .loc_a_addr(32'b0), .loc_a_mask(8'b0), .loc_a_data(64'b0), .loc_a_valid(1'b0), .loc_a_ready(),
        .loc_d_opcode(), .loc_d_param(), .loc_d_size(), .loc_d_source(), .loc_d_data(), .loc_d_valid(), .loc_d_ready(1'b1),
        // B's own SRAM: unused stub in this test (packet only passes through B)
        .sram_awaddr(), .sram_awvalid(), .sram_awready(1'b0),
        .sram_wdata(), .sram_wstrb(), .sram_wvalid(), .sram_wready(1'b0),
        .sram_bresp(2'b0), .sram_bvalid(1'b0), .sram_bready(),
        .sram_araddr(), .sram_arvalid(), .sram_arready(1'b0),
        .sram_rdata(64'b0), .sram_rresp(2'b0), .sram_rvalid(1'b0), .sram_rready(),
        // North (p0) -> C's South
        .p0_s_a_opcode(z3), .p0_s_a_param(z3b), .p0_s_a_size(z3), .p0_s_a_source(z3b),
        .p0_s_a_addr(z32), .p0_s_a_mask(z8), .p0_s_a_data(z64), .p0_s_a_valid(z1), .p0_s_a_ready(),
        .p0_s_d_opcode(), .p0_s_d_param(), .p0_s_d_size(), .p0_s_d_source(), .p0_s_d_data(), .p0_s_d_valid(), .p0_s_d_ready(1'b0),
        .p0_m_a_opcode(bc_n_opcode), .p0_m_a_param(bc_n_param), .p0_m_a_size(bc_n_size), .p0_m_a_source(bc_n_source),
        .p0_m_a_addr(bc_n_addr), .p0_m_a_mask(bc_n_mask), .p0_m_a_data(bc_n_data), .p0_m_a_valid(bc_n_valid), .p0_m_a_ready(bc_n_ready),
        .p0_m_d_opcode(bc_nd_opcode), .p0_m_d_param(bc_nd_param), .p0_m_d_size(bc_nd_size), .p0_m_d_source(bc_nd_source),
        .p0_m_d_data(bc_nd_data), .p0_m_d_valid(bc_nd_valid), .p0_m_d_ready(bc_nd_ready),
        // South (p1) - no neighbour
        .p1_s_a_opcode(z3), .p1_s_a_param(z3b), .p1_s_a_size(z3), .p1_s_a_source(z3b),
        .p1_s_a_addr(z32), .p1_s_a_mask(z8), .p1_s_a_data(z64), .p1_s_a_valid(z1), .p1_s_a_ready(),
        .p1_s_d_opcode(), .p1_s_d_param(), .p1_s_d_size(), .p1_s_d_source(), .p1_s_d_data(), .p1_s_d_valid(), .p1_s_d_ready(1'b0),
        .p1_m_a_opcode(), .p1_m_a_param(), .p1_m_a_size(), .p1_m_a_source(), .p1_m_a_addr(), .p1_m_a_mask(), .p1_m_a_data(), .p1_m_a_valid(), .p1_m_a_ready(1'b0),
        .p1_m_d_opcode(z3), .p1_m_d_param(2'b0), .p1_m_d_size(z3), .p1_m_d_source(z3b), .p1_m_d_data(z64), .p1_m_d_valid(z1), .p1_m_d_ready(),
        // East (p2) - no neighbour
        .p2_s_a_opcode(z3), .p2_s_a_param(z3b), .p2_s_a_size(z3), .p2_s_a_source(z3b),
        .p2_s_a_addr(z32), .p2_s_a_mask(z8), .p2_s_a_data(z64), .p2_s_a_valid(z1), .p2_s_a_ready(),
        .p2_s_d_opcode(), .p2_s_d_param(), .p2_s_d_size(), .p2_s_d_source(), .p2_s_d_data(), .p2_s_d_valid(), .p2_s_d_ready(1'b0),
        .p2_m_a_opcode(), .p2_m_a_param(), .p2_m_a_size(), .p2_m_a_source(), .p2_m_a_addr(), .p2_m_a_mask(), .p2_m_a_data(), .p2_m_a_valid(), .p2_m_a_ready(1'b0),
        .p2_m_d_opcode(z3), .p2_m_d_param(2'b0), .p2_m_d_size(z3), .p2_m_d_source(z3b), .p2_m_d_data(z64), .p2_m_d_valid(z1), .p2_m_d_ready(),
        // West (p3) -> A's East
        .p3_s_a_opcode(ab_e_opcode), .p3_s_a_param(ab_e_param), .p3_s_a_size(ab_e_size), .p3_s_a_source(ab_e_source),
        .p3_s_a_addr(ab_e_addr), .p3_s_a_mask(ab_e_mask), .p3_s_a_data(ab_e_data), .p3_s_a_valid(ab_e_valid), .p3_s_a_ready(ab_e_ready),
        .p3_s_d_opcode(ab_ed_opcode), .p3_s_d_param(ab_ed_param), .p3_s_d_size(ab_ed_size), .p3_s_d_source(ab_ed_source),
        .p3_s_d_data(ab_ed_data), .p3_s_d_valid(ab_ed_valid), .p3_s_d_ready(ab_ed_ready),
        .p3_m_a_opcode(), .p3_m_a_param(), .p3_m_a_size(), .p3_m_a_source(), .p3_m_a_addr(), .p3_m_a_mask(), .p3_m_a_data(), .p3_m_a_valid(), .p3_m_a_ready(1'b0),
        .p3_m_d_opcode(z3), .p3_m_d_param(2'b0), .p3_m_d_size(z3), .p3_m_d_source(z3b), .p3_m_d_data(z64), .p3_m_d_valid(z1), .p3_m_d_ready()
    );

    // ================= Router C (1,1) - the DESTINATION node =================
    wire [31:0] c_sram_awaddr; wire c_sram_awvalid; reg c_sram_awready;
    wire [63:0] c_sram_wdata; wire [7:0] c_sram_wstrb; wire c_sram_wvalid; reg c_sram_wready;
    reg [1:0] c_sram_bresp; reg c_sram_bvalid; wire c_sram_bready;
    wire [31:0] c_sram_araddr; wire c_sram_arvalid; reg c_sram_arready;
    reg [63:0] c_sram_rdata; reg [1:0] c_sram_rresp; reg c_sram_rvalid; wire c_sram_rready;

    u_router_c #(.NODE_X(1), .NODE_Y(1), .DATA_W(64), .ADDR_W(32)) rc (
        .clk(clk), .rst_n(rst_n),
        .loc_a_opcode(3'b0), .loc_a_param(3'b0), .loc_a_size(3'b0), .loc_a_source(4'b0),
        .loc_a_addr(32'b0), .loc_a_mask(8'b0), .loc_a_data(64'b0), .loc_a_valid(1'b0), .loc_a_ready(),
        .loc_d_opcode(), .loc_d_param(), .loc_d_size(), .loc_d_source(), .loc_d_data(), .loc_d_valid(), .loc_d_ready(1'b1),
        .sram_awaddr(c_sram_awaddr), .sram_awvalid(c_sram_awvalid), .sram_awready(c_sram_awready),
        .sram_wdata(c_sram_wdata), .sram_wstrb(c_sram_wstrb), .sram_wvalid(c_sram_wvalid), .sram_wready(c_sram_wready),
        .sram_bresp(c_sram_bresp), .sram_bvalid(c_sram_bvalid), .sram_bready(c_sram_bready),
        .sram_araddr(c_sram_araddr), .sram_arvalid(c_sram_arvalid), .sram_arready(c_sram_arready),
        .sram_rdata(c_sram_rdata), .sram_rresp(c_sram_rresp), .sram_rvalid(c_sram_rvalid), .sram_rready(c_sram_rready),
        // North (p0) - no neighbour
        .p0_s_a_opcode(z3), .p0_s_a_param(z3b), .p0_s_a_size(z3), .p0_s_a_source(z3b),
        .p0_s_a_addr(z32), .p0_s_a_mask(z8), .p0_s_a_data(z64), .p0_s_a_valid(z1), .p0_s_a_ready(),
        .p0_s_d_opcode(), .p0_s_d_param(), .p0_s_d_size(), .p0_s_d_source(), .p0_s_d_data(), .p0_s_d_valid(), .p0_s_d_ready(1'b0),
        .p0_m_a_opcode(), .p0_m_a_param(), .p0_m_a_size(), .p0_m_a_source(), .p0_m_a_addr(), .p0_m_a_mask(), .p0_m_a_data(), .p0_m_a_valid(), .p0_m_a_ready(1'b0),
        .p0_m_d_opcode(z3), .p0_m_d_param(2'b0), .p0_m_d_size(z3), .p0_m_d_source(z3b), .p0_m_d_data(z64), .p0_m_d_valid(z1), .p0_m_d_ready(),
        // South (p1) -> B's North
        .p1_s_a_opcode(bc_n_opcode), .p1_s_a_param(bc_n_param), .p1_s_a_size(bc_n_size), .p1_s_a_source(bc_n_source),
        .p1_s_a_addr(bc_n_addr), .p1_s_a_mask(bc_n_mask), .p1_s_a_data(bc_n_data), .p1_s_a_valid(bc_n_valid), .p1_s_a_ready(bc_n_ready),
        .p1_s_d_opcode(bc_nd_opcode), .p1_s_d_param(bc_nd_param), .p1_s_d_size(bc_nd_size), .p1_s_d_source(bc_nd_source),
        .p1_s_d_data(bc_nd_data), .p1_s_d_valid(bc_nd_valid), .p1_s_d_ready(bc_nd_ready),
        .p1_m_a_opcode(), .p1_m_a_param(), .p1_m_a_size(), .p1_m_a_source(), .p1_m_a_addr(), .p1_m_a_mask(), .p1_m_a_data(), .p1_m_a_valid(), .p1_m_a_ready(1'b0),
        .p1_m_d_opcode(z3), .p1_m_d_param(2'b0), .p1_m_d_size(z3), .p1_m_d_source(z3b), .p1_m_d_data(z64), .p1_m_d_valid(z1), .p1_m_d_ready(),
        // East (p2) - no neighbour
        .p2_s_a_opcode(z3), .p2_s_a_param(z3b), .p2_s_a_size(z3), .p2_s_a_source(z3b),
        .p2_s_a_addr(z32), .p2_s_a_mask(z8), .p2_s_a_data(z64), .p2_s_a_valid(z1), .p2_s_a_ready(),
        .p2_s_d_opcode(), .p2_s_d_param(), .p2_s_d_size(), .p2_s_d_source(), .p2_s_d_data(), .p2_s_d_valid(), .p2_s_d_ready(1'b0),
        .p2_m_a_opcode(), .p2_m_a_param(), .p2_m_a_size(), .p2_m_a_source(), .p2_m_a_addr(), .p2_m_a_mask(), .p2_m_a_data(), .p2_m_a_valid(), .p2_m_a_ready(1'b0),
        .p2_m_d_opcode(z3), .p2_m_d_param(2'b0), .p2_m_d_size(z3), .p2_m_d_source(z3b), .p2_m_d_data(z64), .p2_m_d_valid(z1), .p2_m_d_ready(),
        // West (p3) - no neighbour
        .p3_s_a_opcode(z3), .p3_s_a_param(z3b), .p3_s_a_size(z3), .p3_s_a_source(z3b),
        .p3_s_a_addr(z32), .p3_s_a_mask(z8), .p3_s_a_data(z64), .p3_s_a_valid(z1), .p3_s_a_ready(),
        .p3_s_d_opcode(), .p3_s_d_param(), .p3_s_d_size(), .p3_s_d_source(), .p3_s_d_data(), .p3_s_d_valid(), .p3_s_d_ready(1'b0),
        .p3_m_a_opcode(), .p3_m_a_param(), .p3_m_a_size(), .p3_m_a_source(), .p3_m_a_addr(), .p3_m_a_mask(), .p3_m_a_data(), .p3_m_a_valid(), .p3_m_a_ready(1'b0),
        .p3_m_d_opcode(z3), .p3_m_d_param(2'b0), .p3_m_d_size(z3), .p3_m_d_source(z3b), .p3_m_d_data(z64), .p3_m_d_valid(z1), .p3_m_d_ready()
    );

    // C's SRAM: real memory model (same convention as B's in tb_router_forward.v)
    reg [63:0] mem [0:15];
    reg c_aw_seen;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            c_sram_awready<=1; c_sram_wready<=1; c_sram_bvalid<=0; c_sram_bresp<=0;
            c_sram_arready<=1; c_sram_rvalid<=0; c_aw_seen<=0;
        end else begin
            if (c_sram_awvalid && c_sram_awready && c_sram_wvalid && c_sram_wready) begin
                mem[c_sram_awaddr[5:3]] <= c_sram_wdata;
                c_sram_bvalid<=1; c_aw_seen<=1;
                $display("[%0t] C's SRAM received WRITE: addr=%0d data=%h", $time, c_sram_awaddr[5:3], c_sram_wdata);
            end
            if (c_sram_bvalid && c_sram_bready) c_sram_bvalid<=0;
        end
    end

    integer errors = 0;
    reg a_loc_d_valid_seen = 0;
    always @(posedge clk) if (a_loc_d_valid) a_loc_d_valid_seen <= 1'b1;

    initial begin
        rst_n = 0; a_loc_a_valid = 0;
        a_loc_a_opcode=0; a_loc_a_param=0; a_loc_a_size=0; a_loc_a_source=0;
        a_loc_a_addr=0; a_loc_a_mask=0; a_loc_a_data=0; a_loc_d_ready=1;
        repeat(4) @(posedge clk);
        rst_n = 1;
        repeat(4) @(posedge clk);

        // Inject a WRITE (PutFullData=0) at A's local port, destined for
        // node (1,1) - two hops away (East then North): addr[31:28]=1
        // (dest_x), addr[27:24]=1 (dest_y).
        @(posedge clk);
        a_loc_a_opcode = 3'd0; a_loc_a_source = 4'd9;
        a_loc_a_addr = 32'h1100_0020;  // dest_x=1 dest_y=1, local offset 0x20 -> word idx 4
        a_loc_a_mask = 8'hFF;
        a_loc_a_data = 64'hFEED_FACE_0BAD_C0DE;
        a_loc_a_valid = 1'b1;
        wait (a_loc_a_ready);
        @(posedge clk);
        a_loc_a_valid = 1'b0;

        fork : wait_or_timeout
            begin
                wait (c_aw_seen == 1'b1);
                disable wait_or_timeout;
            end
            begin
                repeat (300) @(posedge clk);
                $display("[FAIL] Timed out waiting for the write to reach C's SRAM (2-hop forward did not complete).");
                errors = errors + 1;
                disable wait_or_timeout;
            end
        join

        repeat(20) @(posedge clk);

        if (mem[4] === 64'hFEED_FACE_0BAD_C0DE) begin
            $display("[PASS] 2-hop (East then North) forward WORKED: C's memory[4] = %h", mem[4]);
        end else begin
            $display("[FAIL] C's memory[4] = %h, expected FEED_FACE_0BAD_C0DE", mem[4]);
            errors = errors + 1;
        end

        if (a_loc_d_valid_seen) $display("[PASS] Write-ack D-channel response returned all the way to A's local port.");
        else begin
            $display("[FAIL] No D-channel ack ever reached A's local port.");
            errors = errors + 1;
        end

        if (errors == 0) $display("SCORE: 1/1");
        else $display("SCORE: 0/1");
        $finish;
    end

    initial begin
        #20000;
        $display("[TIMEOUT]");
        $finish;
    end
endmodule
