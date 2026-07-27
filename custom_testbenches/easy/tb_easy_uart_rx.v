`timescale 1ns/1ps
// Custom testbench for the easy-tier (secure_periph_soc) "uart_rx"
// category (T1201-T1204). Drives a REAL serial waveform onto the
// uart_rx pin (not a shortcut register poke) and confirms it's received
// correctly through the deserializer into RXDATA/RXFIFO, mirroring
// uart_tx's own bit-level rigor. Same 16-cyc/bit timing (baud_div=0).
module tb_easy_uart_rx;
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
    localparam BIT_CYC = 16;

    reg [31:0] rdval;
    reg [1:0]  resp;

    task uart_send_byte;
        input [7:0] data;
        integer i;
        begin
            uart_rx = 1'b0;                 // start bit
            repeat (BIT_CYC) @(posedge clk);
            for (i = 0; i < 8; i = i + 1) begin
                uart_rx = data[i];
                repeat (BIT_CYC) @(posedge clk);
            end
            uart_rx = 1'b1;                 // stop bit
            repeat (BIT_CYC) @(posedge clk);
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

        ahb_write_priv(UART_BASE + 32'h00C, 32'h0000_0003);  // tx_en=1, rx_en=1, div=0

        // ---- T1201: a real serial byte received correctly through the
        // deserializer into RXDATA ----
        uart_send_byte(8'h5A);
        repeat (4) @(posedge clk);
        ahb_read_priv(UART_BASE + 32'h004, rdval, resp);
        check(rdval[7:0] === 8'h5A, "T1201");

        // ---- T1202: STATUS.rx_empty correctly returns to 1 after the
        // one received byte is drained ----
        ahb_read_priv(UART_BASE + 32'h008, rdval, resp);
        check(rdval[3] === 1'b1, "T1202");

        // ---- T1203: filling the RX FIFO to its documented 16-deep
        // capacity without draining asserts rts_n (flow-control "stop
        // sending", per `rts_n=rx_full`) ----
        begin : t1203_block
            integer i;
            for (i = 0; i < 16; i = i + 1) uart_send_byte(8'h00 + i);
            check(uart_rts_n === 1'b1, "T1203");
        end

        // ---- T1204: one MORE byte sent while genuinely full sets
        // STATUS.overrun, without corrupting the 16 already-queued bytes
        // (drained afterward, still exactly the original FIFO-full
        // sequence, byte 0 first) ----
        begin : t1204_block
            reg overrun_ok, order_ok;
            integer i;
            uart_send_byte(8'hFF);
            ahb_read_priv(UART_BASE + 32'h008, rdval, resp);
            overrun_ok = (rdval[6] === 1'b1);
            order_ok = 1'b1;
            for (i = 0; i < 16; i = i + 1) begin
                ahb_read_priv(UART_BASE + 32'h004, rdval, resp);
                if (rdval[7:0] !== (8'h00 + i)) order_ok = 1'b0;
            end
            check(overrun_ok && order_ok, "T1204");
        end

        if (errors == 0) $display("UART_RX SCORE: 4/4");
        else $display("UART_RX SCORE: %0d/4", 4 - errors);
        $finish;
    end

    initial begin
        #300000;
        $display("[TIMEOUT]");
        $finish;
    end
endmodule
