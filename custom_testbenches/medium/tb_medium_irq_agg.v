`timescale 1ns/1ps
// Custom testbench for the medium-tier (noc_aes_soc) "irq_agg" category
// (T501-T504). Unlike hard tier's dual aggregators (which have a real,
// if unreliable, CPU-visible address in some regenerations), medium's
// architecture doc has NO documented CPU address for u_irq_agg at all -
// confirmed directly: the generated top-level ties its psel/penable/
// pwrite permanently to 1'b0 ("Dummy APB tie-off interface"). So this
// exercises the real aggregator register interface via hierarchical
// force/release directly on u_irq_agg's own APB-style port, the same
// technique tb_hard_irq_crypto.v uses for the same underlying reason.
// Real aes0/aes1 done pulses (via the direct top-level ports, same as
// aes0_encrypt/aes1_encrypt) drive the actual irq_src inputs - not a
// synthetic force of irq_src itself - so this is a genuine integration
// check of AES-done -> aggregator -> cpu_irq, not an isolated unit test.
module tb_medium_irq_agg;
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

    localparam [127:0] KEY   = 128'h000102030405060708090a0b0c0d0e0f;
    localparam [127:0] PTEXT = 128'h00112233445566778899aabbccddeeff;

    task run_aes0;
        integer i;
        begin
            aes0_key_in = KEY; aes0_key_valid = 1'b1;
            aes0_data_in = PTEXT; aes0_start = 1'b0;
            @(posedge clk);
            aes0_start = 1'b1;
            @(posedge clk);
            aes0_start = 1'b0; aes0_key_valid = 1'b0;
            for (i = 0; i < 15; i = i + 1) begin
                @(posedge clk);
                if (aes0_done) i = 15;
            end
        end
    endtask

    task run_aes1;
        integer i;
        begin
            aes1_key_in = KEY; aes1_key_valid = 1'b1;
            aes1_data_in = PTEXT; aes1_start = 1'b0;
            @(posedge clk);
            aes1_start = 1'b1;
            @(posedge clk);
            aes1_start = 1'b0; aes1_key_valid = 1'b0;
            for (i = 0; i < 15; i = i + 1) begin
                @(posedge clk);
                if (aes1_done) i = 15;
            end
        end
    endtask

    // Clears all pending state via u_irq_agg's own APB-style port
    // (force/release, since the top-level ties it permanently idle).
    task irq_agg_clear_all;
        begin
            force dut.u_irq_agg.psel = 1'b1; force dut.u_irq_agg.penable = 1'b1;
            force dut.u_irq_agg.pwrite = 1'b1; force dut.u_irq_agg.paddr = 12'h014;
            force dut.u_irq_agg.pwdata = 32'hFFFF_FFFF;
            @(posedge clk);
            release dut.u_irq_agg.psel; release dut.u_irq_agg.penable;
            release dut.u_irq_agg.pwrite; release dut.u_irq_agg.paddr;
            release dut.u_irq_agg.pwdata;
            repeat (2) @(posedge clk);
        end
    endtask

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

        // ---- T501: only aes0 pending -> cpu_irq_id = 0 (src[0]) ----
        run_aes0;
        repeat (2) @(posedge clk);
        check(cpu_irq === 1'b1 && cpu_irq_id === 3'd0, "T501");
        irq_agg_clear_all;

        // ---- T502: only aes1 pending -> cpu_irq_id = 1 (src[1]) ----
        run_aes1;
        repeat (2) @(posedge clk);
        check(cpu_irq === 1'b1 && cpu_irq_id === 3'd1, "T502");
        irq_agg_clear_all;

        // ---- T503: both pending simultaneously -> lowest id (0) wins,
        // per the doc's own "lowest active source ID" contract ----
        run_aes0;
        run_aes1;
        repeat (2) @(posedge clk);
        check(cpu_irq === 1'b1 && cpu_irq_id === 3'd0, "T503");

        // ---- T504: after clearing, cpu_irq correctly deasserts (both
        // sources genuinely cleared, not just id changing) ----
        irq_agg_clear_all;
        check(cpu_irq === 1'b0, "T504");

        if (errors == 0) $display("IRQ_AGG SCORE: 4/4");
        else $display("IRQ_AGG SCORE: %0d/4", 4 - errors);
        $finish;
    end

    initial begin
        #150000;
        $display("[TIMEOUT]");
        $finish;
    end
endmodule
