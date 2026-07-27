`timescale 1ns/1ps
// Custom testbench for the easy-tier (secure_periph_soc) "wdt_unlock"
// category (T1501) - the fifteenth and final easy-tier category. A
// single, focused check distinct from watchdog's own T501/T502 (which
// prove the CORRECT key opens the window and it later expires): this
// confirms a WRONG key does NOT open the window at all, per
// apb_watchdog.v's own exact-match logic (`uck <= (pwdata==32'hABCD_1234)
// ? 4'd15 : 4'd0`) - any other value explicitly locks it back down
// rather than leaving it open.
module tb_easy_wdt_unlock;
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

    localparam [31:0] WDT_BASE = 32'h0000_3000;

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

        // ---- T1501: an INCORRECT unlock key leaves LOAD1 write-
        // protected - a real write attempt right afterward is silently
        // ignored, same as if no unlock had ever been attempted at all ----
        ahb_write_priv(WDT_BASE + 32'h014, 32'hDEAD_BEEF);  // wrong key
        ahb_write_priv(WDT_BASE + 32'h000, 32'd777);
        ahb_read_priv(WDT_BASE + 32'h000, rdval, resp);
        check(rdval !== 32'd777, "T1501");

        if (errors == 0) $display("WDT_UNLOCK SCORE: 1/1");
        else $display("WDT_UNLOCK SCORE: %0d/1", 1 - errors);
        $finish;
    end

    initial begin
        #100000;
        $display("[TIMEOUT]");
        $finish;
    end
endmodule
