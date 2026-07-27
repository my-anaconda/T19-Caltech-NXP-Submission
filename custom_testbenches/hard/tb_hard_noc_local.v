`timescale 1ns/1ps
// Custom testbench for the hard-tier (crypto_soc) "noc_local" category
// (T201-T206): local-node NoC delivery - the CPU (which always enters the
// mesh at node (0,0)) writes/reads its OWN co-located SRAM, without any
// inter-router forwarding. Per the architecture doc: "The router drives
// its AXI ports directly (no NI on the local path)" and dest_x==NODE_X &&
// dest_y==NODE_Y routes locally (dest_sel=0 in gen_router_v2.py) rather
// than out any compass port.
module tb_hard_noc_local;
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
    reg [31:0] rdval;

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

    initial begin
        cpu_awaddr=0; cpu_awvalid=0; cpu_wdata=0; cpu_wstrb=0; cpu_wvalid=0; cpu_bready=0;
        cpu_araddr=0; cpu_arvalid=0; cpu_rready=0;
        por_n = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk); por_n = 1'b1;
        while (dut.sys_rst_n !== 1'b1) @(posedge clk);
        repeat (4) @(posedge clk);

        // ---- T201: local write lands in node (0,0)'s own SRAM ----
        axi_write(32'h0000_0000, 32'hAAAA_0201);
        repeat (3) @(posedge clk);
        check(dut.u_noc_mesh.u_sram_00.mem[0][31:0] === 32'hAAAA_0201, "T201");

        // ---- T202: local read returns what was just written ----
        axi_read(32'h0000_0000, rdval);
        check(rdval === 32'hAAAA_0201, "T202");

        // ---- T203: a different local word address is isolated (no
        // aliasing with word 0) ----
        axi_write(32'h0000_0005, 32'hBBBB_0203);
        repeat (3) @(posedge clk);
        check(dut.u_noc_mesh.u_sram_00.mem[5][31:0] === 32'hBBBB_0203 &&
              dut.u_noc_mesh.u_sram_00.mem[0][31:0] === 32'hAAAA_0201, "T203");

        // ---- T204: back-to-back writes to two more distinct words both
        // land correctly (router FSM correctly returns to S_IDLE and
        // accepts a fresh transaction immediately after) ----
        axi_write(32'h0000_0006, 32'hCCCC_0204);
        axi_write(32'h0000_0007, 32'hDDDD_0204);
        repeat (3) @(posedge clk);
        check(dut.u_noc_mesh.u_sram_00.mem[6][31:0] === 32'hCCCC_0204 &&
              dut.u_noc_mesh.u_sram_00.mem[7][31:0] === 32'hDDDD_0204, "T204");

        // ---- T205: read-after-write consistency on a fresh address ----
        axi_write(32'h0000_0008, 32'hEEEE_0205);
        axi_read(32'h0000_0008, rdval);
        check(rdval === 32'hEEEE_0205, "T205");

        // ---- T206: a purely local transaction never asserts ANY of node
        // (0,0)'s router's compass master ports (structural proof it took
        // the local delivery path, not a routed one) ----
        begin : t206_block
            reg any_compass_active;
            any_compass_active = 1'b0;
            fork
                axi_write(32'h0000_0009, 32'hFFFF_0206);
                begin
                    repeat (30) begin
                        @(posedge clk);
                        if (dut.u_noc_mesh.u_router_00.p0_m_a_valid ||
                            dut.u_noc_mesh.u_router_00.p1_m_a_valid ||
                            dut.u_noc_mesh.u_router_00.p2_m_a_valid ||
                            dut.u_noc_mesh.u_router_00.p3_m_a_valid)
                            any_compass_active = 1'b1;
                    end
                end
            join
            check(!any_compass_active, "T206");
        end

        if (errors == 0) $display("NOC_LOCAL SCORE: 6/6");
        else $display("NOC_LOCAL SCORE: %0d/6", 6 - errors);
        $finish;
    end

    initial begin
        #100000;
        $display("[TIMEOUT]");
        $finish;
    end
endmodule
