`timescale 1ns/1ps
// Custom testbench for the easy-tier (secure_periph_soc) "watchdog"
// category (T501-T506). Real two-stage watchdog behavior, read directly
// from apb_watchdog.v: ctr decrements once per clk cycle (no prescaler),
// UNLOCK opens a ~15-cycle write window, REFRESH either resets the
// counter (window mode off) or - if window mode is on and refreshed too
// early (ctr above half of LOAD1/LOAD2) - flags a window violation
// instead. Ordered so the one test that triggers a REAL system reset
// (T506, stage-2 timeout -> wdt_rst_req -> reset_sync -> sys_rst_n) runs
// LAST, since every other watchdog-specific check needs the SoC to stay
// up.
module tb_easy_watchdog;
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

    // Module-scope event monitor (not a per-test fork): wdt_rst_req
    // immediately (combinationally, via reset_sync's own `async_rst_n =
    // por_n & wdt_rst_n`) triggers a real async system reset that resets
    // apb_watchdog itself - including its own `rstpulse<=0` reset branch
    // - so the pulse can self-clear within the same clock edge's delta-
    // cycles, before the next @(posedge clk) boundary. A plain cycle-
    // boundary poll can genuinely miss it. This `@(posedge wdt_rst_req)`
    // monitor is guaranteed by Verilog event scheduling to fire on the
    // transition itself regardless of how quickly it's cleared
    // afterward, and regardless of which exact bus transaction happens
    // to be in flight when the countdown actually reaches stage 2 (the
    // real trigger can land mid-transaction, not just mid-`repeat`).
    reg saw_wdt_rst_req;
    always @(posedge wdt_rst_req) saw_wdt_rst_req = 1'b1;

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

        // ---- T501: UNLOCK opens the write window - LOAD1 becomes
        // genuinely writable ----
        wdt_unlock;
        ahb_write_priv(WDT_BASE + 32'h000, 32'd100);
        ahb_read_priv(WDT_BASE + 32'h000, rdval, resp);
        check(rdval === 32'd100, "T501");

        // ---- T502: after the ~15-cycle window expires (no unlock),
        // LOAD1 writes are silently ignored - still reads back the T501
        // value, not the new attempted one ----
        repeat (20) @(posedge clk);
        ahb_write_priv(WDT_BASE + 32'h000, 32'd999);
        ahb_read_priv(WDT_BASE + 32'h000, rdval, resp);
        check(rdval === 32'd100, "T502");

        // ---- T503: window-mode violation - with wen=1 (window mode
        // enabled), a REFRESH issued while ctr is still well above
        // LOAD1/2 (i.e. NOT yet inside the "close to expiry" window)
        // sets IRQSTAT.window_violation instead of actually refreshing ----
        wdt_unlock;
        ahb_write_priv(WDT_BASE + 32'h000, 32'd40);   // LOAD1
        ahb_write_priv(WDT_BASE + 32'h004, 32'd40);   // LOAD2
        ahb_write_priv(WDT_BASE + 32'h00C, 32'b0000_0011);  // en=1, wen=1
        repeat (2) @(posedge clk);  // ctr still near 40, well outside the <=20 window
        ahb_write_priv(WDT_BASE + 32'h018, 32'hFEED_C0DE);  // early REFRESH
        ahb_read_priv(WDT_BASE + 32'h01C, rdval, resp);
        check(rdval[1] === 1'b1, "T503");
        wdt_unlock;
        ahb_write_priv(WDT_BASE + 32'h00C, 32'd0);  // stop before reconfiguring
        ahb_write_priv(WDT_BASE + 32'h01C, 32'h3);  // clear both irqstat bits

        // ---- T504: a normal REFRESH (window mode OFF, wen=0) resets
        // the counter back toward LOAD1, genuinely preventing a timeout
        // that would otherwise have happened ----
        wdt_unlock;
        ahb_write_priv(WDT_BASE + 32'h000, 32'd15);   // LOAD1
        ahb_write_priv(WDT_BASE + 32'h004, 32'd15);   // LOAD2
        ahb_write_priv(WDT_BASE + 32'h00C, 32'b0000_0001);  // en=1, wen=0
        repeat (10) @(posedge clk);   // close to expiry (started at 15)
        ahb_write_priv(WDT_BASE + 32'h018, 32'hFEED_C0DE);  // refresh
        ahb_read_priv(WDT_BASE + 32'h008, rdval, resp);     // VALUE
        check(rdval > 32'd10, "T504");
        wdt_unlock;
        ahb_write_priv(WDT_BASE + 32'h00C, 32'd0);
        ahb_write_priv(WDT_BASE + 32'h01C, 32'h3);

        // ---- T505: stage-1 timeout (no refresh) sets IRQSTAT.stage1_fired.
        // saw_wdt_rst_req is armed BEFORE the watchdog starts counting,
        // not just during T506's own wait window below - the real
        // stage-2 trigger can land mid-transaction (e.g. during this
        // very T505 verification read, which itself takes several clk
        // cycles while the watchdog keeps counting down in the
        // background) rather than neatly inside a later `repeat` block. ----
        saw_wdt_rst_req = 1'b0;
        wdt_unlock;
        ahb_write_priv(WDT_BASE + 32'h000, 32'd8);
        ahb_write_priv(WDT_BASE + 32'h004, 32'd8);
        ahb_write_priv(WDT_BASE + 32'h00C, 32'b0000_1101);  // en=1, ren=1, ien=1
        repeat (12) @(posedge clk);
        ahb_read_priv(WDT_BASE + 32'h01C, rdval, resp);
        check(rdval[0] === 1'b1, "T505");

        // ---- T506: continuing without ANY refresh, stage-2 timeout
        // asserts wdt_rst_req - a real system-reset trigger. Runs LAST
        // since this causes a genuine SoC reset. Checks the
        // module-scope `saw_wdt_rst_req` latch (armed above, before
        // T505's own countdown even started) rather than re-polling from
        // here, since the actual trigger may already have fired during
        // T505's own verification read. ----
        repeat (20) @(posedge clk);
        check(saw_wdt_rst_req, "T506");

        if (errors == 0) $display("WATCHDOG SCORE: 6/6");
        else $display("WATCHDOG SCORE: %0d/6", 6 - errors);
        $finish;
    end

    initial begin
        #300000;
        $display("[TIMEOUT]");
        $finish;
    end
endmodule
