`timescale 1ns/1ps
// Custom testbench for the easy-tier (secure_periph_soc) "uart_tx"
// category (T201-T204). Decodes the REAL serial waveform on the uart_tx
// pin bit-by-bit (not just checking FIFO status flags), confirming the
// actual transmitted bit pattern matches what was pushed. Per the
// generated apb_uart.v (read directly): default reset state already has
// tx_en=1/rx_en=1/baud_div=0, and baud_rate = clk/(16*(baud_div+1)), so
// each bit is exactly 16 clk cycles wide - explicitly reconfirmed via
// CTRL write here rather than relying on the reset default, so this
// test is self-contained regardless of what a future regeneration's
// reset default happens to be.
module tb_easy_uart_tx;
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
    localparam BIT_CYC = 16;  // baud_div=0 -> 16 clk cycles/bit

    reg [31:0] rdval;
    reg [1:0]  resp;

    // Samples the uart_tx pin at the CENTER of each bit period and
    // reconstructs a full 10-bit frame (start + 8 data + stop, no
    // parity). Assumes the caller has already seen uart_tx idle-high and
    // is about to catch the falling start-bit edge.
    task uart_capture_byte;
        output [7:0] data;
        output       start_ok;
        output       stop_ok;
        integer i;
        begin
            while (uart_tx !== 1'b0) @(posedge clk);   // wait for start bit
            repeat (BIT_CYC/2) @(posedge clk);          // center of start bit
            start_ok = (uart_tx === 1'b0);
            for (i = 0; i < 8; i = i + 1) begin
                repeat (BIT_CYC) @(posedge clk);        // advance to center of next bit
                data[i] = uart_tx;
            end
            repeat (BIT_CYC) @(posedge clk);            // center of stop bit
            stop_ok = (uart_tx === 1'b1);
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

        // CTRL: tx_en=1, rx_en=1, parity off, baud_div=0 (16 cyc/bit)
        ahb_write_priv(UART_BASE + 32'h00C, 32'h0000_0003);

        // ---- T201: a real byte pushed to TXDATA is correctly
        // serialized on uart_tx: start bit low, 8 data bits LSB-first,
        // stop bit high ----
        begin : t201_block
            reg [7:0] got;
            reg s_ok, e_ok;
            ahb_write_priv(UART_BASE + 32'h000, 32'h0000_00A5);  // 0xA5 = 10100101
            uart_capture_byte(got, s_ok, e_ok);
            check(got === 8'hA5 && s_ok && e_ok, "T201");
        end

        // ---- T202: after the byte drains, STATUS.tx_empty (bit1) is
        // correctly set ----
        repeat (20) @(posedge clk);
        ahb_read_priv(UART_BASE + 32'h008, rdval, resp);
        check(rdval[1] === 1'b1, "T202");

        // ---- T203: CTS gating - with cts_n=1 (not clear to send), a
        // pushed byte stays in the FIFO and TX never starts (uart_tx
        // stays idle high) ----
        begin : t203_block
            reg idle_held;
            integer i;
            uart_cts_n = 1'b1;
            ahb_write_priv(UART_BASE + 32'h000, 32'h0000_005A);
            idle_held = 1'b1;
            for (i = 0; i < BIT_CYC * 3; i = i + 1) begin
                @(posedge clk);
                if (uart_tx !== 1'b1) idle_held = 1'b0;
            end
            check(idle_held, "T203");
            uart_cts_n = 1'b0;  // release CTS so the queued byte can drain
        end

        // ---- T204: the byte queued during T203 (0x5A) now transmits
        // correctly once CTS releases (queued data preserved through the
        // CTS-gated wait) ----
        begin : t204_block
            reg [7:0] got;
            reg s_ok, e_ok;
            uart_capture_byte(got, s_ok, e_ok);
            check(got === 8'h5A && s_ok && e_ok, "T204");
        end

        if (errors == 0) $display("UART_TX SCORE: 4/4");
        else $display("UART_TX SCORE: %0d/4", 4 - errors);
        $finish;
    end

    initial begin
        #200000;
        $display("[TIMEOUT]");
        $finish;
    end
endmodule
