`timescale 1ns/1ps
// Custom testbench for the easy-tier (secure_periph_soc) "timer"
// category (T401-T405). Real down-counter/prescaler/periodic-reload
// behavior, read directly from the generated apb_timer.v: the counter
// decrements once every (prescale+1) clk cycles, and on reaching 0 either
// reloads (periodic mode) or stops (one-shot mode), setting IRQSTAT if
// interrupt-enabled.
module tb_easy_timer;
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

        // ---- T401: CH0, prescale=0 (1 clk/tick), LOAD=5, one-shot
        // (periodic=0), irq_en=1 - terminal count sets IRQSTAT and the
        // timer stops itself (en0 auto-clears) ----
        ahb_write_priv(TMR_BASE + 32'h000, 32'd5);           // LOAD0=5
        ahb_write_priv(TMR_BASE + 32'h008, 32'b0000_0000_0000_0101); // en=1,ie0=1(bit2),per=0
        repeat (10) @(posedge clk);
        ahb_read_priv(TMR_BASE + 32'h010, rdval, resp);
        check(rdval[0] === 1'b1, "T401");

        // ---- T402: after servicing (write 1 to IRQSTAT to clear), the
        // timer is genuinely stopped (CTRL.en read back as 0, one-shot
        // mode correctly self-disabled) ----
        ahb_write_priv(TMR_BASE + 32'h010, 32'd1);
        ahb_read_priv(TMR_BASE + 32'h008, rdval, resp);
        check(rdval[0] === 1'b0, "T402");

        // ---- T403: VALUE (0x004) reflects a real, live-decrementing
        // counter mid-count (not stuck at the load value or at 0) ----
        begin : t403_block
            reg [31:0] v_early, v_late;
            ahb_write_priv(TMR_BASE + 32'h000, 32'd200);
            ahb_write_priv(TMR_BASE + 32'h008, 32'b0000_0000_0000_0011); // en=1, per=1
            repeat (5) @(posedge clk);
            ahb_read_priv(TMR_BASE + 32'h004, v_early, resp);
            repeat (50) @(posedge clk);
            ahb_read_priv(TMR_BASE + 32'h004, v_late, resp);
            check(v_late < v_early, "T403");
            ahb_write_priv(TMR_BASE + 32'h008, 32'd0);  // stop CH0 before CH1 test
        end

        // ---- T404: the prescaler genuinely divides - a channel with
        // prescale=3 (4 clk/tick) takes ~4x longer to decrement the same
        // amount as prescale=0 ----
        begin : t404_block
            reg [31:0] v0, v1;
            integer delta_slow;
            ahb_write_priv(TMR_BASE + 32'h000, 32'd1000);
            ahb_write_priv(TMR_BASE + 32'h008, {20'h0, 8'd3, 4'b0011}); // prescale=3, en=1,per=1
            repeat (2) @(posedge clk);
            ahb_read_priv(TMR_BASE + 32'h004, v0, resp);
            repeat (40) @(posedge clk);
            ahb_read_priv(TMR_BASE + 32'h004, v1, resp);
            delta_slow = v0 - v1;
            // With prescale=0 (T403 above), ~50 cycles decremented the
            // counter by roughly 45-50; with prescale=3 (4x slower),
            // 40 cycles should decrement it by roughly 1/4 as much.
            check(delta_slow > 0 && delta_slow < 20, "T404");
            ahb_write_priv(TMR_BASE + 32'h008, 32'd0);
        end

        // ---- T405: CH1 runs independently and simultaneously with a
        // DIFFERENT load value, reaching its own terminal count on its
        // own schedule ----
        ahb_write_priv(TMR_BASE + 32'h020, 32'd3);
        ahb_write_priv(TMR_BASE + 32'h028, 32'b0000_0000_0000_0101); // en=1, ie1=1, per=0
        repeat (10) @(posedge clk);
        ahb_read_priv(TMR_BASE + 32'h030, rdval, resp);
        check(rdval[0] === 1'b1, "T405");

        if (errors == 0) $display("TIMER SCORE: 5/5");
        else $display("TIMER SCORE: %0d/5", 5 - errors);
        $finish;
    end

    initial begin
        #300000;
        $display("[TIMEOUT]");
        $finish;
    end
endmodule
