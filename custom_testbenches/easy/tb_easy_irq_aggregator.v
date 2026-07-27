`timescale 1ns/1ps
// Custom testbench for the easy-tier (secure_periph_soc) "irq_aggregator"
// category (T701-T705). Unlike hard/medium tier's aggregators (fixed to
// "lowest ID wins" via gen_irq_aggregator_v2), easy tier's own doc
// explicitly states the OPPOSITE convention ("Priority encoder selects
// the highest pending source, src7=highest") - confirmed directly by
// reading the generated irq_aggregator.v, whose priority encoder checks
// bit 7 first, matching the doc. This suite tests THAT documented
// contract, not the hard/medium one.
module tb_easy_irq_aggregator;
    reg         clk;
    reg         por_n;
    reg  [31:0] cpu_haddr;
    reg  [1:0]  cpu_htrans;
    reg         cpu_hwrite;
    reg  [2:0]  cpu_hsize;
    reg  [2:0]  cpu_hburst;
    reg  [2:0]  cpu_hprot;
    reg  [31:0] cpu_hwdata;
    wire [31:0] cpu_hrdata;
    wire        cpu_hready;
    wire [1:0]  cpu_hresp;
    reg  [31:0] gpio_in;
    wire [31:0] gpio_out;
    wire [31:0] gpio_oe;
    wire        uart_tx;
    reg         uart_rx;
    reg         uart_cts_n;
    wire        uart_rts_n;
    wire        pwm0;
    wire        pwm1;
    wire        cpu_irq;
    wire [2:0]  cpu_irq_id;
    wire        wdt_rst_req;

    secure_periph_soc dut (
        .clk(clk), .por_n(por_n),
        .cpu_haddr(cpu_haddr), .cpu_htrans(cpu_htrans), .cpu_hwrite(cpu_hwrite),
        .cpu_hsize(cpu_hsize), .cpu_hburst(cpu_hburst), .cpu_hprot(cpu_hprot),
        .cpu_hwdata(cpu_hwdata), .cpu_hrdata(cpu_hrdata), .cpu_hready(cpu_hready),
        .cpu_hresp(cpu_hresp),
        .gpio_in(gpio_in), .gpio_out(gpio_out), .gpio_oe(gpio_oe),
        .uart_tx(uart_tx), .uart_rx(uart_rx), .uart_cts_n(uart_cts_n), .uart_rts_n(uart_rts_n),
        .pwm0(pwm0), .pwm1(pwm1),
        .cpu_irq(cpu_irq), .cpu_irq_id(cpu_irq_id),
        .wdt_rst_req(wdt_rst_req)
    );

    initial clk = 0;
    always #5 clk = ~clk;

`include "tb_easy_common.vh"

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

    localparam [31:0] GPIO_BASE = 32'h0000_1000;
    localparam [31:0] IRQA_BASE = 32'h0000_4000;

    reg [31:0] rdval;
    reg [1:0]  resp;

    task arm_gpio_pin0_irq;
        begin
            ahb_write_priv(GPIO_BASE + 32'h008, 32'h0000_0000);  // DIR: input
            gpio_in[0] = 1'b0;
            ahb_write_priv(GPIO_BASE + 32'h01C, 32'h0000_0001);  // POL: rising
            ahb_write_priv(GPIO_BASE + 32'h018, 32'h0000_0001);  // EDGE: edge mode
            ahb_write_priv(GPIO_BASE + 32'h014, 32'h0000_0001);  // EN
        end
    endtask

    task pulse_gpio_pin0;
        begin
            repeat (5) @(posedge clk);
            gpio_in[0] = 1'b1;
            repeat (6) @(posedge clk);
        end
    endtask

    initial begin
        por_n = 0;
        cpu_htrans = 2'b00; cpu_hwrite = 0; cpu_haddr = 0; cpu_hwdata = 0;
        cpu_hprot = 3'b001; cpu_hsize = 3'b010; cpu_hburst = 3'b000;
        gpio_in = 0; uart_rx = 1; uart_cts_n = 0;
        repeat (20) @(posedge clk);
        por_n = 1;
        repeat (5) @(posedge clk);

        ahb_write_priv(IRQA_BASE + 32'h008, 32'hFFFF_FFFF);  // IRQ_EN: all sources

        // ---- T701: the software interrupt (src[7], written directly at
        // the aggregator) reaches cpu_irq with the doc's "src7=highest"
        // vector id ----
        ahb_write_priv(IRQA_BASE + 32'h01C, 32'h0000_0080);  // IRQ_SOFT bit7=1
        repeat (2) @(posedge clk);
        check(cpu_irq === 1'b1 && cpu_irq_id === 3'd7, "T701");
        ahb_write_priv(IRQA_BASE + 32'h01C, 32'h0000_0000);  // clear soft
        ahb_write_priv(IRQA_BASE + 32'h014, 32'hFFFF_FFFF);  // IRQ_CLR
        repeat (2) @(posedge clk);

        // ---- T702: a real GPIO edge IRQ (src[2]) alone reaches cpu_irq
        // with id=2 ----
        arm_gpio_pin0_irq;
        pulse_gpio_pin0;
        check(cpu_irq === 1'b1 && cpu_irq_id === 3'd2, "T702");

        // ---- T703: with BOTH src[2] (gpio, still pending) AND src[7]
        // (soft) pending simultaneously, the HIGHEST index wins (7, not
        // 2) - per the doc's own explicit priority direction ----
        ahb_write_priv(IRQA_BASE + 32'h01C, 32'h0000_0080);
        repeat (2) @(posedge clk);
        check(cpu_irq === 1'b1 && cpu_irq_id === 3'd7, "T703");
        ahb_write_priv(IRQA_BASE + 32'h01C, 32'h0000_0000);

        // Full clean baseline before T704/T705: the aggregator defaults
        // to LEVEL mode for every source (IRQ_EDGE reset value 0, never
        // configured above), and gpio_irq itself is ALREADY a sticky-
        // latched signal (GPIO's own ISTAT, set since T702/T703's
        // pulses) - level-mode re-latches r_pend[2] EVERY cycle gpio_irq
        // stays high, so IRQ_CLR alone can't clear it while GPIO's own
        // ISTAT is still set (same sticky-level lesson as gpio_irq's own
        // T304). Clear GPIO's raw source FIRST, then the aggregator's
        // latched pend, same two-step order proven there.
        ahb_write_priv(GPIO_BASE + 32'h020, 32'hFFFF_FFFF);  // clear GPIO's own ISTAT
        gpio_in[0] = 1'b0;
        repeat (4) @(posedge clk);
        ahb_write_priv(IRQA_BASE + 32'h014, 32'hFFFF_FFFF);  // aggregator IRQ_CLR
        repeat (2) @(posedge clk);

        // ---- T704: masking src[2] via IRQ_EN correctly prevents a NEW
        // GPIO edge from ever setting the aggregator's pending bit -
        // cpu_irq stays deasserted even though the real hardware event
        // genuinely happened (confirmed separately in T705 that GPIO's
        // own ISTAT did still latch it - masking is at the aggregator,
        // not a GPIO-level suppression) ----
        ahb_write_priv(IRQA_BASE + 32'h008, 32'hFFFF_FFFB);  // IRQ_EN: mask bit2 off
        pulse_gpio_pin0;
        check(cpu_irq === 1'b0, "T704");

        // ---- T705: re-enabling src[2] reveals the STILL-PENDING GPIO
        // event from T704 (proving masking suppressed the AGGREGATOR's
        // reaction, not the underlying GPIO condition) - and explicitly
        // clearing both the GPIO source and the aggregator's pend
        // afterward genuinely returns cpu_irq to deasserted ----
        ahb_write_priv(IRQA_BASE + 32'h008, 32'hFFFF_FFFF);  // re-enable all
        repeat (2) @(posedge clk);
        begin : t705_reveal
            reg revealed;
            revealed = (cpu_irq === 1'b1 && cpu_irq_id === 3'd2);
            ahb_write_priv(GPIO_BASE + 32'h020, 32'hFFFF_FFFF);
            gpio_in[0] = 1'b0;
            repeat (4) @(posedge clk);
            ahb_write_priv(IRQA_BASE + 32'h014, 32'hFFFF_FFFF);
            repeat (2) @(posedge clk);
            check(revealed && cpu_irq === 1'b0, "T705");
        end

        if (errors == 0) $display("IRQ_AGGREGATOR SCORE: 5/5");
        else $display("IRQ_AGGREGATOR SCORE: %0d/5", 5 - errors);
        $finish;
    end

    initial begin
        #200000;
        $display("[TIMEOUT]");
        $finish;
    end
endmodule
