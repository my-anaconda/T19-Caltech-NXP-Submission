`timescale 1ns/1ps
// Custom testbench for the medium-tier (noc_aes_soc) "noc_2hop" category
// (T1101-T1103). The mesh's only genuine 2-hop (East THEN South, per
// XY-first routing) destination from the CPU's own entry node (0,0) is
// (1,1) - E to (1,0), then S to (1,1), then deliver. (1,2) needs 3 hops
// (E,S,S) and is already covered by noc_ew_routing/noc_ns_routing's own
// column checks; this category isolates the EXACT 2-hop case.
module tb_medium_noc_2hop;
    reg clk = 0, por_n;
    always #5 clk = ~clk;

    reg  [31:0] cpu_awaddr;  reg  cpu_awvalid; wire cpu_awready;
    reg  [63:0] cpu_wdata;   reg  [7:0] cpu_wstrb;
    reg         cpu_wvalid;  wire cpu_wready;
    wire [1:0]  cpu_bresp;   wire cpu_bvalid;  reg  cpu_bready;
    reg  [31:0] cpu_araddr;  reg  cpu_arvalid; wire cpu_arready;
    wire [63:0] cpu_rdata;   wire [1:0] cpu_rresp;
    wire        cpu_rvalid;  reg  cpu_rready;
    reg  [127:0] aes0_key_in; reg aes0_key_valid; reg [127:0] aes0_data_in; reg aes0_start;
    wire [127:0] aes0_data_out; wire aes0_done; wire aes0_busy;
    reg  [127:0] aes1_key_in; reg aes1_key_valid; reg [127:0] aes1_data_in; reg aes1_start;
    wire [127:0] aes1_data_out; wire aes1_done; wire aes1_busy;
    wire cpu_irq; wire [2:0] cpu_irq_id;

    noc_aes_soc dut (
        .clk(clk), .por_n(por_n),
        .cpu_awaddr(cpu_awaddr), .cpu_awvalid(cpu_awvalid), .cpu_awready(cpu_awready),
        .cpu_wdata(cpu_wdata), .cpu_wstrb(cpu_wstrb), .cpu_wvalid(cpu_wvalid), .cpu_wready(cpu_wready),
        .cpu_bresp(cpu_bresp), .cpu_bvalid(cpu_bvalid), .cpu_bready(cpu_bready),
        .cpu_araddr(cpu_araddr), .cpu_arvalid(cpu_arvalid), .cpu_arready(cpu_arready),
        .cpu_rdata(cpu_rdata), .cpu_rresp(cpu_rresp), .cpu_rvalid(cpu_rvalid), .cpu_rready(cpu_rready),
        .aes0_key_in(aes0_key_in), .aes0_key_valid(aes0_key_valid),
        .aes0_data_in(aes0_data_in), .aes0_start(aes0_start),
        .aes0_data_out(aes0_data_out), .aes0_done(aes0_done), .aes0_busy(aes0_busy),
        .aes1_key_in(aes1_key_in), .aes1_key_valid(aes1_key_valid),
        .aes1_data_in(aes1_data_in), .aes1_start(aes1_start),
        .aes1_data_out(aes1_data_out), .aes1_done(aes1_done), .aes1_busy(aes1_busy),
        .cpu_irq(cpu_irq), .cpu_irq_id(cpu_irq_id)
    );

`include "tb_medium_common.vh"

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

    reg [31:0] rdval;

    initial begin
        cpu_awaddr=0; cpu_awvalid=0; cpu_wdata=0; cpu_wstrb=0; cpu_wvalid=0; cpu_bready=0;
        cpu_araddr=0; cpu_arvalid=0; cpu_rready=0;
        aes0_key_in=0; aes0_key_valid=0; aes0_data_in=0; aes0_start=0;
        aes1_key_in=0; aes1_key_valid=0; aes1_data_in=0; aes1_start=0;
        por_n = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk); por_n = 1'b1;
        while (dut.sys_rst_n !== 1'b1) @(posedge clk);
        repeat (4) @(posedge clk);

        // ---- T1101: a real 2-hop (E then S) write to (1,1) lands
        // correctly in that node's own SRAM ----
        axi_write(node_addr(4'd1, 4'd1, 24'd50), 32'hF00D_1101);
        check(dut.u_noc_mesh.u_sram_11.mem[50] === 32'hF00D_1101, "T1101");

        // ---- T1102: aes1 (co-located at (1,1)) stays fully functional
        // and independent - the 2-hop router traffic doesn't interfere
        // with the AES engine sitting at the same node ----
        aes1_key_in = 128'h000102030405060708090a0b0c0d0e0f;
        aes1_key_valid = 1'b1;
        aes1_data_in = 128'h00112233445566778899aabbccddeeff;
        aes1_start = 1'b0;
        @(posedge clk);
        aes1_start = 1'b1;
        @(posedge clk);
        aes1_start = 1'b0; aes1_key_valid = 1'b0;
        begin : t1102_wait
            integer i;
            for (i = 0; i < 15; i = i + 1) begin
                @(posedge clk);
                if (aes1_done) i = 15;
            end
        end
        check(aes1_data_out === 128'h69c4e0d86a7b0430d8cdb78070b4c55a, "T1102");

        // ---- T1103: back-to-back 2-hop writes to TWO different offsets
        // at (1,1) both land correctly (repeated multi-hop transactions
        // don't confuse the router's single-outstanding-transaction
        // state) ----
        axi_write(node_addr(4'd1, 4'd1, 24'd51), 32'hF00D_1103);
        axi_write(node_addr(4'd1, 4'd1, 24'd52), 32'hF00D_1104);
        begin : t1103_block
            reg both_ok;
            both_ok = 1'b1;
            axi_read(node_addr(4'd1, 4'd1, 24'd51), rdval);
            if (rdval !== 32'hF00D_1103) both_ok = 1'b0;
            axi_read(node_addr(4'd1, 4'd1, 24'd52), rdval);
            if (rdval !== 32'hF00D_1104) both_ok = 1'b0;
            check(both_ok, "T1103");
        end

        if (errors == 0) $display("NOC_2HOP SCORE: 3/3");
        else $display("NOC_2HOP SCORE: %0d/3", 3 - errors);
        $finish;
    end

    initial begin
        #150000;
        $display("[TIMEOUT]");
        $finish;
    end
endmodule
