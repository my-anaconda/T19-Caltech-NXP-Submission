`timescale 1ns/1ps
// Custom testbench for the easy-tier (secure_periph_soc) "gpio_level"
// category (T1401-T1402). Level-mode-specific GPIO IRQ behavior
// (IRQ_EDGE=0), distinct from gpio_irq's own single level-mode check:
// confirms BOTH polarities of level-sensitive detection
// (`lv=r_ipol?gs:~gs`, read directly from apb_gpio.v).
module tb_easy_gpio_level;
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

    reg [31:0] rdval;
    reg [1:0]  resp;

    initial begin
        por_n = 0;
        cpu_htrans = 2'b00; cpu_hwrite = 0; cpu_haddr = 0; cpu_hwdata = 0;
        cpu_hprot = 3'b001; cpu_hsize = 3'b010; cpu_hburst = 3'b000;
        gpio_in = 0; uart_rx = 1; uart_cts_n = 0;
        repeat (20) @(posedge clk);
        por_n = 1;
        repeat (5) @(posedge clk);

        ahb_write_priv(GPIO_BASE + 32'h008, 32'h0000_0000);  // DIR: all inputs

        // ---- T1401: active-HIGH level (pol=1) on pin 5 - ISTAT stays
        // set as long as the pin is held high, confirmed across
        // multiple cycles (a real level, not a one-shot latch that
        // happens to still read as set) ----
        gpio_in[5] = 1'b0;
        repeat (5) @(posedge clk);
        ahb_write_priv(GPIO_BASE + 32'h01C, 32'h0000_0020);  // POL bit5=1 (active-high)
        ahb_write_priv(GPIO_BASE + 32'h018, 32'h0000_0000);  // EDGE: level mode (all 0)
        ahb_write_priv(GPIO_BASE + 32'h014, 32'h0000_0020);  // EN bit5
        gpio_in[5] = 1'b1;
        repeat (6) @(posedge clk);
        begin : t1401_block
            reg stays_set;
            integer i;
            stays_set = 1'b1;
            for (i = 0; i < 8; i = i + 1) begin
                ahb_read_priv(GPIO_BASE + 32'h020, rdval, resp);
                if (rdval[5] !== 1'b1) stays_set = 1'b0;
                @(posedge clk);
            end
            check(stays_set, "T1401");
        end
        ahb_write_priv(GPIO_BASE + 32'h014, 32'h0000_0000);
        ahb_write_priv(GPIO_BASE + 32'h020, 32'hFFFF_FFFF);
        gpio_in[5] = 1'b0;
        repeat (4) @(posedge clk);

        // ---- T1402: active-LOW level (pol=0) on pin 6 - ISTAT sets
        // while the pin is LOW, and correctly clears once the pin
        // returns high AND ISTAT is explicitly cleared (same raw-then-
        // latch clear order proven in gpio_irq) ----
        gpio_in[6] = 1'b1;
        repeat (5) @(posedge clk);
        ahb_write_priv(GPIO_BASE + 32'h01C, 32'h0000_0000);  // POL bit6=0 (active-low)
        ahb_write_priv(GPIO_BASE + 32'h018, 32'h0000_0000);  // EDGE: level mode
        ahb_write_priv(GPIO_BASE + 32'h014, 32'h0000_0040);  // EN bit6
        gpio_in[6] = 1'b0;
        repeat (6) @(posedge clk);
        begin : t1402_block
            reg set_ok, clear_ok;
            ahb_read_priv(GPIO_BASE + 32'h020, rdval, resp);
            set_ok = (rdval[6] === 1'b1);
            gpio_in[6] = 1'b1;   // deassert the level condition first
            repeat (6) @(posedge clk);
            ahb_write_priv(GPIO_BASE + 32'h020, 32'hFFFF_FFFF);  // now safe to clear
            repeat (2) @(posedge clk);
            ahb_read_priv(GPIO_BASE + 32'h020, rdval, resp);
            clear_ok = (rdval[6] === 1'b0);
            check(set_ok && clear_ok, "T1402");
        end

        if (errors == 0) $display("GPIO_LEVEL SCORE: 2/2");
        else $display("GPIO_LEVEL SCORE: %0d/2", 2 - errors);
        $finish;
    end

    initial begin
        #200000;
        $display("[TIMEOUT]");
        $finish;
    end
endmodule
