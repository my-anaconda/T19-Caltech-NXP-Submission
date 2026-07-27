`timescale 1ns/1ps
// Custom testbench for the hard-tier (crypto_soc) "soc_cfg_regs" category
// (T1001-T1008): the SoC Config Register Map documented at base
// 0xF001_0000 (crossbar's S2 window) - MBOX_DATA(0x00)/MBOX_STATUS(0x04)/
// PERF_CNT0..3(0x08..14)/PERF_CTRL(0x18)/reserved(0x1C..3C).
//
// Unlike apb_periph/irq_crypto/irq_periph, this block has no dedicated
// rtl_gen_lib generator at all - Step 4 hand-writes the entire S2 decode
// directly into the top-level each run, and (like the APB peripheral
// cluster's own decode in an earlier run) its structure varies a lot:
// t19_hard_test14's S2 block only actually implements offset 0x00
// (MBOX_DATA write) and 0x04 (MBOX_STATUS read) - every other
// documented offset, including ALL of PERF_CNT0..3 and PERF_CTRL,
// silently falls through to a `default: s2_rdata_reg <= 32'b0;` and a
// write that's acked (s2_bvalid fires) but goes nowhere. u_perf in that
// same run IS real and instantiated, just reachable at a completely
// different, undocumented address (an inline paddr[15:12]==7 slot in
// the S1/APB fabric window, mirroring the same ad-hoc pattern already
// seen once before in apb_periph's own investigation) rather than
// through S2 at all.
//
// This testbench tests the SoC config register CONTRACT itself against
// the real, documented 0xF001_0000 address map via the shared axi_write/
// axi_read BFM (this address space's ack timing turned out to be simple,
// standard registered handshakes - no fused-ack workaround needed, unlike
// the APB peripheral cluster's real AHB bridge).
//
// Found and fixed two real top-level bugs (both in t19_nxp_agent_final.py,
// applied as deterministic post-processing on the Step-4-generated
// top-level text - full detail in each fix function's own docstring):
//
// - fix_mbox_wr_en_pulse(): whatever drives u_mbox's wr_en port behaves
//   as a LEVEL that can stay high for more than one clock cycle (a CPU
//   master legally holding awvalid/wvalid through bvalid, exactly what
//   axi_write does) - since gen_async_fifo's write logic has no edge-
//   detection either, a single logical CPU write pushed the SAME word
//   into the mailbox multiple times (confirmed via a real trace: wr_bin
//   incremented by 2 for one axi_write call). Observed generated THREE
//   structurally different ways across regenerations (assign, inline
//   wire, and a clocked reg that still re-asserts every cycle its own
//   condition holds) - rather than keep chasing new source-expression
//   syntax, the fix wraps u_mbox's OWN .wr_en(...) port connection in a
//   fresh edge-detector, which is robust regardless of source style.
// - fix_mbox_rd_rst_n(): u_mbox's rd_rst_n port tied to a constant
//   1'b1 (never actually resetting) on one regeneration, leaving every
//   read-side register permanently 'x' - a direct violation of the
//   doc's own "wr_rst_n and rd_rst_n both = sys_rst_n".
//
// PERF_CNT0..3/PERF_CTRL (0x08..0x18) are a genuine, confirmed top-level
// gap that's NOT fixed here, seen identically on two separate
// regenerations: the S2 block simply never implements those offsets at
// all (falls through to a `default: s2_rdata_reg <= 32'b0;`, and a
// write that's acked but goes nowhere) - u_perf IS real and correctly
// instantiated, just reachable at a completely different, undocumented
// address (an inline paddr[15:12]==7 slot in the S1/APB fabric window)
// instead of through S2 at all. Unlike mbox_wr_en/rd_rst_n, there's no
// single guaranteed wire/port name to regex against here - the S2
// block's overall shape (which offsets it even attempts, and how)
// varies too much across regenerations to fix safely and generically.
//
// A THIRD top-level bug was found on yet another regeneration
// (t19_hard_test16) and is ALSO not fixed, for the same reason: that
// run's S2 read-response state machine (s2_rvalid_reg) only clears on
// `!s2_awvalid && s2_rready`, but the shared axi_read BFM only pulses
// cpu_rready briefly - so once a first read completes, s2_rvalid_reg
// gets stuck at 1 permanently, and every SUBSEQUENT read silently
// returns the FIRST read's stale captured data forever after (confirmed
// via a real trace). s2_rvalid_reg is a purely-internal, non-guaranteed
// register name with no doc-mandated identity - not a safe regex target.
// Documented in NOTES.md, same treatment as the DMA-config-bus gap.
module tb_hard_soc_cfg_regs;
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

    // Per the doc: "DSP polls mbox_empty; asserts rd_en for 1 dsp_clk".
    // dout is a combinational read of the current word (mem[rd_bin]), so
    // it must be captured BEFORE/DURING the pulse, not after (rd_bin
    // advances to the next word at the same edge rd_en is sampled high).
    task mbox_read;
        output [31:0] data;
        begin
            while (mbox_empty) @(posedge dsp_clk);
            data = mbox_dout;
            // Change mbox_rd_en at negedge, not immediately after the
            // posedge that just cleared the while loop above - the same
            // same-edge race already found and fixed for tb_hard_
            // perf_counter.v's event_N stimulus (changing a signal right
            // after @(posedge X) races that SAME edge's own active-
            // region convergence in the DUT). negedge gives a full
            // half-period of guaranteed settling margin before the next
            // posedge samples it.
            @(negedge dsp_clk);
            mbox_rd_en = 1'b1;
            @(posedge dsp_clk);
            @(negedge dsp_clk);
            mbox_rd_en = 1'b0;
        end
    endtask

    localparam [31:0] CFG_BASE = 32'hF001_0000;
    reg [31:0] rdval;
    integer i;

    initial begin
        cpu_awaddr=0; cpu_awvalid=0; cpu_wdata=0; cpu_wstrb=0; cpu_wvalid=0; cpu_bready=0;
        cpu_araddr=0; cpu_arvalid=0; cpu_rready=0;
        por_n = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk); por_n = 1'b1;
        while (dut.sys_rst_n !== 1'b1) @(posedge clk);
        repeat (4) @(posedge clk);

        // ---- T1001: MBOX_STATUS (0x04) correctly reads empty=1 before
        // anything has been pushed ----
        axi_read(CFG_BASE + 32'h004, rdval);
        check(rdval[5] === 1'b1, "T1001");

        // ---- T1002: a real MBOX_DATA (0x00) write reaches the actual
        // async mailbox FIFO - MBOX_STATUS transitions to empty=0. mbox
        // empty/full cross from the wr_clk to the rd_clk (dsp_clk) domain
        // through a 2-stage gray-code synchronizer, so this needs a
        // couple of real dsp_clk edges of settling margin before reading
        // MBOX_STATUS back, or it can still read the pre-write value ----
        axi_write(CFG_BASE + 32'h000, 32'hCAFE_0001);
        repeat (4) @(posedge dsp_clk);
        axi_read(CFG_BASE + 32'h004, rdval);
        check(rdval[5] === 1'b0, "T1002");

        // ---- T1003: the pushed word is correctly retrievable via the
        // real DSP-side interface (mbox_rd_en/mbox_dout, dsp_clk domain)
        // - proves the SoC-config write path reaches the real FIFO
        // storage, not just a fake status bit ----
        mbox_read(rdval);
        check(rdval === 32'hCAFE_0001, "T1003");

        // ---- T1004: MBOX_STATUS correctly returns to empty=1 once the
        // one pushed word has been drained (same wr_clk<->rd_clk gray-
        // code settling margin as T1002, for the read pointer this time) ----
        repeat (2) @(posedge dsp_clk);
        repeat (4) @(posedge clk);
        axi_read(CFG_BASE + 32'h004, rdval);
        check(rdval[5] === 1'b1, "T1004");

        // ---- T1005: pushing DEPTH (16) words without draining sets the
        // MBOX_STATUS full bit ----
        for (i = 0; i < 16; i = i + 1)
            axi_write(CFG_BASE + 32'h000, 32'hD000_0000 + i);
        axi_read(CFG_BASE + 32'h004, rdval);
        check(rdval[4] === 1'b1, "T1005");
        // drain it back out so later tests start from a known-empty FIFO
        for (i = 0; i < 16; i = i + 1) mbox_read(rdval);
        repeat (4) @(posedge clk);

        // ---- T1006: PERF_CNT0 (0x08) readback via the documented SoC
        // config address genuinely reflects u_perf's real cnt0 - forces
        // a real event_0 pulse directly on u_perf (same technique
        // tb_hard_perf_counter.v uses) and checks the SoC-cfg-regs read
        // path actually routes to it, rather than just checking a
        // locally-plausible value ----
        force dut.u_perf.event_0 = 1'b0;
        repeat (2) @(posedge clk);
        @(negedge clk); force dut.u_perf.event_0 = 1'b1;
        @(posedge clk);
        @(negedge clk); force dut.u_perf.event_0 = 1'b0;
        repeat (2) @(posedge clk);
        axi_read(CFG_BASE + 32'h008, rdval);
        check(rdval === dut.u_perf.cnt0, "T1006");

        // ---- T1007: PERF_CTRL (0x18) clear-all, per the doc ("Write
        // PERF_CTRL[1]=1 to clear all counters"), actually reaches
        // u_perf's own real counters ----
        axi_write(CFG_BASE + 32'h018, 32'h0000_0002);
        repeat (4) @(posedge clk);
        check(dut.u_perf.cnt0 === 32'd0, "T1007");

        // ---- T1008: a reserved offset (0x20) reads back 0, per the
        // doc ("0x1C..0x3C reserved reads 0") ----
        axi_read(CFG_BASE + 32'h020, rdval);
        check(rdval === 32'd0, "T1008");

        if (errors == 0) $display("SOC_CFG_REGS SCORE: 8/8");
        else $display("SOC_CFG_REGS SCORE: %0d/8", 8 - errors);
        $finish;
    end

    initial begin
        #400000;
        $display("[TIMEOUT]");
        $finish;
    end
endmodule
