`timescale 1ns/1ps
// Custom testbench for the easy-tier (secure_periph_soc) "timer_pwm"
// category (T1301-T1303). Per apb_timer.v (read directly):
// `pwm0=pe0?(v0>c0):1'b0` - a real combinational compare against the
// LIVE down-counter value, not a separately-generated waveform.
module tb_easy_timer_pwm;
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

    localparam [31:0] TMR_BASE = 32'h0000_2000;

    initial begin
        por_n = 0;
        cpu_htrans = 2'b00; cpu_hwrite = 0; cpu_haddr = 0; cpu_hwdata = 0;
        cpu_hprot = 3'b001; cpu_hsize = 3'b010; cpu_hburst = 3'b000;
        gpio_in = 0; uart_rx = 1; uart_cts_n = 0;
        repeat (20) @(posedge clk);
        por_n = 1;
        repeat (5) @(posedge clk);

        // ---- T1301: CH0 with pwm_en=1, LOAD=100, COMPARE=50 - pwm0
        // starts HIGH (v0=100 > c0=50) since the counter starts above
        // the threshold ----
        ahb_write_priv(TMR_BASE + 32'h000, 32'd100);
        ahb_write_priv(TMR_BASE + 32'h00C, 32'd50);
        ahb_write_priv(TMR_BASE + 32'h008, 32'b0000_0000_0000_1011);  // en=1,per=1,pe0=1(bit3)
        repeat (3) @(posedge clk);
        check(pwm0 === 1'b1, "T1301");

        // ---- T1302: once the counter decrements below the compare
        // threshold (well past 50), pwm0 correctly drops LOW ----
        repeat (70) @(posedge clk);
        check(pwm0 === 1'b0, "T1302");
        ahb_write_priv(TMR_BASE + 32'h008, 32'd0);  // stop CH0

        // ---- T1303: CH1 runs independently with its OWN compare value
        // and produces its own correct pwm1 waveform, unaffected by
        // CH0's state ----
        ahb_write_priv(TMR_BASE + 32'h020, 32'd100);
        ahb_write_priv(TMR_BASE + 32'h02C, 32'd80);
        ahb_write_priv(TMR_BASE + 32'h028, 32'b0000_0000_0000_1011);  // en=1,per=1,pe1=1
        repeat (3) @(posedge clk);
        check(pwm1 === 1'b1 && pwm0 === 1'b0, "T1303");

        if (errors == 0) $display("TIMER_PWM SCORE: 3/3");
        else $display("TIMER_PWM SCORE: %0d/3", 3 - errors);
        $finish;
    end

    initial begin
        #200000;
        $display("[TIMEOUT]");
        $finish;
    end
endmodule
