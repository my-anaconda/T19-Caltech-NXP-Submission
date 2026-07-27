`timescale 1ns/1ps
// Custom testbench for the medium-tier (noc_aes_soc) "noc_local_loop"
// category (T801-T805). Repeated local read/write stress at the CPU's
// own entry node (0,0), plus the doc's two required boundary tie-off
// wires (tie_00_p1_a_valid, tie_02_p0_a_valid - both nodes are on the
// mesh boundary in that direction and must be held at 0).
module tb_medium_noc_local_loop;
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
    integer i;

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

        // ---- T801: single local write+readback at (0,0) ----
        axi_write(node_addr(4'd0, 4'd0, 24'd10), 32'hC00D_0801);
        axi_read(node_addr(4'd0, 4'd0, 24'd10), rdval);
        check(rdval === 32'hC00D_0801, "T801");

        // ---- T802: a DIFFERENT offset at the same node, doesn't
        // clobber T801's word ----
        axi_write(node_addr(4'd0, 4'd0, 24'd11), 32'hC00D_0802);
        axi_read(node_addr(4'd0, 4'd0, 24'd11), rdval);
        check(rdval === 32'hC00D_0802, "T802");
        axi_read(node_addr(4'd0, 4'd0, 24'd10), rdval);
        check(rdval === 32'hC00D_0801, "T803");

        // ---- T804: 8 sequential back-to-back local writes to distinct
        // offsets, all correctly retained (loopback stress) ----
        begin : t804_block
            reg all_ok;
            all_ok = 1'b1;
            for (i = 0; i < 8; i = i + 1)
                axi_write(node_addr(4'd0, 4'd0, 24'd20 + i), 32'hC00D_0000 + i);
            for (i = 0; i < 8; i = i + 1) begin
                axi_read(node_addr(4'd0, 4'd0, 24'd20 + i), rdval);
                if (rdval !== (32'hC00D_0000 + i)) all_ok = 1'b0;
            end
            check(all_ok, "T804");
        end

        // ---- T805: the doc's two required boundary tie-off wires are
        // both held at 0 (node (0,2)'s North port and node (0,0)'s South
        // port both have no neighbour in that direction) ----
        check(dut.tie_02_p0_a_valid === 1'b0 && dut.tie_00_p1_a_valid === 1'b0, "T805");

        if (errors == 0) $display("NOC_LOCAL_LOOP SCORE: 5/5");
        else $display("NOC_LOCAL_LOOP SCORE: %0d/5", 5 - errors);
        $finish;
    end

    initial begin
        #150000;
        $display("[TIMEOUT]");
        $finish;
    end
endmodule
