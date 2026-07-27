`timescale 1ns/1ps
// Custom testbench for the medium-tier (noc_aes_soc) "aes1_encrypt"
// category (T401-T405). Mirrors tb_medium_aes0_encrypt.v for the second
// engine (node 1,1) - same direct top-level port interface, same NIST
// FIPS-197 test vector. T405 checks aes1_done reaches src[1] (id=1),
// distinguishing it from aes0's id=0.
module tb_medium_aes1_encrypt;
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

    localparam [127:0] KEY   = 128'h000102030405060708090a0b0c0d0e0f;
    localparam [127:0] PTEXT = 128'h00112233445566778899aabbccddeeff;
    localparam [127:0] CTEXT = 128'h69c4e0d86a7b0430d8cdb78070b4c55a;

    task run_aes1;
        output        busy_seen;
        output [127:0] result;
        integer i;
        begin
            busy_seen = 1'b0;
            aes1_key_in = KEY; aes1_key_valid = 1'b1;
            aes1_data_in = PTEXT; aes1_start = 1'b0;
            @(posedge clk);
            aes1_start = 1'b1;
            @(posedge clk);
            aes1_start = 1'b0; aes1_key_valid = 1'b0;
            for (i = 0; i < 15; i = i + 1) begin
                @(posedge clk);
                if (aes1_busy) busy_seen = 1'b1;
                if (aes1_done) begin
                    result = aes1_data_out;
                    i = 15;
                end
            end
        end
    endtask

    reg busy_seen;
    reg [127:0] result;

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

        // ---- T401: real AES-128 encryption via the direct top-level
        // port, checked against the NIST FIPS-197 test vector ----
        run_aes1(busy_seen, result);
        check(result === CTEXT, "T401");

        // ---- T402: busy was observed high during the computation ----
        check(busy_seen === 1'b1, "T402");

        // ---- T403: done returns to 0 the cycle after asserting ----
        repeat (2) @(posedge clk);
        check(aes1_done === 1'b0, "T403");

        // ---- T404: a second back-to-back encryption also correct ----
        run_aes1(busy_seen, result);
        check(result === CTEXT, "T404");

        // ---- T405: aes1_done correctly reaches cpu_irq/cpu_irq_id
        // (src[1], id=1) - distinct from aes0's id=0 ----
        repeat (2) @(posedge clk);
        check(cpu_irq === 1'b1 && cpu_irq_id === 3'd1, "T405");

        if (errors == 0) $display("AES1_ENCRYPT SCORE: 5/5");
        else $display("AES1_ENCRYPT SCORE: %0d/5", 5 - errors);
        $finish;
    end

    initial begin
        #100000;
        $display("[TIMEOUT]");
        $finish;
    end
endmodule
