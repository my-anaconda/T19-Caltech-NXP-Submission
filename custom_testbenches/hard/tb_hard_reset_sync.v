`timescale 1ns/1ps
// Custom testbench for the hard-tier (crypto_soc) "reset_sync" category
// (T101-T105). No golden TB has been released for this track, so this
// exercises the documented reset_sync behaviour (architecture doc: "4-stage
// FF chain", async-assert/sync-deassert) directly, using the SAME
// `[PASS] T<id>` / `[FAIL] T<id>` reporting convention evaluate.py's own
// parse_results() looks for, so these results are directly comparable via
// the evaluator's own scoring once it's pointed at a real golden TB.
//
// Reset is only externally controllable via the top-level `por_n` pin
// (wdt_rst_n is tied internally inside crypto_soc.v, not exposed) -
// `dut.sys_rst_n` is used to observe the synchronizer's own internal
// output directly (a plain top-level wire one level below `dut`, not a
// deep/fragile hierarchical reach), since that's the only way to verify
// the *synchronizer's own* stage-count/async-assert behaviour rather than
// just its downstream side-effects.
module tb_hard_reset_sync;
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
        por_n = 1'b0;

        // ---- T101: cold power-up takes exactly STAGES=4 clk cycles from
        // the cycle after por_n releases until sys_rst_n asserts high ----
        repeat (3) @(posedge clk);
        @(negedge clk);
        por_n = 1'b1;   // release well clear of any posedge, avoids a race
        cnt = 0;
        begin : t101_outer
            while (1) begin
                @(posedge clk); #1;   // #1 lets the DUT's NBA chain update settle before sampling
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

        // ---- T102: async ASSERT - sys_rst_n drops immediately (same sim
        // time, not waiting for a clock edge) when por_n drops mid-cycle ----
        @(posedge clk); #3;               // land deliberately off-edge
        por_n = 1'b0;
        #1;                                // let the async always-block settle
        check(dut.sys_rst_n === 1'b0, "T102");

        // ---- T103: re-triggerability - a second release also takes
        // exactly 4 cycles, not stuck or mistimed after a prior cycle ----
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

        // ---- T104: stability - sys_rst_n stays low with zero glitches for
        // an extended por_n-low window (not just a momentary dip) ----
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

        // ---- T105: end-to-end integration - after releasing reset, a real
        // CPU write to MBOX_DATA (0xF001_0000) actually takes effect
        // (top-level mbox_empty pin, not an internal register bit, so this
        // only depends on the documented port contract) ----
        @(negedge clk);
        por_n = 1'b1;
        while (dut.sys_rst_n !== 1'b1) @(posedge clk);
        repeat (4) @(posedge clk);
        axi_write(32'hF001_0000, 32'hDEAD_0105);
        repeat (5) @(posedge clk);
        check(mbox_empty === 1'b0, "T105");

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
