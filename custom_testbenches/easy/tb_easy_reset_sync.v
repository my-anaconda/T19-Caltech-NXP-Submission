`timescale 1ns/1ps
// Custom testbench for the easy-tier (secure_periph_soc) "reset_sync"
// category (T801-T803). Per the architecture doc: 3-stage sync chain,
// async-assert on EITHER POR or WDT reset. T803 is a real integration
// check (drives a genuine watchdog stage-2 timeout, not a synthetic
// wdt_rst_n force) confirming the OR-path actually works end-to-end.
module tb_easy_reset_sync;
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
    integer cnt;

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

    reg saw_reset_from_wdt;
    always @(negedge dut.u_reset_sync.sys_rst_n) saw_reset_from_wdt = 1'b1;

    initial begin
        por_n = 0;
        cpu_htrans = 2'b00; cpu_hwrite = 0; cpu_haddr = 0; cpu_hwdata = 0;
        cpu_hprot = 3'b001; cpu_hsize = 3'b010; cpu_hburst = 3'b000;
        gpio_in = 0; uart_rx = 1; uart_cts_n = 0;

        // ---- T801: cold power-up takes exactly 3 clk cycles from the
        // cycle after por_n releases until sys_rst_n asserts high (the
        // doc's own "3-stage sync chain", confirmed directly in
        // reset_sync.v) ----
        repeat (3) @(posedge clk);
        @(negedge clk);
        por_n = 1'b1;
        cnt = 0;
        begin : t801_outer
            while (1) begin
                @(posedge clk); #1;
                cnt = cnt + 1;
                if (dut.u_reset_sync.sys_rst_n === 1'b1) disable t801_outer;
                if (cnt > 20) begin
                    $display("[FAIL] T801 (timed out)");
                    errors = errors + 1;
                    disable t801_outer;
                end
            end
        end
        if (cnt <= 20) check(cnt == 3, "T801");

        repeat (10) @(posedge clk);

        // ---- T802: async ASSERT - sys_rst_n drops immediately (same
        // sim time, not waiting for a clock edge) when por_n drops
        // mid-cycle ----
        @(posedge clk); #3;
        por_n = 1'b0;
        #1;
        check(dut.u_reset_sync.sys_rst_n === 1'b0, "T802");
        @(negedge clk);
        por_n = 1'b1;
        while (dut.u_reset_sync.sys_rst_n !== 1'b1) @(posedge clk);
        repeat (5) @(posedge clk);

        // ---- T803: a REAL watchdog stage-2 timeout (por_n stays high
        // throughout) also asserts sys_rst_n via the documented OR-path
        // (POR or WDT), driven through the actual watchdog IP, not a
        // synthetic force ----
        saw_reset_from_wdt = 1'b0;
        ahb_write_priv(WDT_BASE + 32'h014, 32'hABCD_1234);  // UNLOCK
        ahb_write_priv(WDT_BASE + 32'h000, 32'd6);          // LOAD1
        ahb_write_priv(WDT_BASE + 32'h004, 32'd6);          // LOAD2
        ahb_write_priv(WDT_BASE + 32'h00C, 32'b0000_0101);  // en=1, ren=1
        repeat (30) @(posedge clk);
        check(saw_reset_from_wdt && por_n === 1'b1, "T803");

        if (errors == 0) $display("RESET_SYNC SCORE: 3/3");
        else $display("RESET_SYNC SCORE: %0d/3", 3 - errors);
        $finish;
    end

    initial begin
        #300000;
        $display("[TIMEOUT]");
        $finish;
    end
endmodule
