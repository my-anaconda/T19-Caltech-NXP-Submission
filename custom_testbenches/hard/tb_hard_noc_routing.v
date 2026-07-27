`timescale 1ns/1ps
// Custom testbench for the hard-tier (crypto_soc) "noc_routing" category
// (T301-T310): CPU-initiated writes to REMOTE nodes, exercising real
// multi-hop XY routing through the mesh - not just node (0,0) local
// delivery (that's noc_local). This is the category that directly
// exercises the router forwarding fix from earlier in this project.
//
// Per the architecture doc's XY routing rule: addr[31:28]=dest_x,
// addr[27:24]=dest_y; hop East/West until dest_x matches, then hop
// toward dest_y, then deliver locally. Per this generator's own
// (internally self-consistent, see NOTES.md) convention: dest_y >
// NODE_Y -> "go North" (p0) -> wired to the neighbour at y+1.
//
// Per the doc's own "D-channel limitation" callout: D-channel replies
// only return to the local inject port of the node where the request
// was ACCEPTED (always the CPU's own node (0,0) for CPU-originated
// traffic) - not to the remote destination's own local port. This is
// naturally satisfied by this router's own `origin` tracking (already
// proven by the 2-hop router-only testbench), so a write's ack SHOULD
// correctly return to the CPU regardless of hop count - this category
// verifies that end-to-end, not just that the data lands.
module tb_hard_noc_routing;
    reg clk = 0, dsp_clk = 0, por_n;
    always #5 clk = ~clk;
    always #7 dsp_clk = ~dsp_clk;

    reg  [31:0] cpu_awaddr;  reg  cpu_awvalid; wire cpu_awready;
    reg  [31:0] cpu_wdata;   reg  [3:0] cpu_wstrb;
    reg         cpu_wvalid;  wire cpu_wready;
    wire [1:0]  cpu_bresp;   wire cpu_bvalid;  reg  cpu_bready;
    reg  [31:0] cpu_araddr;  reg  cpu_arvalid; wire cpu_arready;
    wire [31:0] cpu_rdata;   wire [1:0] cpu_rresp;
    wire        cpu_rvalid;  reg  cpu_rready;
    wire [15:0] gpio0_pad;
    wire [7:0]  gpio1_pad;
    reg         uart_rx = 1'b1;
    wire        uart_tx;
    wire        cpu_crypto_irq; wire [2:0] cpu_crypto_irq_id;
    wire        cpu_periph_irq; wire [2:0] cpu_periph_irq_id;
    wire [31:0] mbox_dout;
    reg         mbox_rd_en = 1'b0;
    wire        mbox_empty;

    crypto_soc dut (
        .clk(clk), .por_n(por_n), .dsp_clk(dsp_clk),
        .cpu_awaddr(cpu_awaddr), .cpu_awvalid(cpu_awvalid), .cpu_awready(cpu_awready),
        .cpu_wdata(cpu_wdata), .cpu_wstrb(cpu_wstrb), .cpu_wvalid(cpu_wvalid), .cpu_wready(cpu_wready),
        .cpu_bresp(cpu_bresp), .cpu_bvalid(cpu_bvalid), .cpu_bready(cpu_bready),
        .cpu_araddr(cpu_araddr), .cpu_arvalid(cpu_arvalid), .cpu_arready(cpu_arready),
        .cpu_rdata(cpu_rdata), .cpu_rresp(cpu_rresp), .cpu_rvalid(cpu_rvalid), .cpu_rready(cpu_rready),
        .gpio0_pad(gpio0_pad), .gpio1_pad(gpio1_pad),
        .uart_rx(uart_rx), .uart_tx(uart_tx),
        .cpu_crypto_irq(cpu_crypto_irq), .cpu_crypto_irq_id(cpu_crypto_irq_id),
        .cpu_periph_irq(cpu_periph_irq), .cpu_periph_irq_id(cpu_periph_irq_id),
        .mbox_dout(mbox_dout), .mbox_rd_en(mbox_rd_en), .mbox_empty(mbox_empty)
    );

`include "tb_hard_common.vh"

    integer errors = 0;

    task check;
        input        cond;
        input [79:0] tid;
        begin
            if (cond) $display("[PASS] %0s", tid);
            else begin
                $display("[FAIL] %0s", tid);
                errors = errors + 1;
            end
        end
    endtask

    // addr encoding: dest_x=addr[31:28], dest_y=addr[27:24], word index
    // in the low bits (matches u_noc_local's convention, same SRAM depth).
    function [31:0] node_addr;
        input [3:0] dx;
        input [3:0] dy;
        input [7:0] word;
        node_addr = {dx, dy, 16'b0, word};
    endfunction

    initial begin
        cpu_awaddr=0; cpu_awvalid=0; cpu_wdata=0; cpu_wstrb=0; cpu_wvalid=0; cpu_bready=0;
        cpu_araddr=0; cpu_arvalid=0; cpu_rready=0;
        por_n = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk); por_n = 1'b1;
        while (dut.sys_rst_n !== 1'b1) @(posedge clk);
        repeat (4) @(posedge clk);

        // ---- T301: 1 hop East - node (1,0) ----
        axi_write(node_addr(1, 0, 1), 32'hA301_0001);
        repeat (5) @(posedge clk);
        check(dut.u_noc_mesh.u_sram_10.mem[1][31:0] === 32'hA301_0001, "T301");

        // ---- T302: 2 hops East - node (2,0) ----
        axi_write(node_addr(2, 0, 2), 32'hA302_0002);
        repeat (5) @(posedge clk);
        check(dut.u_noc_mesh.u_sram_20.mem[2][31:0] === 32'hA302_0002, "T302");

        // ---- T303: 3 hops East - node (3,0), mesh edge in X ----
        axi_write(node_addr(3, 0, 3), 32'hA303_0003);
        repeat (5) @(posedge clk);
        check(dut.u_noc_mesh.u_sram_30.mem[3][31:0] === 32'hA303_0003, "T303");

        // ---- T304: 1 hop toward +Y - node (0,1) ----
        axi_write(node_addr(0, 1, 4), 32'hA304_0004);
        repeat (5) @(posedge clk);
        check(dut.u_noc_mesh.u_sram_01.mem[4][31:0] === 32'hA304_0004, "T304");

        // ---- T305: 2 hops toward +Y - node (0,2), mesh edge in Y ----
        axi_write(node_addr(0, 2, 5), 32'hA305_0005);
        repeat (5) @(posedge clk);
        check(dut.u_noc_mesh.u_sram_02.mem[5][31:0] === 32'hA305_0005, "T305");

        // ---- T306: X-then-Y, node (1,1) - the doc's own worked example ----
        axi_write(node_addr(1, 1, 6), 32'hA306_0006);
        repeat (5) @(posedge clk);
        check(dut.u_noc_mesh.u_sram_11.mem[6][31:0] === 32'hA306_0006, "T306");

        // ---- T307: opposite corner, node (3,2) - maximal hop count ----
        axi_write(node_addr(3, 2, 7), 32'hA307_0007);
        repeat (8) @(posedge clk);
        check(dut.u_noc_mesh.u_sram_32.mem[7][31:0] === 32'hA307_0007, "T307");

        // ---- T308: a different interior node, (2,1) ----
        axi_write(node_addr(2, 1, 8), 32'hA308_0008);
        repeat (5) @(posedge clk);
        check(dut.u_noc_mesh.u_sram_21.mem[8][31:0] === 32'hA308_0008, "T308");

        // ---- T309: back-to-back writes to two DIFFERENT remote nodes
        // don't interfere with each other (no cross-node aliasing) ----
        axi_write(node_addr(1, 0, 9), 32'hA309_AAAA);
        axi_write(node_addr(2, 0, 9), 32'hA309_BBBB);
        repeat (5) @(posedge clk);
        check(dut.u_noc_mesh.u_sram_10.mem[9][31:0] === 32'hA309_AAAA &&
              dut.u_noc_mesh.u_sram_20.mem[9][31:0] === 32'hA309_BBBB, "T309");

        // ---- T310: the write-ack (bvalid) for a MAXIMUM-hop-count write
        // (opposite corner) correctly returns all the way back to the CPU
        // - not just that the data lands, but that the D-channel reply
        // survives the full round trip through every intermediate router ----
        begin : t310_block
            reg [31:0] wait_cnt;
            wait_cnt = 0;
            @(posedge clk);
            cpu_awaddr = node_addr(3, 2, 10); cpu_awvalid = 1'b1;
            cpu_wdata = 32'hA310_FEED; cpu_wstrb = 4'hF; cpu_wvalid = 1'b1;
            cpu_bready = 1'b1;
            while (!(cpu_awready && cpu_wready)) @(posedge clk);
            while (!cpu_bvalid) begin
                @(posedge clk);
                wait_cnt = wait_cnt + 1;
                if (wait_cnt > 100) begin
                    check(1'b0, "T310");
                    disable t310_block;
                end
            end
            cpu_awvalid = 1'b0; cpu_wvalid = 1'b0;
            @(posedge clk);
            cpu_bready = 1'b0;
            repeat (3) @(posedge clk);
            check(dut.u_noc_mesh.u_sram_32.mem[10][31:0] === 32'hA310_FEED, "T310");
        end

        if (errors == 0) $display("NOC_ROUTING SCORE: 10/10");
        else $display("NOC_ROUTING SCORE: %0d/10", 10 - errors);
        $finish;
    end

    initial begin
        #150000;
        $display("[TIMEOUT]");
        $finish;
    end
endmodule
