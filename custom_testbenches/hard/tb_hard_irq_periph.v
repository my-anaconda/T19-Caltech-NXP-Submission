`timescale 1ns/1ps
// Custom testbench for the hard-tier (crypto_soc) "irq_periph" category
// (T901-T907): u_irq_periph (the same gen_irq_aggregator generator
// already fixed for u_irq_crypto in tb_hard_irq_crypto.v/
// gen_irq_aggregator_v2.py), aggregating uart_rx_irq/gpio0_irq/
// gpio1_irq/timer0_irq/wdt_irq into src[0..4].
//
// Unlike tb_hard_irq_crypto.v (which force/release's the aggregator's
// own ports directly, since irq_crypto's sources - AES done pulses, DMA
// IRQs - don't have a fully reliable CPU-visible path), irq_periph's
// FIVE sources are all real APB peripherals already given solid,
// real-CPU-path testbenches in apb_periph (uart/gpio0/gpio1/timer0/wdt,
// all reached via the documented 0xF000_xxxx global address map, proven
// working there). So THIS testbench does something stronger than
// irq_crypto's: it triggers each peripheral's OWN real interrupt-
// generating condition via genuine CPU register writes (apb_write, the
// same fused-ack-aware task proven in apb_periph) and checks the result
// reaches cpu_periph_irq/cpu_periph_irq_id - a real, end-to-end
// integration test spanning peripheral -> irq_periph_src -> aggregator,
// not an isolated unit test of the aggregator alone. The aggregator's
// OWN register-level behavior (masking, edge/level, polarity, soft-IRQ,
// the doc-mandated lowest-id priority order) is already thoroughly
// covered by tb_hard_irq_crypto.v against the SAME generator - T905
// here re-confirms the priority contract holds through the REAL
// integration path too, not just the isolated aggregator.
module tb_hard_irq_periph;
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

    // Same fused-ack-aware write task proven in tb_hard_apb_periph.v -
    // holds wdata one extra cycle past acceptance (for the bridge's
    // ST_SETUP to sample it) then drops everything at once, never
    // re-checking bvalid (already fired, fused with awready).
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

    // Clearing a source peripheral's OWN status register (e.g. GPIO's
    // ISTAT) drops that source's wire into the aggregator, but does NOT
    // clear the AGGREGATOR's own separately-latched r_pend bit for that
    // source - the exact same lesson already learned the hard way in
    // tb_hard_irq_crypto.v's T704/irq_crypto_clear. u_irq_periph's own
    // CPU-visible address is just as unreliable/run-dependent as
    // u_irq_crypto's (no documented "Slot N" entry, and Step 4 doesn't
    // route it consistently across regenerations), so this clears it
    // the same way irq_crypto's testbench does: force/release directly
    // on the aggregator's own always-ready APB slave port.
    task irq_periph_clear_pend;
        begin
            force dut.u_irq_periph.psel = 1'b1;
            force dut.u_irq_periph.penable = 1'b1;
            force dut.u_irq_periph.pwrite = 1'b1;
            force dut.u_irq_periph.paddr = 12'h014;
            force dut.u_irq_periph.pwdata = 32'hFFFF_FFFF;
            @(posedge clk);
            release dut.u_irq_periph.psel;
            release dut.u_irq_periph.penable;
            release dut.u_irq_periph.pwrite;
            release dut.u_irq_periph.paddr;
            release dut.u_irq_periph.pwdata;
        end
    endtask

    localparam [31:0] UART_BASE   = 32'hF000_0000;
    localparam [31:0] GPIO0_BASE  = 32'hF000_1000;
    localparam [31:0] GPIO1_BASE  = 32'hF000_2000;
    localparam [31:0] TIMER0_BASE = 32'hF000_3000;
    localparam [31:0] WDT_BASE    = 32'hF000_4000;

    initial begin
        cpu_awaddr=0; cpu_awvalid=0; cpu_wdata=0; cpu_wstrb=0; cpu_wvalid=0; cpu_bready=0;
        cpu_araddr=0; cpu_arvalid=0; cpu_rready=0;
        por_n = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk); por_n = 1'b1;
        while (dut.sys_rst_n !== 1'b1) @(posedge clk);
        repeat (4) @(posedge clk);

        // ---- T901: a real rising-edge GPIO0 interrupt (bit 0) reaches
        // cpu_periph_irq with id==1 (gpio0_irq is irq_periph_src[1]) ----
        apb_write(GPIO0_BASE + 32'h008, 32'h0000_0000);  // DIR = all inputs
        force gpio0_pad = 16'h0000;
        repeat (6) @(posedge clk);                        // settle debounce low
        apb_write(GPIO0_BASE + 32'h01C, 32'h0000_0001);   // IPOL bit0 = 1 (rising-edge-active)
        apb_write(GPIO0_BASE + 32'h018, 32'h0000_0001);   // IEDGE bit0 = 1 (edge mode)
        apb_write(GPIO0_BASE + 32'h014, 32'h0000_0001);   // IEN bit0 = 1 (enabled)
        repeat (4) @(posedge clk);
        force gpio0_pad[0] = 1'b1;                        // the rising edge
        repeat (6) @(posedge clk);
        check(cpu_periph_irq === 1'b1 && cpu_periph_irq_id === 3'd1, "T901");
        apb_write(GPIO0_BASE + 32'h020, 32'hFFFF_FFFF);   // ISTAT clear (W1C)
        apb_write(GPIO0_BASE + 32'h014, 32'h0000_0000);   // IEN off
        force gpio0_pad = 16'h0000;
        repeat (4) @(posedge clk);
        irq_periph_clear_pend;
        repeat (2) @(posedge clk);

        // ---- T902: mirrors T901 for GPIO1 (bit 0) - id==2 ----
        apb_write(GPIO1_BASE + 32'h008, 32'h0000_0000);  // DIR = all inputs
        force gpio1_pad = 8'h00;
        repeat (6) @(posedge clk);
        apb_write(GPIO1_BASE + 32'h01C, 32'h0000_0001);
        apb_write(GPIO1_BASE + 32'h018, 32'h0000_0001);
        apb_write(GPIO1_BASE + 32'h014, 32'h0000_0001);
        repeat (4) @(posedge clk);
        force gpio1_pad[0] = 1'b1;
        repeat (6) @(posedge clk);
        check(cpu_periph_irq === 1'b1 && cpu_periph_irq_id === 3'd2, "T902");
        apb_write(GPIO1_BASE + 32'h020, 32'hFFFF_FFFF);
        apb_write(GPIO1_BASE + 32'h014, 32'h0000_0000);
        force gpio1_pad = 8'h00;
        repeat (4) @(posedge clk);
        irq_periph_clear_pend;
        repeat (2) @(posedge clk);

        // ---- T903: timer0's real counter wrap (CTRL0 en0=1,ie0=1, a
        // short LOAD0) fires timer0_irq - id==3 ----
        apb_write(TIMER0_BASE + 32'h000, 32'd10);         // LOAD0 = 10
        apb_write(TIMER0_BASE + 32'h008, 32'h0000_0005);  // CTRL0: en0=1, ie0=1
        repeat (20) @(posedge clk);
        check(cpu_periph_irq === 1'b1 && cpu_periph_irq_id === 3'd3, "T903");
        apb_write(TIMER0_BASE + 32'h010, 32'h0000_0001);  // IRQCLR0
        repeat (4) @(posedge clk);
        irq_periph_clear_pend;
        repeat (2) @(posedge clk);

        // ---- T904: the watchdog's real stage-1 (LOAD1) countdown fires
        // wdt_irq (ien=1 by default, per the watchdog's own documented
        // reset values) - id==4 ----
        apb_write(WDT_BASE + 32'h014, 32'hABCD_1234);      // UNLOCK_KEY
        apb_write(WDT_BASE + 32'h000, 32'd20);             // LOAD1 = 20
        // CTRL write overwrites en/wen/ren/ien together (not just the
        // bits named) - must explicitly keep ien=1 (bit3) here or it
        // gets cleared from its reset default, silently gating wdt_irq
        // off (wdt_irq = iq1 & ien) even though the stage-1 countdown
        // and iq1 itself fire correctly.
        apb_write(WDT_BASE + 32'h00C, 32'h0000_0009);       // CTRL: en=1, ien=1
        repeat (35) @(posedge clk);
        check(cpu_periph_irq === 1'b1 && cpu_periph_irq_id === 3'd4, "T904");
        apb_write(WDT_BASE + 32'h01C, 32'h0000_0001);       // IRQCLR bit0 (clear iq1)
        repeat (4) @(posedge clk);
        irq_periph_clear_pend;
        repeat (2) @(posedge clk);

        // ---- T905: THE priority contract, re-confirmed through the
        // real integration path (not just the isolated aggregator
        // already proven in tb_hard_irq_crypto.v T702) - trigger GPIO0's
        // edge IRQ (id 1) and timer0's wrap IRQ (id 3) again, both
        // pending simultaneously, and check the LOWEST (1) wins, per the
        // architecture doc's "cpu_irq_id[2:0] (lowest active source
        // ID)" ----
        apb_write(GPIO0_BASE + 32'h014, 32'h0000_0001);   // IEN bit0 back on (IEDGE/IPOL still set from T901)
        force gpio0_pad[0] = 1'b0;
        repeat (2) @(posedge clk);
        force gpio0_pad[0] = 1'b1;                        // a fresh rising edge
        repeat (2) @(posedge clk);
        apb_write(TIMER0_BASE + 32'h000, 32'd10);
        apb_write(TIMER0_BASE + 32'h008, 32'h0000_0005);  // re-arm timer0 too
        repeat (20) @(posedge clk);
        check(cpu_periph_irq === 1'b1 && cpu_periph_irq_id === 3'd1, "T905");
        apb_write(GPIO0_BASE + 32'h020, 32'hFFFF_FFFF);
        apb_write(GPIO0_BASE + 32'h014, 32'h0000_0000);
        apb_write(TIMER0_BASE + 32'h010, 32'h0000_0001);
        force gpio0_pad = 16'h0000;
        repeat (4) @(posedge clk);
        irq_periph_clear_pend;
        repeat (2) @(posedge clk);

        // ---- T906: the UART's own real status-driven IRQ (irq_en bit1
        // = tx_empty, true at idle since the TX FIFO starts empty) -
        // id==0, uart is src[0] ----
        apb_write(UART_BASE + 32'h010, 32'h0000_0002);    // irq_en bit1 = tx_empty
        repeat (10) @(posedge clk);
        check(cpu_periph_irq === 1'b1 && cpu_periph_irq_id === 3'd0, "T906");
        apb_write(UART_BASE + 32'h014, 32'hFFFF_FFFF);    // irq_stat clear
        apb_write(UART_BASE + 32'h010, 32'h0000_0000);    // irq_en off
        repeat (4) @(posedge clk);
        irq_periph_clear_pend;
        repeat (2) @(posedge clk);

        // ---- T907: fully idle once every source is cleared and
        // disabled - cpu_periph_irq must deassert cleanly ----
        check(cpu_periph_irq === 1'b0, "T907");

        if (errors == 0) $display("IRQ_PERIPH SCORE: 7/7");
        else $display("IRQ_PERIPH SCORE: %0d/7", 7 - errors);
        $finish;
    end

    initial begin
        #300000;
        $display("[TIMEOUT]");
        $finish;
    end
endmodule
