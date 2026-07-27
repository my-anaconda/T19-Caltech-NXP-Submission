`timescale 1ns/1ps
// Custom testbench for the medium-tier (noc_aes_soc) "irq_id_order"
// category (T1201-T1202) - the twelfth and final medium-tier category.
// Distinct from irq_agg's own T503 (which checks the simultaneous-
// pending case once): this specifically checks the ORDER contract holds
// as sources come and go - both pending resolves to the lowest id, and
// after servicing/clearing that lowest one, the id correctly moves to
// the next still-pending source rather than going stale or clearing
// everything.
module tb_medium_irq_id_order;
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

    task run_aes0;
        integer i;
        begin
            aes0_key_in = KEY; aes0_key_valid = 1'b1;
            aes0_data_in = PTEXT; aes0_start = 1'b0;
            @(posedge clk);
            aes0_start = 1'b1;
            @(posedge clk);
            aes0_start = 1'b0; aes0_key_valid = 1'b0;
            for (i = 0; i < 15; i = i + 1) begin
                @(posedge clk);
                if (aes0_done) i = 15;
            end
        end
    endtask

    task run_aes1;
        integer i;
        begin
            aes1_key_in = KEY; aes1_key_valid = 1'b1;
            aes1_data_in = PTEXT; aes1_start = 1'b0;
            @(posedge clk);
            aes1_start = 1'b1;
            @(posedge clk);
            aes1_start = 1'b0; aes1_key_valid = 1'b0;
            for (i = 0; i < 15; i = i + 1) begin
                @(posedge clk);
                if (aes1_done) i = 15;
            end
        end
    endtask

    // Clears only src[0] (aes0)'s pending bit, leaving src[1] untouched.
    task irq_agg_clear_src0;
        begin
            force dut.u_irq_agg.psel = 1'b1; force dut.u_irq_agg.penable = 1'b1;
            force dut.u_irq_agg.pwrite = 1'b1; force dut.u_irq_agg.paddr = 12'h014;
            force dut.u_irq_agg.pwdata = 32'h0000_0001;
            @(posedge clk);
            release dut.u_irq_agg.psel; release dut.u_irq_agg.penable;
            release dut.u_irq_agg.pwrite; release dut.u_irq_agg.paddr;
            release dut.u_irq_agg.pwdata;
            repeat (2) @(posedge clk);
        end
    endtask

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

        // ---- T1201: both sources pending simultaneously -> lowest id
        // (0, aes0) wins, per the doc's "lowest active source ID" ----
        run_aes0;
        run_aes1;
        repeat (2) @(posedge clk);
        check(cpu_irq === 1'b1 && cpu_irq_id === 3'd0, "T1201");

        // ---- T1202: after clearing ONLY src[0]'s pending bit (aes0
        // serviced), the id correctly moves on to src[1] (aes1), which
        // is still genuinely pending - not stuck at 0, and not cleared
        // to idle either ----
        irq_agg_clear_src0;
        check(cpu_irq === 1'b1 && cpu_irq_id === 3'd1, "T1202");

        if (errors == 0) $display("IRQ_ID_ORDER SCORE: 2/2");
        else $display("IRQ_ID_ORDER SCORE: %0d/2", 2 - errors);
        $finish;
    end

    initial begin
        #150000;
        $display("[TIMEOUT]");
        $finish;
    end
endmodule
