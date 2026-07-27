`timescale 1ns/1ps
// Custom testbench for the hard-tier (crypto_soc) "integration" category
// (T1201-T1205) - the twelfth and final hard-tier category. Every prior
// category (reset_sync, noc_local/routing, aes_basic, dma_basic,
// apb_periph, irq_crypto, irq_periph, soc_cfg_regs, mailbox,
// perf_counter) exercises exactly one IP block/subsystem, mostly via
// force/release on that block's own ports directly. This category
// deliberately does the opposite: it chains MULTIPLE already-proven
// subsystems together through REAL top-level wiring, to catch bugs that
// only exist in how they interact - the exact kind of gap a per-category
// unit test structurally cannot see (e.g. the router-stubbing and
// mbox_wr_en-pulse bugs found earlier this session were both invisible
// to isolated unit tests and only surfaced once something drove the real
// end-to-end path).
//
// T1201: cold-boot-to-first-transaction - the minimum post-reset settle
//   margin (same 4-cycle convention every other category uses), then one
//   real transaction into EACH of the three crossbar-decoded address
//   regions (S0 NoC, S1 APB, S2 SoC-cfg) back-to-back, nothing residual
//   from reset interferes with any of them.
// T1202: dual-aggregator independence - a real AES0 done pulse and a
//   real GPIO0 edge-IRQ fired close together; checks BOTH cpu_crypto_irq
//   and cpu_periph_irq assert correctly and independently (no cross-talk
//   between the two separate aggregator instances, e.g. an accidental OR
//   of both outputs or one blocking the other).
// T1203: the doc's explicit fan-out claim ("aes_done ... OR-fed to
//   irq_crypto_src[0..3] AND perf ch[3]") - one real aes1 done pulse
//   must correctly reach BOTH consumers from the SAME physical event.
// T1204: a full software-driven chain - CPU programs a REMOTE
//   (multi-hop) DMA transfer, waits for the real dma0_irq via
//   cpu_crypto_irq, then (as the "software response" to that IRQ) pushes
//   the transferred value through the real SoC-cfg mailbox path and
//   confirms the DSP side reads it back - NoC + DMA + IRQ + mailbox CDC
//   all in one continuous, causally-linked sequence.
// T1205: perf ch[0]'s doc-mandated real-traffic filter ("ch[0] = ni_00
//   tl_a_valid, NoC transactions from CPU") - unlike tb_hard_perf_
//   counter.v (which forces event_0 directly, bypassing whatever really
//   drives it), this drives one real NoC transaction, one real APB
//   transaction, and one real SoC-cfg-space transaction and checks cnt0
//   increased by exactly 1 - i.e. only the genuine NoC access counted.
//
// T1203/T1205 depend on u_perf's SoC-cfg-space wiring being reachable and
// correctly rebased - the SAME known gap already documented in
// tb_hard_soc_cfg_regs.v (T1006/T1007). Two real bugs in this area were
// found and fixed via this very test (t19_hard_test25): u_perf's paddr
// reached through TWO hops of indirection instead of one (fixed by
// deepening fix_perf_paddr_rebase's own wire-chase to bounded depth 3),
// and event_0 tied to a flat constant since try_stitch_noc_mesh() hides
// ni_00's internal signals from Step 4 entirely (fixed by
// fix_perf_event0_wiring(), redirecting it to the crossbar's own
// guaranteed S0 handshake). A THIRD structural variant, found on
// t19_hard_test27, is NOT auto-fixed: u_perf reached through a MUX of
// the test14-style inline S1/APB slot AND a separate S2 path
// (`.paddr(psel_perf ? paddr[11:0] : perf_paddr)`) - blindly replacing
// psel/paddr here risks breaking the S1 branch the same way the
// existing guard was built to protect test14, so it's deliberately left
// alone. When this variant occurs, T1203/T1205 (and soc_cfg_regs'
// T1006/T1007) fail together - a real, understood, and documented gap,
// not a flaky test.
module tb_hard_integration;
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

    function [31:0] node_addr;
        input [3:0] dx;
        input [3:0] dy;
        input [7:0] word;
        node_addr = {dx, dy, 16'b0, word};
    endfunction

    localparam [31:0] CFG_BASE   = 32'hF001_0000;
    localparam [31:0] GPIO0_BASE = 32'hF000_1000;

    // Fused-ack-aware APB write, same as proven in tb_hard_apb_periph.v /
    // tb_hard_irq_periph.v.
    task apb_write;
        input [31:0] addr;
        input [31:0] data;
        begin
            @(posedge clk);
            cpu_awaddr = addr; cpu_awvalid = 1'b1;
            cpu_wdata = data; cpu_wstrb = 4'hF; cpu_wvalid = 1'b1;
            cpu_bready = 1'b1;
            @(posedge clk);
            while (!(cpu_awready && cpu_wready)) @(posedge clk);
            @(posedge clk);
            cpu_awvalid = 1'b0; cpu_wvalid = 1'b0; cpu_bready = 1'b0;
        end
    endtask

    task dma_cfg_write;
        input        which;      // 0=dma0, 1=dma1
        input [11:0] addr;
        input [31:0] data;
        begin
            @(posedge clk);
            if (which == 0) begin
                force dut.u_dma0.cfg_awaddr = addr; force dut.u_dma0.cfg_awvalid = 1'b1;
                force dut.u_dma0.cfg_wdata = data; force dut.u_dma0.cfg_wvalid = 1'b1;
            end else begin
                force dut.u_dma1.cfg_awaddr = addr; force dut.u_dma1.cfg_awvalid = 1'b1;
                force dut.u_dma1.cfg_wdata = data; force dut.u_dma1.cfg_wvalid = 1'b1;
            end
            @(posedge clk);
            if (which == 0) begin
                release dut.u_dma0.cfg_awaddr; release dut.u_dma0.cfg_awvalid;
                release dut.u_dma0.cfg_wdata; release dut.u_dma0.cfg_wvalid;
            end else begin
                release dut.u_dma1.cfg_awaddr; release dut.u_dma1.cfg_awvalid;
                release dut.u_dma1.cfg_wdata; release dut.u_dma1.cfg_wvalid;
            end
        end
    endtask

    // Same dsp-domain read task proven in tb_hard_soc_cfg_regs.v.
    task mbox_read;
        output [31:0] data;
        begin
            while (mbox_empty) @(posedge dsp_clk);
            data = mbox_dout;
            @(negedge dsp_clk);
            mbox_rd_en = 1'b1;
            @(posedge dsp_clk);
            @(negedge dsp_clk);
            mbox_rd_en = 1'b0;
        end
    endtask

    task irq_crypto_clear_all;
        begin
            force dut.u_irq_crypto.irq_src = 8'b0;
            repeat (2) @(posedge clk);
            force dut.u_irq_crypto.psel = 1'b1; force dut.u_irq_crypto.penable = 1'b1;
            force dut.u_irq_crypto.pwrite = 1'b1; force dut.u_irq_crypto.paddr = 12'h014;
            force dut.u_irq_crypto.pwdata = 32'hFFFF_FFFF;
            @(posedge clk);
            release dut.u_irq_crypto.psel; release dut.u_irq_crypto.penable;
            release dut.u_irq_crypto.pwrite; release dut.u_irq_crypto.paddr;
            release dut.u_irq_crypto.pwdata;
            release dut.u_irq_crypto.irq_src;
            repeat (2) @(posedge clk);
        end
    endtask

    task irq_periph_clear_all;
        begin
            force dut.u_irq_periph.psel = 1'b1; force dut.u_irq_periph.penable = 1'b1;
            force dut.u_irq_periph.pwrite = 1'b1; force dut.u_irq_periph.paddr = 12'h014;
            force dut.u_irq_periph.pwdata = 32'hFFFF_FFFF;
            @(posedge clk);
            release dut.u_irq_periph.psel; release dut.u_irq_periph.penable;
            release dut.u_irq_periph.pwrite; release dut.u_irq_periph.paddr;
            release dut.u_irq_periph.pwdata;
            repeat (2) @(posedge clk);
        end
    endtask

    reg [31:0] rdval, rdval2, dma_val;

    initial begin
        cpu_awaddr=0; cpu_awvalid=0; cpu_wdata=0; cpu_wstrb=0; cpu_wvalid=0; cpu_bready=0;
        cpu_araddr=0; cpu_arvalid=0; cpu_rready=0;
        por_n = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk); por_n = 1'b1;
        while (dut.sys_rst_n !== 1'b1) @(posedge clk);
        repeat (4) @(posedge clk);

        // ---- T1201: cold-boot-to-first-transaction - one real access
        // into each of the three crossbar-decoded regions (S0 NoC, S1
        // APB, S2 SoC-cfg), back-to-back, right after the minimum settle
        // margin every other category also uses ----
        // evaluate.py's parser (`re.match(r'\[(PASS|FAIL)\]\s+T(\d+)', ...)`)
        // keys results purely by the numeric id, so every check in this
        // category must be its OWN distinct T120N id (a suffixed
        // "T1201a"/"T1201b" would both collapse onto id 1201 and silently
        // discard all but the last result) - each check below combines
        // its sub-conditions with && into one id instead.
        axi_write(node_addr(0, 0, 20), 32'hB007_0001);          // S0: NoC local write
        apb_write(GPIO0_BASE + 32'h008, 32'h0000_0000);         // S1: APB write (DIR=inputs)
        axi_read(CFG_BASE + 32'h004, rdval);                    // S2: SoC-cfg read (MBOX_STATUS)
        check(dut.u_noc_mesh.u_sram_00.mem[20][31:0] === 32'hB007_0001
              && dut.gpio0_pad !== 16'bx
              && rdval[5] === 1'b1, "T1201");

        // ---- T1202: dual-aggregator independence - a real AES0 done
        // pulse and a real GPIO0 edge-IRQ, both live at once ----
        apb_write(GPIO0_BASE + 32'h01C, 32'h0000_0001);  // IPOL bit0 = rising-edge-active
        apb_write(GPIO0_BASE + 32'h018, 32'h0000_0001);  // IEDGE bit0 = edge mode
        apb_write(GPIO0_BASE + 32'h014, 32'h0000_0001);  // IEN bit0 = enabled
        force gpio0_pad[0] = 1'b0;
        repeat (2) @(posedge clk);

        force dut.u_aes0.key_in = 128'h000102030405060708090a0b0c0d0e0f;
        force dut.u_aes0.key_valid = 1'b1;
        force dut.u_aes0.data_in = 128'h00112233445566778899aabbccddeeff;
        force dut.u_aes0.start = 1'b0; force dut.u_aes0.encrypt = 1'b1;
        @(posedge clk);
        force dut.u_aes0.start = 1'b1;
        @(posedge clk);
        force dut.u_aes0.start = 1'b0; force dut.u_aes0.key_valid = 1'b0;
        force gpio0_pad[0] = 1'b1;  // the periph-side rising edge, fired close to the AES start
        begin : t1202_wait
            integer i;
            for (i = 0; i < 15; i = i + 1) begin
                @(posedge clk);
                if (dut.u_aes0.done) i = 15;
            end
        end
        release dut.u_aes0.key_in; release dut.u_aes0.key_valid;
        release dut.u_aes0.data_in; release dut.u_aes0.start; release dut.u_aes0.encrypt;
        repeat (2) @(posedge clk);
        check(cpu_crypto_irq === 1'b1 && cpu_crypto_irq_id === 3'd0
              && cpu_periph_irq === 1'b1 && cpu_periph_irq_id === 3'd1, "T1202");

        apb_write(GPIO0_BASE + 32'h020, 32'hFFFF_FFFF);  // ISTAT clear (W1C)
        apb_write(GPIO0_BASE + 32'h014, 32'h0000_0000);  // IEN off
        force gpio0_pad = 16'h0000;
        irq_periph_clear_all;
        irq_crypto_clear_all;

        // ---- T1203: doc-mandated fan-out - one real aes1 done pulse
        // must reach BOTH irq_crypto (src[1]) AND perf ch[3] together ----
        axi_write(CFG_BASE + 32'h018, 32'h0000_0002);  // perf clear-all first, clean baseline
        repeat (4) @(posedge clk);

        force dut.u_aes1.key_in = 128'h000102030405060708090a0b0c0d0e0f;
        force dut.u_aes1.key_valid = 1'b1;
        force dut.u_aes1.data_in = 128'h00112233445566778899aabbccddeeff;
        force dut.u_aes1.start = 1'b0; force dut.u_aes1.encrypt = 1'b1;
        @(posedge clk);
        force dut.u_aes1.start = 1'b1;
        @(posedge clk);
        force dut.u_aes1.start = 1'b0; force dut.u_aes1.key_valid = 1'b0;
        begin : t1203_wait
            integer i;
            for (i = 0; i < 15; i = i + 1) begin
                @(posedge clk);
                if (dut.u_aes1.done) i = 15;
            end
        end
        release dut.u_aes1.key_in; release dut.u_aes1.key_valid;
        release dut.u_aes1.data_in; release dut.u_aes1.start; release dut.u_aes1.encrypt;
        repeat (2) @(posedge clk);
        check(cpu_crypto_irq === 1'b1 && cpu_crypto_irq_id === 3'd1
              && dut.u_perf.cnt3 === 32'd1, "T1203");
        irq_crypto_clear_all;

        // ---- T1204: full software-driven chain - CPU programs a
        // REMOTE (multi-hop) dma0 transfer, waits for the real IRQ, then
        // (the "software response") pushes the transferred value through
        // the real SoC-cfg mailbox path and confirms the DSP side reads
        // it back ----
        dma_val = 32'hC0A1_1204;
        axi_write(node_addr(0, 1, 30), dma_val);       // preload src at dma0's own inject node
        repeat (5) @(posedge clk);
        dma_cfg_write(0, 12'h000, node_addr(0, 1, 30)); // SRC_ADDR
        dma_cfg_write(0, 12'h004, node_addr(2, 2, 31)); // DST_ADDR: remote node (2,2), 2+ hops away
        dma_cfg_write(0, 12'h008, 32'd4);                // LENGTH = 1 word
        dma_cfg_write(0, 12'h00C, 32'h0000_0003);        // CTRL: start=1, irq_en=1
        begin : t1204_wait
            integer i;
            for (i = 0; i < 60; i = i + 1) begin
                @(posedge clk);
                if (dut.u_dma0.r_stat[1]) i = 60;
            end
        end
        repeat (2) @(posedge clk);
        begin : t1204_check
            reg dma_ok;
            dma_ok = (cpu_crypto_irq === 1'b1 && cpu_crypto_irq_id === 3'd4
                      && dut.u_noc_mesh.u_sram_22.mem[31][31:0] === dma_val);
            irq_crypto_clear_all;

            // software reacts to the IRQ: reads the transferred word back
            // out of the destination node, then pushes it into the mailbox
            axi_read(node_addr(2, 2, 31), rdval2);
            axi_write(CFG_BASE + 32'h000, rdval2);
            repeat (4) @(posedge dsp_clk);
            mbox_read(rdval2);
            check(dma_ok && (rdval2 === dma_val), "T1204");
        end

        // ---- T1205: perf ch[0]'s real-traffic filter - one real NoC
        // transaction, one real APB transaction, one real SoC-cfg
        // transaction; only the NoC one should count ----
        axi_write(CFG_BASE + 32'h018, 32'h0000_0002);  // clear-all, clean baseline
        repeat (4) @(posedge clk);
        axi_write(node_addr(0, 0, 21), 32'hB007_0002);  // real NoC transaction (via ni_00)
        repeat (4) @(posedge clk);
        apb_write(GPIO0_BASE + 32'h008, 32'h0000_0000);  // real APB transaction (not NoC)
        axi_read(CFG_BASE + 32'h004, rdval);             // real SoC-cfg-space transaction (not NoC)
        repeat (4) @(posedge clk);
        check(dut.u_perf.cnt0 === 32'd1, "T1205");

        if (errors == 0) $display("INTEGRATION SCORE: 5/5");
        else $display("INTEGRATION SCORE: %0d/5", 5 - errors);
        $finish;
    end

    initial begin
        #400000;
        $display("[TIMEOUT]");
        $finish;
    end
endmodule
