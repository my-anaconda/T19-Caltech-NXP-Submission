`timescale 1ns/1ps
// Custom testbench for the medium-tier (noc_aes_soc) "noc_ew_routing"
// category (T901-T905). Column x=0 (CPU's own column) to column x=1
// (AES column) is the mesh's only East-West hop - one check per
// destination row, plus a back-to-back stress check and an isolation
// check confirming East-routed traffic doesn't disturb the CPU's own
// local node.
module tb_medium_noc_ew_routing;
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

        // preload the local node so T905's isolation check has a known
        // baseline to compare against
        axi_write(node_addr(4'd0, 4'd0, 24'd30), 32'hE0E0_0000);

        // ---- T901: East hop to (1,0) ----
        axi_write(node_addr(4'd1, 4'd0, 24'd1), 32'hE0E0_0901);
        axi_read(node_addr(4'd1, 4'd0, 24'd1), rdval);
        check(rdval === 32'hE0E0_0901, "T901");

        // ---- T902: East hop to (1,1) ----
        axi_write(node_addr(4'd1, 4'd1, 24'd1), 32'hE0E0_0902);
        axi_read(node_addr(4'd1, 4'd1, 24'd1), rdval);
        check(rdval === 32'hE0E0_0902, "T902");

        // ---- T903: East hop to (1,2) ----
        axi_write(node_addr(4'd1, 4'd2, 24'd1), 32'hE0E0_0903);
        axi_read(node_addr(4'd1, 4'd2, 24'd1), rdval);
        check(rdval === 32'hE0E0_0903, "T903");

        // ---- T904: back-to-back writes to TWO different East nodes
        // don't corrupt each other (real single-outstanding-transaction
        // router correctly serializes rather than confusing state) ----
        axi_write(node_addr(4'd1, 4'd0, 24'd2), 32'hE0E0_0904);
        axi_write(node_addr(4'd1, 4'd1, 24'd2), 32'hE0E0_0905);
        begin : t904_block
            reg both_ok;
            both_ok = 1'b1;
            axi_read(node_addr(4'd1, 4'd0, 24'd2), rdval);
            if (rdval !== 32'hE0E0_0904) both_ok = 1'b0;
            axi_read(node_addr(4'd1, 4'd1, 24'd2), rdval);
            if (rdval !== 32'hE0E0_0905) both_ok = 1'b0;
            check(both_ok, "T904");
        end

        // ---- T905: all that East-routed traffic left the CPU's own
        // local node (0,0) completely untouched ----
        axi_read(node_addr(4'd0, 4'd0, 24'd30), rdval);
        check(rdval === 32'hE0E0_0000, "T905");

        if (errors == 0) $display("NOC_EW_ROUTING SCORE: 5/5");
        else $display("NOC_EW_ROUTING SCORE: %0d/5", 5 - errors);
        $finish;
    end

    initial begin
        #150000;
        $display("[TIMEOUT]");
        $finish;
    end
endmodule
