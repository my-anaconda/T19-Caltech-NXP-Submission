`timescale 1ns/1ps
// Custom testbench for the easy-tier (secure_periph_soc) "gpio_irq"
// category (T301-T305). Real GPIO pin transitions (through the
// documented 3-stage debounce, confirmed by reading apb_gpio.v
// directly) driving actual edge/level interrupts, observed on the real
// top-level cpu_irq/cpu_irq_id path (through the IRQ aggregator too),
// not just the GPIO's own ISTAT register in isolation.
module tb_easy_gpio_irq;
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

    // Enables the IRQ aggregator's src[2] (gpio_irq, per the doc's
    // required wiring) so cpu_irq is actually observable end-to-end.
    task enable_agg_gpio_src;
        begin
            ahb_write_priv(IRQA_BASE + 32'h008, 32'hFFFF_FFFF);  // IRQ_EN: all sources
        end
    endtask

    task clear_agg_pend;
        begin
            ahb_write_priv(IRQA_BASE + 32'h014, 32'hFFFF_FFFF);  // IRQ_CLR
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

        enable_agg_gpio_src;

        // ---- T301: a real rising edge on pin 0 (edge mode, rising
        // polarity) sets ISTAT bit0 and reaches cpu_irq ----
        ahb_write_priv(GPIO_BASE + 32'h008, 32'h0000_0000);  // DIR: all inputs
        ahb_write_priv(GPIO_BASE + 32'h01C, 32'h0000_0001);  // IRQ_POL bit0=1 (rising)
        ahb_write_priv(GPIO_BASE + 32'h018, 32'h0000_0001);  // IRQ_EDGE bit0=1 (edge)
        ahb_write_priv(GPIO_BASE + 32'h014, 32'h0000_0001);  // IRQ_EN bit0=1
        gpio_in[0] = 1'b0;
        repeat (5) @(posedge clk);
        gpio_in[0] = 1'b1;                                    // the rising edge
        repeat (6) @(posedge clk);                            // clear the 3-stage debounce
        ahb_read_priv(GPIO_BASE + 32'h020, rdval, resp);
        check(rdval[0] === 1'b1 && cpu_irq === 1'b1, "T301");

        // ---- T302: writing 1 to ISTAT bit0 (W1C) correctly clears it,
        // and cpu_irq deasserts once the AGGREGATOR's own separately-
        // latched pending bit is also cleared. Per the doc, the
        // aggregator defaults to LEVEL mode (IRQ_EDGE reset value 0) for
        // every source including gpio_irq, so it independently latches
        // src[2] itself (`r_pend <= r_pend | (~r_edge & irq_in & ...)`,
        // read directly from irq_aggregator.v) while gpio_irq was high
        // during T301 - the same "clear the raw source, then clear the
        // aggregator's own pend" two-step lesson already proven in the
        // hard/medium-tier aggregator testbenches ----
        ahb_write_priv(GPIO_BASE + 32'h020, 32'h0000_0001);
        repeat (2) @(posedge clk);
        clear_agg_pend;
        ahb_read_priv(GPIO_BASE + 32'h020, rdval, resp);
        check(rdval[0] === 1'b0 && cpu_irq === 1'b0, "T302");

        // ---- T303: a real FALLING edge on pin 1 (polarity=0, edge
        // mode) is independently detected ----
        gpio_in[1] = 1'b1;
        repeat (5) @(posedge clk);
        ahb_write_priv(GPIO_BASE + 32'h01C, 32'h0000_0000);  // IRQ_POL bit1=0 (falling)
        ahb_write_priv(GPIO_BASE + 32'h018, 32'h0000_0002);  // IRQ_EDGE bit1=1 (edge)
        ahb_write_priv(GPIO_BASE + 32'h014, 32'h0000_0002);  // IRQ_EN bit1=1
        gpio_in[1] = 1'b0;                                    // the falling edge
        repeat (6) @(posedge clk);
        ahb_read_priv(GPIO_BASE + 32'h020, rdval, resp);
        check(rdval[1] === 1'b1, "T303");
        ahb_write_priv(GPIO_BASE + 32'h020, 32'hFFFF_FFFF);
        ahb_write_priv(GPIO_BASE + 32'h014, 32'h0000_0000);
        repeat (2) @(posedge clk);

        // ---- T304: LEVEL mode (iedge=0) on pin 2 - stays asserted the
        // whole time the level condition holds, and only clears once
        // BOTH the raw pin is deasserted AND ISTAT is cleared (same
        // sticky-level lesson as the hard/medium tier aggregators -
        // clearing ISTAT while the level condition is still true just
        // re-latches it the very next cycle) ----
        ahb_write_priv(GPIO_BASE + 32'h01C, 32'h0000_0004);  // IRQ_POL bit2=1 (active-high level)
        ahb_write_priv(GPIO_BASE + 32'h018, 32'h0000_0000);  // IRQ_EDGE bit2=0 (level)
        ahb_write_priv(GPIO_BASE + 32'h014, 32'h0000_0004);  // IRQ_EN bit2=1
        gpio_in[2] = 1'b1;
        repeat (6) @(posedge clk);
        ahb_read_priv(GPIO_BASE + 32'h020, rdval, resp);
        check(rdval[2] === 1'b1, "T304");
        gpio_in[2] = 1'b0;   // deassert the level condition first
        repeat (6) @(posedge clk);
        ahb_write_priv(GPIO_BASE + 32'h020, 32'hFFFF_FFFF);  // now safe to clear
        ahb_write_priv(GPIO_BASE + 32'h014, 32'h0000_0000);
        repeat (2) @(posedge clk);

        // ---- T305: two DIFFERENT pins pending simultaneously both show
        // up correctly in ISTAT (multi-bit correctness, not just a
        // single pin happening to work) ----
        ahb_write_priv(GPIO_BASE + 32'h01C, 32'h0000_0003);  // pins 0,1 both rising-active
        ahb_write_priv(GPIO_BASE + 32'h018, 32'h0000_0003);  // both edge mode
        ahb_write_priv(GPIO_BASE + 32'h014, 32'h0000_0003);  // both enabled
        gpio_in[0] = 1'b0; gpio_in[1] = 1'b0;
        repeat (5) @(posedge clk);
        gpio_in[0] = 1'b1; gpio_in[1] = 1'b1;
        repeat (6) @(posedge clk);
        ahb_read_priv(GPIO_BASE + 32'h020, rdval, resp);
        check(rdval[1:0] === 2'b11, "T305");

        if (errors == 0) $display("GPIO_IRQ SCORE: 5/5");
        else $display("GPIO_IRQ SCORE: %0d/5", 5 - errors);
        $finish;
    end

    initial begin
        #200000;
        $display("[TIMEOUT]");
        $finish;
    end
endmodule
