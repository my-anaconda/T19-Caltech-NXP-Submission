`timescale 1ns/1ps
// Custom testbench for the medium-tier (noc_aes_soc) "sram_ni_idle"
// category (T601-T605). Checks that nodes NOT targeted by a transaction
// stay genuinely idle - no spurious bvalid/rvalid pulses on their own,
// and no cross-talk when a real transaction targets a DIFFERENT node.
module tb_medium_sram_ni_idle;
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

        // ---- T601: fresh out of reset, before any transaction, no node
        // spuriously asserts bvalid/rvalid on its own over an idle
        // window (all 6 nodes' SRAM+NI pairs genuinely quiet) ----
        begin : t601_block
            reg quiet;
            integer i;
            quiet = 1'b1;
            for (i = 0; i < 20; i = i + 1) begin
                @(posedge clk);
                if (dut.u_noc_mesh.u_sram_00.bvalid || dut.u_noc_mesh.u_sram_00.rvalid ||
                    dut.u_noc_mesh.u_sram_01.bvalid || dut.u_noc_mesh.u_sram_01.rvalid ||
                    dut.u_noc_mesh.u_sram_02.bvalid || dut.u_noc_mesh.u_sram_02.rvalid ||
                    dut.u_noc_mesh.u_sram_10.bvalid || dut.u_noc_mesh.u_sram_10.rvalid ||
                    dut.u_noc_mesh.u_sram_11.bvalid || dut.u_noc_mesh.u_sram_11.rvalid ||
                    dut.u_noc_mesh.u_sram_12.bvalid || dut.u_noc_mesh.u_sram_12.rvalid)
                    quiet = 1'b0;
            end
            check(quiet, "T601");
        end

        // ---- T602: a real write targeting node (0,1) does NOT cause
        // node (0,2)'s SRAM to spuriously see any activity ----
        begin : t602_block
            reg neighbor_quiet;
            integer i;
            neighbor_quiet = 1'b1;
            fork
                axi_write(node_addr(4'd0, 4'd1, 24'd5), 32'hC0DE_0602);
                begin
                    for (i = 0; i < 10; i = i + 1) begin
                        @(posedge clk);
                        if (dut.u_noc_mesh.u_sram_02.awvalid || dut.u_noc_mesh.u_sram_02.arvalid)
                            neighbor_quiet = 1'b0;
                    end
                end
            join
            check(neighbor_quiet, "T602");
        end

        // ---- T603: node (1,0)'s SRAM (co-located with aes0) stays
        // quiet while aes0 itself runs a real encryption - the AES
        // engine's own activity doesn't leak into its co-located SRAM's
        // AXI port ----
        begin : t603_block
            reg sram_quiet;
            integer i;
            sram_quiet = 1'b1;
            aes0_key_in = 128'h000102030405060708090a0b0c0d0e0f;
            aes0_key_valid = 1'b1;
            aes0_data_in = 128'h00112233445566778899aabbccddeeff;
            aes0_start = 1'b0;
            @(posedge clk);
            aes0_start = 1'b1;
            @(posedge clk);
            aes0_start = 1'b0; aes0_key_valid = 1'b0;
            for (i = 0; i < 12; i = i + 1) begin
                @(posedge clk);
                if (dut.u_noc_mesh.u_sram_10.awvalid || dut.u_noc_mesh.u_sram_10.arvalid)
                    sram_quiet = 1'b0;
            end
            check(sram_quiet, "T603");
        end

        // ---- T604: after T602/T603's activity, node (0,1)'s own write
        // is still correctly readable back (nothing corrupted by the
        // neighbor/AES activity happening concurrently) ----
        axi_read(node_addr(4'd0, 4'd1, 24'd5), rdval);
        check(rdval === 32'hC0DE_0602, "T604");

        // ---- T605: a full idle window AFTER all activity settles shows
        // no residual/stuck activity anywhere (everything correctly
        // returned to quiescent) ----
        begin : t605_block
            reg quiet;
            integer i;
            quiet = 1'b1;
            for (i = 0; i < 15; i = i + 1) begin
                @(posedge clk);
                if (dut.u_noc_mesh.u_sram_00.bvalid || dut.u_noc_mesh.u_sram_01.bvalid ||
                    dut.u_noc_mesh.u_sram_02.bvalid || dut.u_noc_mesh.u_sram_10.bvalid ||
                    dut.u_noc_mesh.u_sram_11.bvalid || dut.u_noc_mesh.u_sram_12.bvalid)
                    quiet = 1'b0;
            end
            check(quiet, "T605");
        end

        if (errors == 0) $display("SRAM_NI_IDLE SCORE: 5/5");
        else $display("SRAM_NI_IDLE SCORE: %0d/5", 5 - errors);
        $finish;
    end

    initial begin
        #150000;
        $display("[TIMEOUT]");
        $finish;
    end
endmodule
