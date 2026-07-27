`timescale 1ns/1ps
// Custom testbench for the easy-tier (secure_periph_soc) "wdt_window"
// category (T901-T903). Deeper window-mode behavior than watchdog's own
// single violation check: confirms a refresh WITHIN the window succeeds
// cleanly, a refresh OUTSIDE it is flagged, and - critically - that a
// window violation does NOT stop the countdown (it's a flag, not a
// safety net), per apb_watchdog.v's own logic (`if(wen&&!inwin)
// iqw<=1; else begin ctr<=ld1; stage<=0; end` - the violation branch
// does nothing to ctr/stage at all).
module tb_easy_wdt_window;
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

    task wdt_unlock;
        begin
            ahb_write_priv(WDT_BASE + 32'h014, 32'hABCD_1234);
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

        // LOAD1=LOAD2=32, window mode ON. Window opens once
        // ctr<=LOAD1>>1=16.
        wdt_unlock;
        ahb_write_priv(WDT_BASE + 32'h000, 32'd32);
        ahb_write_priv(WDT_BASE + 32'h004, 32'd32);
        ahb_write_priv(WDT_BASE + 32'h00C, 32'b0000_0011);  // en=1, wen=1

        // ---- T901: a refresh issued WITHIN the window (after waiting
        // long enough that ctr <= 16) succeeds cleanly - ctr resets back
        // toward LOAD1, no violation flagged ----
        repeat (20) @(posedge clk);   // ctr now well below 16
        ahb_write_priv(WDT_BASE + 32'h018, 32'hFEED_C0DE);
        ahb_read_priv(WDT_BASE + 32'h01C, rdval, resp);
        check(rdval[1] === 1'b0, "T901");
        ahb_read_priv(WDT_BASE + 32'h008, rdval, resp);
        check(rdval > 32'd25, "T902");

        // ---- T903: a window violation does NOT halt the countdown - if
        // never followed by a real (in-window) refresh, the watchdog
        // still reaches its stage-1 timeout on schedule, exactly as if
        // the violating refresh had never been attempted at all ----
        begin : t903_block
            reg fired;
            ahb_write_priv(WDT_BASE + 32'h018, 32'hFEED_C0DE);  // just refreshed, ctr~32
            repeat (2) @(posedge clk);
            ahb_write_priv(WDT_BASE + 32'h018, 32'hFEED_C0DE);  // early refresh -> violation
            ahb_read_priv(WDT_BASE + 32'h01C, rdval, resp);
            fired = (rdval[1] === 1'b1);
            // let it run all the way to stage-1 timeout without ever
            // refreshing again
            repeat (40) @(posedge clk);
            ahb_read_priv(WDT_BASE + 32'h01C, rdval, resp);
            check(fired && rdval[0] === 1'b1, "T903");
        end

        if (errors == 0) $display("WDT_WINDOW SCORE: 3/3");
        else $display("WDT_WINDOW SCORE: %0d/3", 3 - errors);
        $finish;
    end

    initial begin
        #300000;
        $display("[TIMEOUT]");
        $finish;
    end
endmodule
