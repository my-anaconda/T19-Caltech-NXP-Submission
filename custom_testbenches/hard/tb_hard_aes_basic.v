`timescale 1ns/1ps
// Custom testbench for the hard-tier (crypto_soc) "aes_basic" category
// (T401-T408). Per the architecture doc's own explicit callout: "The AES
// engines are standalone instances, not connected to the router's local
// AXI port" - there is no CPU-programmable register interface for them
// at all, so the only way to exercise them is to force their own input
// ports directly via hierarchical reference (`dut.u_aes0.key_in` etc.),
// exactly like testing an isolated IP block that happens to be
// instantiated inside a larger SoC. `force`/`release` is the standard,
// legitimate Verilog mechanism for this - it overrides the top-level's
// own tie-offs for the duration of the force.
//
// gen_aes128 (organizer-provided) implements a REAL, correct AES-128
// core (proper S-box/ShiftRows/MixColumns/key-schedule per FIPS-197),
// not a dummy placeholder, so this uses the actual NIST FIPS-197
// AES-128 validation vector to verify genuine cryptographic
// correctness, not just "some data came out":
//   key       = 00010203 04050607 08090a0b 0c0d0e0f
//   plaintext = 00112233 44556677 8899aabb ccddeeff
//   ciphertext= 69c4e0d8 6a7b0430 d8cdb780 70b4c55a
module tb_hard_aes_basic;
    reg clk = 0, dsp_clk = 0, por_n;
    always #5 clk = ~clk;
    always #7 dsp_clk = ~dsp_clk;

    reg  [31:0] cpu_awaddr;  reg  cpu_awvalid; wire cpu_awready;
    reg  [31:0] cpu_wdata;   reg  [3:0] cpu_wstrb;
    reg         cpu_wvalid;  wire cpu_wready;
    wire [1:0]  cpu_bresp;   wire cpu_bvalid;  reg  cpu_bready;
    reg  [31:0] cpu_araddr;  reg  cpu_arvalid; wire cpu_arready;
    wire [31:0] cpu_rdata;   wire [1:0] cpu_rresp;
    wire        cpu_rvalid;  reg  cpu_rready;
    wire [15:0] gpio0_pad;
    wire [7:0]  gpio1_pad;
    reg         uart_rx = 1'b1;
    wire        uart_tx;
    wire        cpu_crypto_irq; wire [2:0] cpu_crypto_irq_id;
    wire        cpu_periph_irq; wire [2:0] cpu_periph_irq_id;
    wire [31:0] mbox_dout;
    reg         mbox_rd_en = 1'b0;
    wire        mbox_empty;

    crypto_soc dut (
        .clk(clk), .por_n(por_n), .dsp_clk(dsp_clk),
        .cpu_awaddr(cpu_awaddr), .cpu_awvalid(cpu_awvalid), .cpu_awready(cpu_awready),
        .cpu_wdata(cpu_wdata), .cpu_wstrb(cpu_wstrb), .cpu_wvalid(cpu_wvalid), .cpu_wready(cpu_wready),
        .cpu_bresp(cpu_bresp), .cpu_bvalid(cpu_bvalid), .cpu_bready(cpu_bready),
        .cpu_araddr(cpu_araddr), .cpu_arvalid(cpu_arvalid), .cpu_arready(cpu_arready),
        .cpu_rdata(cpu_rdata), .cpu_rresp(cpu_rresp), .cpu_rvalid(cpu_rvalid), .cpu_rready(cpu_rready),
        .gpio0_pad(gpio0_pad), .gpio1_pad(gpio1_pad),
        .uart_rx(uart_rx), .uart_tx(uart_tx),
        .cpu_crypto_irq(cpu_crypto_irq), .cpu_crypto_irq_id(cpu_crypto_irq_id),
        .cpu_periph_irq(cpu_periph_irq), .cpu_periph_irq_id(cpu_periph_irq_id),
        .mbox_dout(mbox_dout), .mbox_rd_en(mbox_rd_en), .mbox_empty(mbox_empty)
    );

`include "tb_hard_common.vh"

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

    localparam [127:0] KEY   = 128'h000102030405060708090a0b0c0d0e0f;
    localparam [127:0] PTEXT = 128'h00112233445566778899aabbccddeeff;
    localparam [127:0] CTEXT = 128'h69c4e0d86a7b0430d8cdb78070b4c55a;

    // Drives the standard test vector into one AES engine (via
    // hierarchical force) and waits for its `done` pulse. `busy_seen`
    // reports whether busy was observed high at least once during the
    // computation (for the T402-style timing check).
    task run_aes;
        input  [7:0]  which;   // 0=aes0 1=aes1 2=aes2 3=aes3
        output        busy_seen;
        output [127:0] result;
        integer i;
        begin
            busy_seen = 1'b0;
            case (which)
                8'd0: begin
                    force dut.u_aes0.key_in = KEY; force dut.u_aes0.key_valid = 1'b1;
                    force dut.u_aes0.data_in = PTEXT; force dut.u_aes0.start = 1'b0; force dut.u_aes0.encrypt = 1'b1;
                    @(posedge clk);
                    force dut.u_aes0.start = 1'b1;
                    @(posedge clk);
                    force dut.u_aes0.start = 1'b0; force dut.u_aes0.key_valid = 1'b0;
                    for (i = 0; i < 15; i = i + 1) begin
                        @(posedge clk);
                        if (dut.u_aes0.busy) busy_seen = 1'b1;
                        if (dut.u_aes0.done) begin
                            result = dut.u_aes0.data_out;
                            i = 15;
                        end
                    end
                    release dut.u_aes0.key_in; release dut.u_aes0.key_valid;
                    release dut.u_aes0.data_in; release dut.u_aes0.start; release dut.u_aes0.encrypt;
                end
                8'd1: begin
                    force dut.u_aes1.key_in = KEY; force dut.u_aes1.key_valid = 1'b1;
                    force dut.u_aes1.data_in = PTEXT; force dut.u_aes1.start = 1'b0; force dut.u_aes1.encrypt = 1'b1;
                    @(posedge clk);
                    force dut.u_aes1.start = 1'b1;
                    @(posedge clk);
                    force dut.u_aes1.start = 1'b0; force dut.u_aes1.key_valid = 1'b0;
                    for (i = 0; i < 15; i = i + 1) begin
                        @(posedge clk);
                        if (dut.u_aes1.busy) busy_seen = 1'b1;
                        if (dut.u_aes1.done) begin
                            result = dut.u_aes1.data_out;
                            i = 15;
                        end
                    end
                    release dut.u_aes1.key_in; release dut.u_aes1.key_valid;
                    release dut.u_aes1.data_in; release dut.u_aes1.start; release dut.u_aes1.encrypt;
                end
                8'd2: begin
                    force dut.u_aes2.key_in = KEY; force dut.u_aes2.key_valid = 1'b1;
                    force dut.u_aes2.data_in = PTEXT; force dut.u_aes2.start = 1'b0; force dut.u_aes2.encrypt = 1'b1;
                    @(posedge clk);
                    force dut.u_aes2.start = 1'b1;
                    @(posedge clk);
                    force dut.u_aes2.start = 1'b0; force dut.u_aes2.key_valid = 1'b0;
                    for (i = 0; i < 15; i = i + 1) begin
                        @(posedge clk);
                        if (dut.u_aes2.busy) busy_seen = 1'b1;
                        if (dut.u_aes2.done) begin
                            result = dut.u_aes2.data_out;
                            i = 15;
                        end
                    end
                    release dut.u_aes2.key_in; release dut.u_aes2.key_valid;
                    release dut.u_aes2.data_in; release dut.u_aes2.start; release dut.u_aes2.encrypt;
                end
                default: begin
                    force dut.u_aes3.key_in = KEY; force dut.u_aes3.key_valid = 1'b1;
                    force dut.u_aes3.data_in = PTEXT; force dut.u_aes3.start = 1'b0; force dut.u_aes3.encrypt = 1'b1;
                    @(posedge clk);
                    force dut.u_aes3.start = 1'b1;
                    @(posedge clk);
                    force dut.u_aes3.start = 1'b0; force dut.u_aes3.key_valid = 1'b0;
                    for (i = 0; i < 15; i = i + 1) begin
                        @(posedge clk);
                        if (dut.u_aes3.busy) busy_seen = 1'b1;
                        if (dut.u_aes3.done) begin
                            result = dut.u_aes3.data_out;
                            i = 15;
                        end
                    end
                    release dut.u_aes3.key_in; release dut.u_aes3.key_valid;
                    release dut.u_aes3.data_in; release dut.u_aes3.start; release dut.u_aes3.encrypt;
                end
            endcase
        end
    endtask

    reg busy_seen;
    reg [127:0] result;

    initial begin
        cpu_awaddr=0; cpu_awvalid=0; cpu_wdata=0; cpu_wstrb=0; cpu_wvalid=0; cpu_bready=0;
        cpu_araddr=0; cpu_arvalid=0; cpu_rready=0;
        por_n = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk); por_n = 1'b1;
        while (dut.sys_rst_n !== 1'b1) @(posedge clk);
        repeat (4) @(posedge clk);

        // ---- T401: aes0 - real AES-128 encryption, checked against the
        // standard NIST FIPS-197 test vector ----
        run_aes(0, busy_seen, result);
        check(result === CTEXT, "T401");

        // ---- T402: busy was observed high during the computation ----
        check(busy_seen === 1'b1, "T402");

        // ---- T403: done returns to 0 the cycle after asserting (single-
        // cycle pulse, not stuck high) ----
        repeat (2) @(posedge clk);
        check(dut.u_aes0.done === 1'b0, "T403");

        // ---- T404/T405/T406: the other three engines are independent,
        // correctly-instantiated cores producing the SAME correct result
        // for the SAME inputs ----
        run_aes(1, busy_seen, result);
        check(result === CTEXT, "T404");
        run_aes(2, busy_seen, result);
        check(result === CTEXT, "T405");
        run_aes(3, busy_seen, result);
        check(result === CTEXT, "T406");

        // ---- T407: aes3's own done pulse (irq_crypto_src[3]) correctly
        // aggregates - fire ONLY aes3 (fresh, after clearing any prior
        // pending state is impossible without a register write, so this
        // checks id resolves to the HIGHEST pending source: after the
        // T401/404/405/406 runs above, src[0..3] are all pending, so vid
        // should be 3, the top of the 4 AES sources) ----
        // r_pend latches on a clock edge, so give it one cycle to catch
        // up with aes3's just-observed done pulse before checking it.
        repeat (2) @(posedge clk);
        check(cpu_crypto_irq === 1'b1 && cpu_crypto_irq_id === 3'd3, "T407");

        // ---- T408: the AES-node's own co-located SRAM (sram_30,
        // co-located with aes0 at node (3,0) per the architecture doc)
        // still functions correctly via normal CPU NoC routing - the AES
        // engine's presence doesn't interfere with the SRAM's real
        // function ----
        axi_write({4'd3, 4'd0, 16'b0, 8'd1}, 32'hFEED_AE50);
        repeat (6) @(posedge clk);
        check(dut.u_noc_mesh.u_sram_30.mem[1][31:0] === 32'hFEED_AE50, "T408");

        if (errors == 0) $display("AES_BASIC SCORE: 8/8");
        else $display("AES_BASIC SCORE: %0d/8", 8 - errors);
        $finish;
    end

    initial begin
        #150000;
        $display("[TIMEOUT]");
        $finish;
    end
endmodule
