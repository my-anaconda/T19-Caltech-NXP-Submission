`timescale 1ns/1ps
// Custom testbench for the hard-tier (crypto_soc) "mailbox" category
// (T1101-T1108): u_mbox (gen_async_fifo in gen_primitives.py), the
// dual-clock CDC FIFO underlying the SoC config space's MBOX_DATA/
// MBOX_STATUS registers.
//
// soc_cfg_regs's own testbench already covers the CPU-facing register
// CONTRACT (push via MBOX_DATA, status via MBOX_STATUS) and found real
// bugs in the TOP-LEVEL glue around the FIFO (mbox_wr_en level-vs-pulse,
// rd_rst_n tied to a constant). This testbench is different in scope: it
// force/release's u_mbox's own wr_en/din/rd_en ports directly (bypassing
// whatever top-level SoC-cfg wiring a given run happens to have, exactly
// like aes_basic/dma_basic did for engines whose own top-level path was
// unreliable) to test the FIFO IP ITSELF - real CDC data integrity,
// full/empty edge cases, and circular-buffer wraparound - independent of
// any top-level integration gaps.
//
// Read gen_async_fifo's source before writing any of this: it is a
// textbook-correct Cummings-style dual-clock FIFO (gray-code pointers,
// the standard MSB-inverted comparison for full detection, matching
// pointer-width (PBITS=ABITS+1) binary/gray tracking) - unlike every
// other IP generator touched so far this session, no bug was found in
// the generator itself by inspection. This testbench exists to verify
// that assessment empirically, under real dual-clock stress (clk=10ns,
// dsp_clk=14ns period, genuinely asynchronous - no common multiple
// within any reasonably-sized test window), not just take it on faith.
module tb_hard_mailbox;
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

    // Force/release directly on u_mbox's own wr_clk-domain ports -
    // bypasses whatever (possibly buggy, possibly non-existent-this-run)
    // top-level SoC-cfg wiring feeds mbox_wr_en/mbox_wr_data, testing the
    // FIFO itself. A single wr_clk pulse, matching the generator's own
    // plain level-gated write (if(wr_en&&!full)) - no edge-detection
    // needed here since we control the pulse width directly.
    task mbox_push;
        input [31:0] data;
        begin
            @(negedge clk);
            force dut.u_mbox.din = data;
            force dut.u_mbox.wr_en = 1'b1;
            @(posedge clk);
            @(negedge clk);
            force dut.u_mbox.wr_en = 1'b0;
        end
    endtask

    // Real DSP-side pop via the top-level's own exposed mbox_rd_en/
    // mbox_dout/mbox_empty ports (real signals, not force - this IS the
    // documented, real DSP-facing interface, per the doc: "DSP polls
    // mbox_empty; asserts rd_en for 1 dsp_clk"). Changes rd_en at
    // negedge, not immediately after the while loop's posedge - the same
    // same-edge race already found and fixed in tb_hard_soc_cfg_regs.v's
    // own mbox_read task.
    task mbox_pop;
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

    localparam DEPTH = 16;
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

        // ---- T1101: a single push, then pop, round-trips the exact
        // data through the real dual-clock domain crossing ----
        mbox_push(32'hDEAD_BEEF);
        mbox_pop(rdval);
        check(rdval === 32'hDEAD_BEEF, "T1101");

        // ---- T1102: FIFO ordering - three distinct pushes come back
        // out in the SAME order pushed, not reversed/reordered ----
        mbox_push(32'h1111_0001);
        mbox_push(32'h2222_0002);
        mbox_push(32'h3333_0003);
        mbox_pop(rdval); check(rdval === 32'h1111_0001, "T1102a");
        mbox_pop(rdval); check(rdval === 32'h2222_0002, "T1102b");
        mbox_pop(rdval); check(rdval === 32'h3333_0003, "T1102c");

        // ---- T1103: filling to exactly DEPTH (16) words asserts full,
        // not one word early or late ----
        for (i = 0; i < DEPTH; i = i + 1) mbox_push(32'hF000_0000 + i);
        repeat (2) @(posedge clk);
        check(dut.mbox_full === 1'b1, "T1103");

        // ---- T1104: pushing while genuinely full is safely ignored -
        // no data corruption, no phantom extra word ----
        mbox_push(32'hBAD0_0000);  // must be dropped, FIFO is full
        repeat (2) @(posedge clk);
        check(dut.mbox_full === 1'b1, "T1104a");
        // drain all 16 real words back out, in order, confirming the
        // dropped push left no trace (word 15 is the LAST real one,
        // not the dropped 0xBAD00000)
        for (i = 0; i < DEPTH; i = i + 1) begin
            mbox_pop(rdval);
            if (rdval !== (32'hF000_0000 + i)) errors = errors + 1;
        end
        check(dut.mbox_empty === 1'b1, "T1104b");

        // ---- T1105: popping while genuinely empty is safely ignored -
        // dout/empty stay stable, no underflow corruption. mbox_pop's
        // own while(mbox_empty) loop would hang forever here (nothing
        // will ever push more data), so this forces rd_en directly and
        // confirms rd_bin does NOT advance ----
        check(dut.mbox_empty === 1'b1, "T1105a");
        begin : t1105_force_pop
            reg [4:0] rd_bin_before;
            rd_bin_before = dut.u_mbox.rd_bin;
            @(negedge dsp_clk);
            force dut.u_mbox.rd_en = 1'b1;
            @(posedge dsp_clk);
            @(negedge dsp_clk);
            force dut.u_mbox.rd_en = 1'b0;
            release dut.u_mbox.rd_en;  // else every later mbox_pop's real rd_en (via mbox_rd_en) is silently overridden by this leftover force
            check(dut.u_mbox.rd_bin === rd_bin_before, "T1105b");
        end

        // ---- T1106: circular-buffer wraparound - push+pop well past
        // DEPTH's own boundary (40 total pushes/pops via one-in-one-out,
        // never actually filling) crosses the internal wr_bin[ABITS-1:0]
        // wraparound point (16) more than twice, confirming the gray-
        // code pointer math survives multiple full wraps ----
        for (i = 0; i < 40; i = i + 1) begin
            mbox_push(32'hAAAA_0000 + i);
            mbox_pop(rdval);
            if (rdval !== (32'hAAAA_0000 + i)) errors = errors + 1;
        end
        check(dut.mbox_empty === 1'b1, "T1106");

        // ---- T1107: back-to-back fast writes (every wr_clk cycle, no
        // gaps) followed by a batch drain - real CDC stress, confirming
        // rapid writes on one domain don't corrupt data or ordering
        // observed from the completely asynchronous read domain ----
        for (i = 0; i < DEPTH; i = i + 1) begin
            @(negedge clk);
            force dut.u_mbox.din = 32'hCC00_0000 + i;
            force dut.u_mbox.wr_en = 1'b1;
            @(posedge clk);
        end
        @(negedge clk);
        force dut.u_mbox.wr_en = 1'b0;
        begin : t1107_check
            reg ok;
            ok = 1'b1;
            for (i = 0; i < DEPTH; i = i + 1) begin
                mbox_pop(rdval);
                if (rdval !== (32'hCC00_0000 + i)) ok = 1'b0;
            end
            check(ok, "T1107");
        end

        // ---- T1108: fully drained and idle - full/empty both settle
        // to their correct steady-state values ----
        repeat (4) @(posedge dsp_clk);
        check(dut.mbox_full === 1'b0 && dut.mbox_empty === 1'b1, "T1108");

        force dut.u_mbox.wr_en = 1'b0;
        release dut.u_mbox.din;
        release dut.u_mbox.wr_en;
        release dut.u_mbox.rd_en;

        if (errors == 0) $display("MAILBOX SCORE: 12/12");
        else $display("MAILBOX SCORE: %0d/12", 12 - errors);
        $finish;
    end

    initial begin
        #600000;
        $display("[TIMEOUT]");
        $finish;
    end
endmodule
