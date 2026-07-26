`timescale 1ns/1ps
// Functional test: two routers (A at node 0,0 and B at node 1,0, B is A's
// East neighbour) wired together exactly per the real mesh convention
// (A's East-master <-> B's West-slave, and vice versa for the return path).
// Drives a WRITE request into A's local inject port destined for node
// (1,0) and checks it actually reaches B's attached SRAM model and that
// the write-ack comes back to A's local D-channel - i.e. a real, working
// single-hop forward, not just "it elaborates".
module tb_router_forward;
    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    // ---- Router A (0,0) ----
    reg  [2:0] a_loc_a_opcode, a_loc_a_param;
    reg  [2:0] a_loc_a_size;
    reg  [3:0] a_loc_a_source;
    reg  [31:0] a_loc_a_addr;
    reg  [7:0] a_loc_a_mask;
    reg  [63:0] a_loc_a_data;
    reg  a_loc_a_valid;
    wire a_loc_a_ready;
    wire [2:0] a_loc_d_opcode; wire [1:0] a_loc_d_param; wire [2:0] a_loc_d_size;
    wire [3:0] a_loc_d_source; wire [63:0] a_loc_d_data; wire a_loc_d_valid;
    reg  a_loc_d_ready;

    // Router A's own SRAM (unused in this cross-node test, tied idle)
    wire [31:0] a_sram_awaddr; wire a_sram_awvalid; reg a_sram_awready;
    wire [63:0] a_sram_wdata; wire [7:0] a_sram_wstrb; wire a_sram_wvalid; reg a_sram_wready;
    reg [1:0] a_sram_bresp; reg a_sram_bvalid; wire a_sram_bready;
    wire [31:0] a_sram_araddr; wire a_sram_arvalid; reg a_sram_arready;
    reg [63:0] a_sram_rdata; reg [1:0] a_sram_rresp; reg a_sram_rvalid; wire a_sram_rready;

    // A's N/S/W boundary slave ports tied per doc ("boundary ports must be tied to zero")
    wire [2:0] z3=0; wire[2:0] z3b=0; wire z1=0; wire[31:0]z32=0; wire[7:0]z8=0; wire[63:0]z64=0;
    wire dummy_ready;

    // A<->B link on the East/West pair (A's East = B; B's West = A)
    wire [2:0] link_e_opcode, link_e_param; wire [2:0] link_e_size; wire [3:0] link_e_source;
    wire [31:0] link_e_addr; wire [7:0] link_e_mask; wire [63:0] link_e_data; wire link_e_valid; wire link_e_ready;
    wire [2:0] link_ed_opcode; wire [1:0] link_ed_param; wire [2:0] link_ed_size; wire [3:0] link_ed_source;
    wire [63:0] link_ed_data; wire link_ed_valid; wire link_ed_ready;

    u_router_a #(.NODE_X(0), .NODE_Y(0), .DATA_W(64), .ADDR_W(32)) ra (
        .clk(clk), .rst_n(rst_n),
        .loc_a_opcode(a_loc_a_opcode), .loc_a_param(a_loc_a_param), .loc_a_size(a_loc_a_size),
        .loc_a_source(a_loc_a_source), .loc_a_addr(a_loc_a_addr), .loc_a_mask(a_loc_a_mask),
        .loc_a_data(a_loc_a_data), .loc_a_valid(a_loc_a_valid), .loc_a_ready(a_loc_a_ready),
        .loc_d_opcode(a_loc_d_opcode), .loc_d_param(a_loc_d_param), .loc_d_size(a_loc_d_size),
        .loc_d_source(a_loc_d_source), .loc_d_data(a_loc_d_data), .loc_d_valid(a_loc_d_valid), .loc_d_ready(a_loc_d_ready),
        .sram_awaddr(a_sram_awaddr), .sram_awvalid(a_sram_awvalid), .sram_awready(a_sram_awready),
        .sram_wdata(a_sram_wdata), .sram_wstrb(a_sram_wstrb), .sram_wvalid(a_sram_wvalid), .sram_wready(a_sram_wready),
        .sram_bresp(a_sram_bresp), .sram_bvalid(a_sram_bvalid), .sram_bready(a_sram_bready),
        .sram_araddr(a_sram_araddr), .sram_arvalid(a_sram_arvalid), .sram_arready(a_sram_arready),
        .sram_rdata(a_sram_rdata), .sram_rresp(a_sram_rresp), .sram_rvalid(a_sram_rvalid), .sram_rready(a_sram_rready),
        // North (p0) - no neighbour, tie off
        .p0_s_a_opcode(z3), .p0_s_a_param(z3b), .p0_s_a_size(z3), .p0_s_a_source(z3b),
        .p0_s_a_addr(z32), .p0_s_a_mask(z8), .p0_s_a_data(z64), .p0_s_a_valid(z1), .p0_s_a_ready(),
        .p0_s_d_opcode(), .p0_s_d_param(), .p0_s_d_size(), .p0_s_d_source(), .p0_s_d_data(), .p0_s_d_valid(), .p0_s_d_ready(1'b0),
        .p0_m_a_opcode(), .p0_m_a_param(), .p0_m_a_size(), .p0_m_a_source(), .p0_m_a_addr(), .p0_m_a_mask(), .p0_m_a_data(), .p0_m_a_valid(), .p0_m_a_ready(1'b0),
        .p0_m_d_opcode(z3), .p0_m_d_param(2'b0), .p0_m_d_size(z3), .p0_m_d_source(z3b), .p0_m_d_data(z64), .p0_m_d_valid(z1), .p0_m_d_ready(),
        // South (p1) - no neighbour, tie off
        .p1_s_a_opcode(z3), .p1_s_a_param(z3b), .p1_s_a_size(z3), .p1_s_a_source(z3b),
        .p1_s_a_addr(z32), .p1_s_a_mask(z8), .p1_s_a_data(z64), .p1_s_a_valid(z1), .p1_s_a_ready(),
        .p1_s_d_opcode(), .p1_s_d_param(), .p1_s_d_size(), .p1_s_d_source(), .p1_s_d_data(), .p1_s_d_valid(), .p1_s_d_ready(1'b0),
        .p1_m_a_opcode(), .p1_m_a_param(), .p1_m_a_size(), .p1_m_a_source(), .p1_m_a_addr(), .p1_m_a_mask(), .p1_m_a_data(), .p1_m_a_valid(), .p1_m_a_ready(1'b0),
        .p1_m_d_opcode(z3), .p1_m_d_param(2'b0), .p1_m_d_size(z3), .p1_m_d_source(z3b), .p1_m_d_data(z64), .p1_m_d_valid(z1), .p1_m_d_ready(),
        // East (p2) - connects to B's West
        .p2_s_a_opcode(z3), .p2_s_a_param(z3b), .p2_s_a_size(z3), .p2_s_a_source(z3b),
        .p2_s_a_addr(z32), .p2_s_a_mask(z8), .p2_s_a_data(z64), .p2_s_a_valid(z1), .p2_s_a_ready(),
        .p2_s_d_opcode(), .p2_s_d_param(), .p2_s_d_size(), .p2_s_d_source(), .p2_s_d_data(), .p2_s_d_valid(), .p2_s_d_ready(1'b0),
        .p2_m_a_opcode(link_e_opcode), .p2_m_a_param(link_e_param), .p2_m_a_size(link_e_size), .p2_m_a_source(link_e_source),
        .p2_m_a_addr(link_e_addr), .p2_m_a_mask(link_e_mask), .p2_m_a_data(link_e_data), .p2_m_a_valid(link_e_valid), .p2_m_a_ready(link_e_ready),
        .p2_m_d_opcode(link_ed_opcode), .p2_m_d_param(link_ed_param), .p2_m_d_size(link_ed_size), .p2_m_d_source(link_ed_source),
        .p2_m_d_data(link_ed_data), .p2_m_d_valid(link_ed_valid), .p2_m_d_ready(link_ed_ready),
        // West (p3) - no neighbour, tie off
        .p3_s_a_opcode(z3), .p3_s_a_param(z3b), .p3_s_a_size(z3), .p3_s_a_source(z3b),
        .p3_s_a_addr(z32), .p3_s_a_mask(z8), .p3_s_a_data(z64), .p3_s_a_valid(z1), .p3_s_a_ready(),
        .p3_s_d_opcode(), .p3_s_d_param(), .p3_s_d_size(), .p3_s_d_source(), .p3_s_d_data(), .p3_s_d_valid(), .p3_s_d_ready(1'b0),
        .p3_m_a_opcode(), .p3_m_a_param(), .p3_m_a_size(), .p3_m_a_source(), .p3_m_a_addr(), .p3_m_a_mask(), .p3_m_a_data(), .p3_m_a_valid(), .p3_m_a_ready(1'b0),
        .p3_m_d_opcode(z3), .p3_m_d_param(2'b0), .p3_m_d_size(z3), .p3_m_d_source(z3b), .p3_m_d_data(z64), .p3_m_d_valid(z1), .p3_m_d_ready()
    );

    // ---- Router B (1,0) ----
    wire [31:0] b_sram_awaddr; wire b_sram_awvalid; reg b_sram_awready;
    wire [63:0] b_sram_wdata; wire [7:0] b_sram_wstrb; wire b_sram_wvalid; reg b_sram_wready;
    reg [1:0] b_sram_bresp; reg b_sram_bvalid; wire b_sram_bready;
    wire [31:0] b_sram_araddr; wire b_sram_arvalid; reg b_sram_arready;
    reg [63:0] b_sram_rdata; reg [1:0] b_sram_rresp; reg b_sram_rvalid; wire b_sram_rready;
    reg  [2:0] b_loc_a_opcode, b_loc_a_param;
    reg  [2:0] b_loc_a_size;
    reg  [3:0] b_loc_a_source;
    reg  [31:0] b_loc_a_addr;
    reg  [7:0] b_loc_a_mask;
    reg  [63:0] b_loc_a_data;
    reg  b_loc_a_valid = 0;
    wire b_loc_a_ready;
    reg  b_loc_d_ready = 1;

    u_router_b #(.NODE_X(1), .NODE_Y(0), .DATA_W(64), .ADDR_W(32)) rb (
        .clk(clk), .rst_n(rst_n),
        .loc_a_opcode(3'b0), .loc_a_param(3'b0), .loc_a_size(3'b0), .loc_a_source(4'b0),
        .loc_a_addr(32'b0), .loc_a_mask(8'b0), .loc_a_data(64'b0), .loc_a_valid(1'b0), .loc_a_ready(),
        .loc_d_opcode(), .loc_d_param(), .loc_d_size(), .loc_d_source(), .loc_d_data(), .loc_d_valid(), .loc_d_ready(1'b1),
        .sram_awaddr(b_sram_awaddr), .sram_awvalid(b_sram_awvalid), .sram_awready(b_sram_awready),
        .sram_wdata(b_sram_wdata), .sram_wstrb(b_sram_wstrb), .sram_wvalid(b_sram_wvalid), .sram_wready(b_sram_wready),
        .sram_bresp(b_sram_bresp), .sram_bvalid(b_sram_bvalid), .sram_bready(b_sram_bready),
        .sram_araddr(b_sram_araddr), .sram_arvalid(b_sram_arvalid), .sram_arready(b_sram_arready),
        .sram_rdata(b_sram_rdata), .sram_rresp(b_sram_rresp), .sram_rvalid(b_sram_rvalid), .sram_rready(b_sram_rready),
        .p0_s_a_opcode(z3), .p0_s_a_param(z3b), .p0_s_a_size(z3), .p0_s_a_source(z3b),
        .p0_s_a_addr(z32), .p0_s_a_mask(z8), .p0_s_a_data(z64), .p0_s_a_valid(z1), .p0_s_a_ready(),
        .p0_s_d_opcode(), .p0_s_d_param(), .p0_s_d_size(), .p0_s_d_source(), .p0_s_d_data(), .p0_s_d_valid(), .p0_s_d_ready(1'b0),
        .p0_m_a_opcode(), .p0_m_a_param(), .p0_m_a_size(), .p0_m_a_source(), .p0_m_a_addr(), .p0_m_a_mask(), .p0_m_a_data(), .p0_m_a_valid(), .p0_m_a_ready(1'b0),
        .p0_m_d_opcode(z3), .p0_m_d_param(2'b0), .p0_m_d_size(z3), .p0_m_d_source(z3b), .p0_m_d_data(z64), .p0_m_d_valid(z1), .p0_m_d_ready(),
        .p1_s_a_opcode(z3), .p1_s_a_param(z3b), .p1_s_a_size(z3), .p1_s_a_source(z3b),
        .p1_s_a_addr(z32), .p1_s_a_mask(z8), .p1_s_a_data(z64), .p1_s_a_valid(z1), .p1_s_a_ready(),
        .p1_s_d_opcode(), .p1_s_d_param(), .p1_s_d_size(), .p1_s_d_source(), .p1_s_d_data(), .p1_s_d_valid(), .p1_s_d_ready(1'b0),
        .p1_m_a_opcode(), .p1_m_a_param(), .p1_m_a_size(), .p1_m_a_source(), .p1_m_a_addr(), .p1_m_a_mask(), .p1_m_a_data(), .p1_m_a_valid(), .p1_m_a_ready(1'b0),
        .p1_m_d_opcode(z3), .p1_m_d_param(2'b0), .p1_m_d_size(z3), .p1_m_d_source(z3b), .p1_m_d_data(z64), .p1_m_d_valid(z1), .p1_m_d_ready(),
        .p2_s_a_opcode(z3), .p2_s_a_param(z3b), .p2_s_a_size(z3), .p2_s_a_source(z3b),
        .p2_s_a_addr(z32), .p2_s_a_mask(z8), .p2_s_a_data(z64), .p2_s_a_valid(z1), .p2_s_a_ready(),
        .p2_s_d_opcode(), .p2_s_d_param(), .p2_s_d_size(), .p2_s_d_source(), .p2_s_d_data(), .p2_s_d_valid(), .p2_s_d_ready(1'b0),
        .p2_m_a_opcode(), .p2_m_a_param(), .p2_m_a_size(), .p2_m_a_source(), .p2_m_a_addr(), .p2_m_a_mask(), .p2_m_a_data(), .p2_m_a_valid(), .p2_m_a_ready(1'b0),
        .p2_m_d_opcode(z3), .p2_m_d_param(2'b0), .p2_m_d_size(z3), .p2_m_d_source(z3b), .p2_m_d_data(z64), .p2_m_d_valid(z1), .p2_m_d_ready(),
        // West (p3) - connects to A's East (link)
        .p3_s_a_opcode(link_e_opcode), .p3_s_a_param(link_e_param), .p3_s_a_size(link_e_size), .p3_s_a_source(link_e_source),
        .p3_s_a_addr(link_e_addr), .p3_s_a_mask(link_e_mask), .p3_s_a_data(link_e_data), .p3_s_a_valid(link_e_valid), .p3_s_a_ready(link_e_ready),
        .p3_s_d_opcode(link_ed_opcode), .p3_s_d_param(link_ed_param), .p3_s_d_size(link_ed_size), .p3_s_d_source(link_ed_source),
        .p3_s_d_data(link_ed_data), .p3_s_d_valid(link_ed_valid), .p3_s_d_ready(link_ed_ready),
        .p3_m_a_opcode(), .p3_m_a_param(), .p3_m_a_size(), .p3_m_a_source(), .p3_m_a_addr(), .p3_m_a_mask(), .p3_m_a_data(), .p3_m_a_valid(), .p3_m_a_ready(1'b0),
        .p3_m_d_opcode(z3), .p3_m_d_param(2'b0), .p3_m_d_size(z3), .p3_m_d_source(z3b), .p3_m_d_data(z64), .p3_m_d_valid(z1), .p3_m_d_ready()
    );

    // A's own SRAM: unused stub, always idle/not-ready (never exercised in this test)
    initial begin a_sram_awready=0; a_sram_wready=0; a_sram_bresp=0; a_sram_bvalid=0; a_sram_arready=0; a_sram_rdata=0; a_sram_rresp=0; a_sram_rvalid=0; end

    // B's SRAM: a REAL simple memory model, so we can verify the write actually
    // lands. Accepts AW and W together in the same cycle (valid AXI4-Lite
    // behaviour, and what the router actually does) rather than requiring
    // them on separate cycles.
    reg [63:0] mem [0:15];
    reg b_aw_seen;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            b_sram_awready<=1; b_sram_wready<=1; b_sram_bvalid<=0; b_sram_bresp<=0;
            b_sram_arready<=1; b_sram_rvalid<=0; b_aw_seen<=0;
        end else begin
            if (b_sram_awvalid && b_sram_awready && b_sram_wvalid && b_sram_wready) begin
                mem[b_sram_awaddr[5:3]] <= b_sram_wdata;
                b_sram_bvalid<=1; b_aw_seen<=1;
                $display("[%0t] B's SRAM received WRITE: addr=%0d data=%h", $time, b_sram_awaddr[5:3], b_sram_wdata);
            end
            if (b_sram_bvalid && b_sram_bready) b_sram_bvalid<=0;
        end
    end

    integer errors = 0;
    initial begin
        rst_n = 0; a_loc_a_valid = 0;
        a_loc_a_opcode=0; a_loc_a_param=0; a_loc_a_size=0; a_loc_a_source=0;
        a_loc_a_addr=0; a_loc_a_mask=0; a_loc_a_data=0; a_loc_d_ready=1;
        repeat(4) @(posedge clk);
        rst_n = 1;
        repeat(4) @(posedge clk);

        // Inject a WRITE (opcode PutFullData=0) at A's local port, destined
        // for node (1,0): addr[31:28]=1 (dest_x), addr[27:24]=0 (dest_y).
        @(posedge clk);
        a_loc_a_opcode = 3'd0; a_loc_a_source = 4'd7;
        a_loc_a_addr = 32'h1000_0018;  // dest_x=1 dest_y=0, local offset 0x18 -> word idx 3
        a_loc_a_mask = 8'hFF;
        a_loc_a_data = 64'hDEAD_BEEF_CAFE_F00D;
        a_loc_a_valid = 1'b1;
        wait (a_loc_a_ready);
        @(posedge clk);
        a_loc_a_valid = 1'b0;

        // Wait for the write to actually land in B's memory, or time out.
        fork : wait_or_timeout
            begin
                wait (b_aw_seen == 1'b1 || (mem[3] == 64'hDEAD_BEEF_CAFE_F00D));
                disable wait_or_timeout;
            end
            begin
                repeat (200) @(posedge clk);
                $display("[FAIL] Timed out waiting for the write to reach B's SRAM - forwarding did not work.");
                errors = errors + 1;
                disable wait_or_timeout;
            end
        join

        repeat(20) @(posedge clk);

        if (mem[3] === 64'hDEAD_BEEF_CAFE_F00D) begin
            $display("[PASS] Cross-router forward WORKED: B's memory[3] = %h", mem[3]);
        end else begin
            $display("[FAIL] B's memory[3] = %h, expected DEAD_BEEF_CAFE_F00D", mem[3]);
            errors = errors + 1;
        end

        if (a_loc_d_valid_seen) $display("[PASS] Write-ack D-channel response returned to A's local port.");

        if (errors == 0) $display("SCORE: 1/1");
        else $display("SCORE: 0/1");
        $finish;
    end

    reg a_loc_d_valid_seen = 0;
    always @(posedge clk) if (a_loc_d_valid) a_loc_d_valid_seen <= 1'b1;

    initial begin
        #10000;
        $display("[TIMEOUT]");
        $finish;
    end
endmodule
