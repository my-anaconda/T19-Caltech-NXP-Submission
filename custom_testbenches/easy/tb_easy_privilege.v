`timescale 1ns/1ps
// Custom testbench for the easy-tier (secure_periph_soc) "privilege"
// category (T601-T603). Per apb_fabric5.v (read directly): only slave 3
// (watchdog) is privilege-gated (`priv_err=dec3&&!priv`), everything
// else accepts any privilege level. A privilege violation surfaces as a
// real AHB ERROR response (hresp=2'b01) via the bridge's 2-cycle error
// FSM, not just an internal flag.
module tb_easy_privilege;
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
    localparam [31:0] WDT_BASE  = 32'h0000_3000;

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

        // ---- T601: an UNPRIVILEGED read from the watchdog (S3) is
        // rejected with a real AHB ERROR response ----
        ahb_read_user(WDT_BASE + 32'h008, rdval, resp);
        check(resp === 2'b01, "T601");

        // ---- T602: the SAME address, PRIVILEGED, succeeds cleanly
        // (OKAY response) ----
        ahb_read_priv(WDT_BASE + 32'h008, rdval, resp);
        check(resp === 2'b00, "T602");

        // ---- T603: an unprivileged access to a DIFFERENT slave (GPIO,
        // S1) is NOT blocked - the privilege filter is specific to S3,
        // not a global lockout ----
        ahb_write_user(GPIO_BASE + 32'h004, 32'hFACE_0603);
        ahb_read_user(GPIO_BASE + 32'h004, rdval, resp);
        check(resp === 2'b00 && rdval === 32'hFACE_0603, "T603");

        if (errors == 0) $display("PRIVILEGE SCORE: 3/3");
        else $display("PRIVILEGE SCORE: %0d/3", 3 - errors);
        $finish;
    end

    initial begin
        #150000;
        $display("[TIMEOUT]");
        $finish;
    end
endmodule
