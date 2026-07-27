`timescale 1ns/1ps
// Custom testbench for the medium-tier (noc_aes_soc) "noc_topology" category
// (T201-T205). The doc's own "Node Inventory" table lists exactly 5 nodes
// other than the CPU's own entry point (0,0): (0,1), (0,2), (1,0), (1,1),
// (1,2) - one check per node, confirming basic reachability/connectivity
// to every node in the mesh at least once via a real CPU write+readback.
// Deeper routing-direction-specific behavior (E-W only, N-S only, 2-hop)
// is covered by the later noc_ew_routing/noc_ns_routing/noc_2hop
// categories - this one is a broad first-pass survey.
module tb_medium_noc_topology;
    reg clk = 0, por_n;
    always #5 clk = ~clk;

    reg  [31:0] cpu_awaddr;  reg  cpu_awvalid; wire cpu_awready;
    reg  [63:0] cpu_wdata;   reg  [7:0] cpu_wstrb;
    reg         cpu_wvalid;  wire cpu_wready;
    wire [1:0]  cpu_bresp;   wire cpu_bvalid;  reg  cpu_bready;
    reg  [31:0] cpu_araddr;  reg  cpu_arvalid; wire cpu_arready;
    wire [63:0] cpu_rdata;   wire [1:0] cpu_rresp;
    wire        cpu_rvalid;  reg  cpu_rready;
    reg  [127:0] aes0_key_in; reg aes0_key_valid; reg [127:0] aes0_data_in; reg aes0_start;
    wire [127:0] aes0_data_out; wire aes0_done; wire aes0_busy;
    reg  [127:0] aes1_key_in; reg aes1_key_valid; reg [127:0] aes1_data_in; reg aes1_start;
    wire [127:0] aes1_data_out; wire aes1_done; wire aes1_busy;
    wire cpu_irq; wire [2:0] cpu_irq_id;

    noc_aes_soc dut (
        .clk(clk), .por_n(por_n),
        .cpu_awaddr(cpu_awaddr), .cpu_awvalid(cpu_awvalid), .cpu_awready(cpu_awready),
        .cpu_wdata(cpu_wdata), .cpu_wstrb(cpu_wstrb), .cpu_wvalid(cpu_wvalid), .cpu_wready(cpu_wready),
        .cpu_bresp(cpu_bresp), .cpu_bvalid(cpu_bvalid), .cpu_bready(cpu_bready),
        .cpu_araddr(cpu_araddr), .cpu_arvalid(cpu_arvalid), .cpu_arready(cpu_arready),
        .cpu_rdata(cpu_rdata), .cpu_rresp(cpu_rresp), .cpu_rvalid(cpu_rvalid), .cpu_rready(cpu_rready),
        .aes0_key_in(aes0_key_in), .aes0_key_valid(aes0_key_valid),
        .aes0_data_in(aes0_data_in), .aes0_start(aes0_start),
        .aes0_data_out(aes0_data_out), .aes0_done(aes0_done), .aes0_busy(aes0_busy),
        .aes1_key_in(aes1_key_in), .aes1_key_valid(aes1_key_valid),
        .aes1_data_in(aes1_data_in), .aes1_start(aes1_start),
        .aes1_data_out(aes1_data_out), .aes1_done(aes1_done), .aes1_busy(aes1_busy),
        .cpu_irq(cpu_irq), .cpu_irq_id(cpu_irq_id)
    );

`include "tb_medium_common.vh"

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

    reg [31:0] rdval;

    initial begin
        cpu_awaddr=0; cpu_awvalid=0; cpu_wdata=0; cpu_wstrb=0; cpu_wvalid=0; cpu_bready=0;
        cpu_araddr=0; cpu_arvalid=0; cpu_rready=0;
        aes0_key_in=0; aes0_key_valid=0; aes0_data_in=0; aes0_start=0;
        aes1_key_in=0; aes1_key_valid=0; aes1_data_in=0; aes1_start=0;
        por_n = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk); por_n = 1'b1;
        while (dut.sys_rst_n !== 1'b1) @(posedge clk);
        repeat (4) @(posedge clk);

        // ---- T201: node (0,1) reachable and writable/readable ----
        axi_write(node_addr(4'd0, 4'd1, 24'd1), 32'hA0B1_0201);
        axi_read(node_addr(4'd0, 4'd1, 24'd1), rdval);
        check(rdval === 32'hA0B1_0201, "T201");

        // ---- T202: node (0,2) ----
        axi_write(node_addr(4'd0, 4'd2, 24'd1), 32'hA0B1_0202);
        axi_read(node_addr(4'd0, 4'd2, 24'd1), rdval);
        check(rdval === 32'hA0B1_0202, "T202");

        // ---- T203: node (1,0) - co-located with aes0, SRAM still works ----
        axi_write(node_addr(4'd1, 4'd0, 24'd1), 32'hA0B1_0203);
        axi_read(node_addr(4'd1, 4'd0, 24'd1), rdval);
        check(rdval === 32'hA0B1_0203, "T203");

        // ---- T204: node (1,1) - co-located with aes1, SRAM still works ----
        axi_write(node_addr(4'd1, 4'd1, 24'd1), 32'hA0B1_0204);
        axi_read(node_addr(4'd1, 4'd1, 24'd1), rdval);
        check(rdval === 32'hA0B1_0204, "T204");

        // ---- T205: node (1,2) - the mesh's far corner ----
        axi_write(node_addr(4'd1, 4'd2, 24'd1), 32'hA0B1_0205);
        axi_read(node_addr(4'd1, 4'd2, 24'd1), rdval);
        check(rdval === 32'hA0B1_0205, "T205");

        if (errors == 0) $display("NOC_TOPOLOGY SCORE: 5/5");
        else $display("NOC_TOPOLOGY SCORE: %0d/5", 5 - errors);
        $finish;
    end

    initial begin
        #150000;
        $display("[TIMEOUT]");
        $finish;
    end
endmodule
