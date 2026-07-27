`timescale 1ns/1ps
// Custom testbench for the medium-tier (noc_aes_soc) "reset_sync" category
// (T101-T105). Mirrors tb_hard_reset_sync.v's approach: the architecture
// doc's own diagram shows the same 4-FF chain as the hard tier
// ("Determine the number of synchronizer stages from the structure of the
// diagram" - 4 FF boxes drawn), so this hardcodes the expected 4-cycle
// release latency and treats any deviation as a real bug, not a
// regeneration-to-regeneration style choice.
module tb_medium_reset_sync;
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
    integer cnt;

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

    initial begin
        cpu_awaddr=0; cpu_awvalid=0; cpu_wdata=0; cpu_wstrb=0; cpu_wvalid=0; cpu_bready=0;
        cpu_araddr=0; cpu_arvalid=0; cpu_rready=0;
        aes0_key_in=0; aes0_key_valid=0; aes0_data_in=0; aes0_start=0;
        aes1_key_in=0; aes1_key_valid=0; aes1_data_in=0; aes1_start=0;
        por_n = 1'b0;

        // ---- T101: cold power-up takes exactly 4 clk cycles from the
        // cycle after por_n releases until sys_rst_n asserts high ----
        repeat (3) @(posedge clk);
        @(negedge clk);
        por_n = 1'b1;
        cnt = 0;
        begin : t101_outer
            while (1) begin
                @(posedge clk); #1;
                cnt = cnt + 1;
                if (dut.sys_rst_n === 1'b1) disable t101_outer;
                if (cnt > 20) begin
                    $display("[FAIL] T101 (timed out waiting for sys_rst_n)");
                    errors = errors + 1;
                    disable t101_outer;
                end
            end
        end
        if (cnt <= 20) check(cnt == 4, "T101");

        repeat (10) @(posedge clk);

        // ---- T102: async ASSERT - sys_rst_n drops immediately when
        // por_n drops mid-cycle ----
        @(posedge clk); #3;
        por_n = 1'b0;
        #1;
        check(dut.sys_rst_n === 1'b0, "T102");

        // ---- T103: re-triggerability - a second release also takes
        // exactly 4 cycles ----
        repeat (5) @(posedge clk);
        @(negedge clk);
        por_n = 1'b1;
        cnt = 0;
        begin : t103_outer
            while (1) begin
                @(posedge clk); #1;
                cnt = cnt + 1;
                if (dut.sys_rst_n === 1'b1) disable t103_outer;
                if (cnt > 20) begin
                    $display("[FAIL] T103 (timed out waiting for sys_rst_n)");
                    errors = errors + 1;
                    disable t103_outer;
                end
            end
        end
        if (cnt <= 20) check(cnt == 4, "T103");

        repeat (10) @(posedge clk);

        // ---- T104: stability - sys_rst_n stays low with zero glitches
        // for an extended por_n-low window ----
        begin : t104_block
            reg glitch_free;
            glitch_free = 1'b1;
            por_n = 1'b0;
            repeat (20) begin
                @(posedge clk);
                if (dut.sys_rst_n !== 1'b0) glitch_free = 1'b0;
            end
            check(glitch_free, "T104");
        end

        // ---- T105: end-to-end integration - after releasing reset, a
        // real CPU write to node (0,0)'s own local SRAM actually takes
        // effect (only depends on the documented port contract) ----
        @(negedge clk);
        por_n = 1'b1;
        while (dut.sys_rst_n !== 1'b1) @(posedge clk);
        repeat (4) @(posedge clk);
        axi_write(node_addr(4'd0, 4'd0, 24'd1), 32'hDEAD_0105);
        repeat (6) @(posedge clk);
        check(dut.u_noc_mesh.u_sram_00.mem[1][31:0] === 32'hDEAD_0105, "T105");

        if (errors == 0) $display("RESET_SYNC SCORE: 5/5");
        else $display("RESET_SYNC SCORE: %0d/5", 5 - errors);
        $finish;
    end

    initial begin
        #100000;
        $display("[TIMEOUT]");
        $finish;
    end
endmodule
