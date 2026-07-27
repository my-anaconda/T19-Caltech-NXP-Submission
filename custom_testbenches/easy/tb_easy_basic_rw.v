`timescale 1ns/1ps
// Custom testbench for the easy-tier (secure_periph_soc) "basic_rw"
// category (T101-T109). A broad first-pass survey confirming basic
// AHB->APB register read/write reaches every one of the five
// peripherals through the real bus fabric (bridge + 5-slave decode),
// before any category-specific behavior (IRQ, PWM, watchdog staging,
// etc.) is tested. Uses the exact ahb_write/ahb_read BFM tasks from the
// organizer's own tb_top_skeleton.v.
module tb_easy_basic_rw;
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
    localparam [31:0] GPIO_BASE = 32'h0000_1000;
    localparam [31:0] TMR_BASE  = 32'h0000_2000;
    localparam [31:0] WDT_BASE  = 32'h0000_3000;
    localparam [31:0] IRQA_BASE = 32'h0000_4000;

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

        // ---- T101: UART CTRL (0x00C) write+readback ----
        ahb_write_priv(UART_BASE + 32'h00C, 32'h0000_0003);  // tx_en=1, rx_en=1
        ahb_read_priv(UART_BASE + 32'h00C, rdval, resp);
        check(rdval[1:0] === 2'b11, "T101");

        // ---- T102: GPIO DATA_OUT (0x004) write+readback ----
        ahb_write_priv(GPIO_BASE + 32'h004, 32'hCAFE_1234);
        ahb_read_priv(GPIO_BASE + 32'h004, rdval, resp);
        check(rdval === 32'hCAFE_1234, "T102");

        // ---- T103: GPIO DIR (0x008) write+readback ----
        ahb_write_priv(GPIO_BASE + 32'h008, 32'h0000_00FF);
        ahb_read_priv(GPIO_BASE + 32'h008, rdval, resp);
        check(rdval === 32'h0000_00FF, "T103");

        // ---- T104: Timer CH0 LOAD (0x000) write+readback ----
        ahb_write_priv(TMR_BASE + 32'h000, 32'h0000_1000);
        ahb_read_priv(TMR_BASE + 32'h000, rdval, resp);
        check(rdval === 32'h0000_1000, "T104");

        // ---- T105: Timer CH0 COMPARE (0x00C) write+readback ----
        ahb_write_priv(TMR_BASE + 32'h00C, 32'h0000_0800);
        ahb_read_priv(TMR_BASE + 32'h00C, rdval, resp);
        check(rdval === 32'h0000_0800, "T105");

        // ---- T106: Watchdog LOAD1 write+readback - requires the
        // documented UNLOCK sequence first (write 0xABCD_1234 to 0x014),
        // since all WDT writes are unlock-gated ----
        ahb_write_priv(WDT_BASE + 32'h014, 32'hABCD_1234);
        ahb_write_priv(WDT_BASE + 32'h000, 32'h0002_0000);
        ahb_read_priv(WDT_BASE + 32'h000, rdval, resp);
        check(rdval === 32'h0002_0000, "T106");

        // ---- T107: IRQ Aggregator IRQ_EN (0x008) write+readback ----
        ahb_write_priv(IRQA_BASE + 32'h008, 32'h0000_00FF);
        ahb_read_priv(IRQA_BASE + 32'h008, rdval, resp);
        check(rdval === 32'h0000_00FF, "T107");

        // ---- T108: a read-only register (UART STATUS, 0x008) reads a
        // real, defined value (not X) - confirms RO registers are
        // actually driven, not just floating ----
        ahb_read_priv(UART_BASE + 32'h008, rdval, resp);
        check(^rdval !== 1'bx, "T108");

        // ---- T109: back-to-back writes to THREE different peripherals
        // don't cross-corrupt each other's registers ----
        ahb_write_priv(UART_BASE + 32'h00C, 32'h0000_0001);
        ahb_write_priv(GPIO_BASE + 32'h004, 32'h0000_00AA);
        ahb_write_priv(TMR_BASE + 32'h000, 32'h0000_0555);
        begin : t109_block
            reg all_ok;
            all_ok = 1'b1;
            ahb_read_priv(UART_BASE + 32'h00C, rdval, resp);
            if (rdval[1:0] !== 2'b01) all_ok = 1'b0;
            ahb_read_priv(GPIO_BASE + 32'h004, rdval, resp);
            if (rdval !== 32'h0000_00AA) all_ok = 1'b0;
            ahb_read_priv(TMR_BASE + 32'h000, rdval, resp);
            if (rdval !== 32'h0000_0555) all_ok = 1'b0;
            check(all_ok, "T109");
        end

        if (errors == 0) $display("BASIC_RW SCORE: 9/9");
        else $display("BASIC_RW SCORE: %0d/9", 9 - errors);
        $finish;
    end

    initial begin
        #200000;
        $display("[TIMEOUT]");
        $finish;
    end
endmodule
