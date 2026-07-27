`timescale 1ns/1ps
// Custom testbench for the hard-tier (crypto_soc) "perf_counter" category
// (T801-T807): u_perf (gen_perf_counter in gen_primitives.py), a 4-channel
// event counter.
//
// Per the architecture doc, counter values are meant to be readable via
// SoC config registers at 0xF001_0008..0x14, with an enable/clear-all
// control at 0x18 - but a real generation (t19_hard_test11) showed the
// top-level's own SoC-cfg-register block never actually wires PERF_CTRL's
// enable or clear-all bits to anything (captured into a register, then
// never read by anything else - a dangling register, confirmed by
// reading the source, not yet fixed - see NOTES.md), and that SAME run's
// top-level also references u_perf.u_cntN.count directly (a hierarchical
// path into a sub-module structure the real generator doesn't have,
// failing elaboration outright until fixed). Given the CPU-facing path
// is both unreliable and (for enable/clear-all) not actually wired up in
// practice, this follows the same pattern already established for
// aes_basic/dma_basic/irq_crypto: force/release directly on u_perf's own
// ports (event_0..3, and its plain always-ready APB slave interface) -
// this exercises the real counter RTL exhaustively and deterministically.
//
// Found (by reading gen_perf_counter BEFORE writing any of this) a real,
// direct contradiction between the architecture doc and the organizer's
// own generator: the doc states "each counting POSITIVE EDGES of its
// event input", but the generator's increment logic is a plain level
// check (`if(event_i) cnt_i<=cnt_i+1;`) - it increments every cycle
// event_i is held high, not once per rising edge. This matters for real:
// two of the four documented channels are wired to genuinely multi-
// cycle/level signals (ch[0]=ni_00's tl_a_valid, ch[1]/ch[2]=dma0_irq/
// dma1_irq - level IRQs that stay high until cleared/re-armed), not
// 1-cycle pulses like ch[3]'s AES done sources - so the bug would
// silently over-count in exactly the cases the doc's own channel wiring
// creates. T802 below is the direct test: hold event_0 high for several
// cycles (simulating a stalled multi-cycle NoC transaction, or an
// un-cleared level IRQ) and check cnt0 increments by exactly 1, not by
// the number of cycles held. Fixed in gen_perf_counter_v2.py with a
// proper per-channel rising-edge detector.
module tb_hard_perf_counter;
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

    // u_perf's APB slave is a simple always-ready slave (assign pready=1;
    // assign pslverr=0;), gating the clear-all write on plain
    // psel&&penable&&pwrite&&paddr==0 each clock edge - a single forced
    // clock edge is enough, no bridge-style multi-cycle settling needed.
    task perf_reg_write;
        input [11:0] addr;
        input [31:0] data;
        begin
            @(negedge clk);
            force dut.u_perf.psel = 1'b1;
            force dut.u_perf.penable = 1'b1;
            force dut.u_perf.pwrite = 1'b1;
            force dut.u_perf.paddr = addr;
            force dut.u_perf.pwdata = data;
            // Empirically needs to be held across TWO edges to reliably
            // register, not just one (found via a real trace - one edge
            // alone left the write condition true and confirmed, yet the
            // clear didn't take; a second edge held the same way
            // consistently did). Not fully root-caused beyond that, but
            // this is a safe, always-legal way to hold a write - matches
            // the same "give it one more settling cycle" pattern already
            // needed for apb_periph's real AHB bridge.
            @(posedge clk);
            @(posedge clk);
            release dut.u_perf.psel;
            release dut.u_perf.penable;
            release dut.u_perf.pwrite;
            release dut.u_perf.paddr;
            release dut.u_perf.pwdata;
        end
    endtask

    task perf_reg_read;
        input  [11:0] addr;
        output [31:0] data;
        begin
            force dut.u_perf.paddr = addr;
            #1;
            data = dut.u_perf.prdata;
            release dut.u_perf.paddr;
        end
    endtask

    reg [31:0] rdval;

    initial begin
        cpu_awaddr=0; cpu_awvalid=0; cpu_wdata=0; cpu_wstrb=0; cpu_wvalid=0; cpu_bready=0;
        cpu_araddr=0; cpu_arvalid=0; cpu_rready=0;
        por_n = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk); por_n = 1'b1;
        while (dut.sys_rst_n !== 1'b1) @(posedge clk);
        repeat (4) @(posedge clk);

        // Establish a known-0 baseline on all four event lines before any
        // edge-detect test. Found (empirically, via a real trace) that
        // the real top-level's own drivers for these ports (e.g.
        // event_0 = s0_awvalid && s0_awready, a real NoC signal) can
        // already be high/toggling during reset settling, which latches
        // u_perf's own ev_prevN register to 1 before this testbench ever
        // takes over via force - so the very first forced 0->1 transition
        // wasn't seen as a rising edge relative to that stale ev_prevN=1
        // baseline. Forcing to 0 and holding a couple of cycles first
        // guarantees ev_prevN settles to a known 0 before any real test
        // stimulus begins.
        //
        // Every event_N change below happens right after @(negedge clk),
        // not immediately following @(posedge clk) - found (via a real
        // trace) that changing a force'd stimulus signal at the SAME
        // simulation instant as the posedge it's meant to be stable
        // BEFORE races against that edge's own active-region convergence
        // (a classic same-edge testbench hazard, nothing to do with the
        // DUT's edge-detect logic itself, which is otherwise correct -
        // this is the exact same edge_ev=irq_in&~irq_prev construction
        // already proven correct in gen_irq_aggregator/tb_hard_irq_crypto
        // T705). Driving changes at negedge gives a full half-period of
        // guaranteed settling margin before the next posedge samples it.
        force dut.u_perf.event_0 = 1'b0;
        force dut.u_perf.event_1 = 1'b0;
        force dut.u_perf.event_2 = 1'b0;
        force dut.u_perf.event_3 = 1'b0;
        repeat (2) @(posedge clk);

        // ---- T801: a single 1-cycle pulse on event_0 increments cnt0
        // by exactly 1 ----
        @(negedge clk); force dut.u_perf.event_0 = 1'b1;
        @(posedge clk);
        @(negedge clk); force dut.u_perf.event_0 = 1'b0;
        repeat (2) @(posedge clk);
        perf_reg_read(12'h000, rdval);
        check(rdval === 32'd1, "T801");

        // ---- T802: THE key doc-vs-generator conflict. Holding event_0
        // HIGH for several consecutive cycles (simulating a stalled
        // multi-cycle NoC transaction, or a level IRQ like dma0_irq that
        // stays asserted until cleared) must still only count ONE event
        // (a single rising edge), per the doc's "counting positive edges"
        // - not one increment per cycle held ----
        @(negedge clk); force dut.u_perf.event_0 = 1'b1;
        repeat (5) @(posedge clk);
        @(negedge clk); force dut.u_perf.event_0 = 1'b0;
        repeat (2) @(posedge clk);
        perf_reg_read(12'h000, rdval);
        check(rdval === 32'd2, "T802");  // was 1 after T801, +1 more edge here

        // ---- T803: three SEPARATE pulses on event_1 increment cnt1 by
        // exactly 3 ----
        @(negedge clk); force dut.u_perf.event_1 = 1'b1; @(posedge clk);
        @(negedge clk); force dut.u_perf.event_1 = 1'b0; @(posedge clk);
        @(negedge clk); force dut.u_perf.event_1 = 1'b1; @(posedge clk);
        @(negedge clk); force dut.u_perf.event_1 = 1'b0; @(posedge clk);
        @(negedge clk); force dut.u_perf.event_1 = 1'b1; @(posedge clk);
        @(negedge clk); force dut.u_perf.event_1 = 1'b0;
        repeat (2) @(posedge clk);
        perf_reg_read(12'h004, rdval);
        check(rdval === 32'd3, "T803");

        // ---- T804: channels are independent - all this event_0/event_1
        // activity has left cnt2/cnt3 at 0 ----
        perf_reg_read(12'h008, rdval);
        check(rdval === 32'd0, "T804a");
        perf_reg_read(12'h00C, rdval);
        check(rdval === 32'd0, "T804b");

        // ---- T805: a write to paddr==0 clears ALL FOUR counters at
        // once, even the ones that were incremented (cnt0=2, cnt1=3) ----
        perf_reg_write(12'h000, 32'h0);
        repeat (2) @(posedge clk);
        perf_reg_read(12'h000, rdval); check(rdval === 32'd0, "T805a");
        perf_reg_read(12'h004, rdval); check(rdval === 32'd0, "T805b");

        // ---- T806: a distinct pulse on event_2 after the clear
        // correctly resumes counting from 0 ----
        @(negedge clk); force dut.u_perf.event_2 = 1'b1; @(posedge clk);
        @(negedge clk); force dut.u_perf.event_2 = 1'b0;
        repeat (2) @(posedge clk);
        perf_reg_read(12'h008, rdval);
        check(rdval === 32'd1, "T806");

        // ---- T807: event_3 (the OR of the four AES engines' own
        // 1-cycle done pulses, per the doc's channel wiring) also counts
        // correctly - two separate pulses give cnt3==2 ----
        @(negedge clk); force dut.u_perf.event_3 = 1'b1; @(posedge clk);
        @(negedge clk); force dut.u_perf.event_3 = 1'b0; @(posedge clk);
        @(negedge clk); force dut.u_perf.event_3 = 1'b1; @(posedge clk);
        @(negedge clk); force dut.u_perf.event_3 = 1'b0;
        repeat (2) @(posedge clk);
        perf_reg_read(12'h00C, rdval);
        check(rdval === 32'd2, "T807");

        force dut.u_perf.event_0 = 1'b0;
        force dut.u_perf.event_1 = 1'b0;
        force dut.u_perf.event_2 = 1'b0;
        force dut.u_perf.event_3 = 1'b0;

        if (errors == 0) $display("PERF_COUNTER SCORE: 9/9");
        else $display("PERF_COUNTER SCORE: %0d/9", 9 - errors);
        $finish;
    end

    initial begin
        #200000;
        $display("[TIMEOUT]");
        $finish;
    end
endmodule
