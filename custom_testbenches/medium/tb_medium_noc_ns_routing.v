`timescale 1ns/1ps
// Custom testbench for the medium-tier (noc_aes_soc) "noc_ns_routing"
// category (T1001-T1005). Column x=0's North-South hops: (0,0)->(0,1)
// is 1 hop, (0,0)->(0,2) is 2 hops (through (0,1) as a pure relay, not
// itself the destination) - the real multi-hop case for this direction.
module tb_medium_noc_ns_routing;
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

        // ---- T1001: 1-hop South to (0,1) ----
        axi_write(node_addr(4'd0, 4'd1, 24'd40), 32'hDEAD_1001);
        axi_read(node_addr(4'd0, 4'd1, 24'd40), rdval);
        check(rdval === 32'hDEAD_1001, "T1001");

        // ---- T1002: 2-hop South to (0,2), through (0,1) as a pure
        // relay (not the destination) ----
        axi_write(node_addr(4'd0, 4'd2, 24'd40), 32'hDEAD_1002);
        axi_read(node_addr(4'd0, 4'd2, 24'd40), rdval);
        check(rdval === 32'hDEAD_1002, "T1002");

        // ---- T1003: the 2-hop write to (0,2) left (0,1)'s own word
        // from T1001 untouched (relaying through a node doesn't corrupt
        // that node's own local storage) ----
        axi_read(node_addr(4'd0, 4'd1, 24'd40), rdval);
        check(rdval === 32'hDEAD_1001, "T1003");

        // ---- T1004: a second write to the SAME 2-hop destination
        // overwrites cleanly (latest value wins, no stale/ghost data) ----
        axi_write(node_addr(4'd0, 4'd2, 24'd40), 32'hDEAD_1004);
        axi_read(node_addr(4'd0, 4'd2, 24'd40), rdval);
        check(rdval === 32'hDEAD_1004, "T1004");

        // ---- T1005: a different offset within (0,2)'s own SRAM,
        // reached via the same 2-hop path, is independently correct
        // (not just offset 40 happens to work) ----
        axi_write(node_addr(4'd0, 4'd2, 24'd99), 32'hDEAD_1005);
        axi_read(node_addr(4'd0, 4'd2, 24'd99), rdval);
        check(rdval === 32'hDEAD_1005, "T1005");

        if (errors == 0) $display("NOC_NS_ROUTING SCORE: 5/5");
        else $display("NOC_NS_ROUTING SCORE: %0d/5", 5 - errors);
        $finish;
    end

    initial begin
        #150000;
        $display("[TIMEOUT]");
        $finish;
    end
endmodule
