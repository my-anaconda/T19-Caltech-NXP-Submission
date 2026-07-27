`timescale 1ns/1ps
// Custom testbench for the easy-tier (secure_periph_soc) "irq_priority"
// category (T1001-T1003). A more exhaustive priority-ordering check than
// irq_aggregator's own single pairwise check: three DIFFERENT real
// hardware/software sources (uart_irq=src1, timer_irq=src3,
// software=src7), added one at a time, confirming the vector id climbs
// correctly each time per the doc's "highest pending source wins".
module tb_easy_irq_priority;
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

    localparam [31:0] UART_BASE = 32'h0000_0000;
    localparam [31:0] TMR_BASE  = 32'h0000_2000;
    localparam [31:0] IRQA_BASE = 32'h0000_4000;

    initial begin
        por_n = 0;
        cpu_htrans = 2'b00; cpu_hwrite = 0; cpu_haddr = 0; cpu_hwdata = 0;
        cpu_hprot = 3'b001; cpu_hsize = 3'b010; cpu_hburst = 3'b000;
        gpio_in = 0; uart_rx = 1; uart_cts_n = 0;
        repeat (20) @(posedge clk);
        por_n = 1;
        repeat (5) @(posedge clk);

        ahb_write_priv(IRQA_BASE + 32'h008, 32'hFFFF_FFFF);  // IRQ_EN: all sources

        // ---- T1001: src[1] (uart, tx_empty at idle) alone -> id=1 ----
        ahb_write_priv(UART_BASE + 32'h010, 32'h0000_0002);  // UART IRQEN: tx_empty
        repeat (2) @(posedge clk);
        check(cpu_irq === 1'b1 && cpu_irq_id === 3'd1, "T1001");

        // ---- T1002: adding src[3] (timer, real terminal-count IRQ)
        // while src[1] is still pending -> id climbs to 3 (higher wins) ----
        ahb_write_priv(TMR_BASE + 32'h000, 32'd6);
        ahb_write_priv(TMR_BASE + 32'h008, 32'b0000_0000_0000_0101);  // en=1, ie0=1
        repeat (10) @(posedge clk);
        check(cpu_irq === 1'b1 && cpu_irq_id === 3'd3, "T1002");

        // ---- T1003: adding src[7] (software) on top of BOTH -> id
        // climbs to 7, the overall highest ----
        ahb_write_priv(IRQA_BASE + 32'h01C, 32'h0000_0080);
        repeat (2) @(posedge clk);
        check(cpu_irq === 1'b1 && cpu_irq_id === 3'd7, "T1003");

        if (errors == 0) $display("IRQ_PRIORITY SCORE: 3/3");
        else $display("IRQ_PRIORITY SCORE: %0d/3", 3 - errors);
        $finish;
    end

    initial begin
        #200000;
        $display("[TIMEOUT]");
        $finish;
    end
endmodule
