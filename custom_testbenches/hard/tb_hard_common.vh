// Shared AXI4-Lite CPU bus-functional-model tasks for the hard-tier
// (crypto_soc) custom testbenches. `include`d by each per-category
// tb_hard_*.v file so every category drives the CPU bus the same way.
// Plain Verilog-2001 (iverilog -g2005 compatible) - no ANSI task ports,
// no `automatic`, every task body wrapped in begin/end.

task axi_write;
    input [31:0] addr;
    input [31:0] data;
    begin
        @(posedge clk);
        cpu_awaddr = addr; cpu_awvalid = 1'b1;
        cpu_wdata = data; cpu_wstrb = 4'hF; cpu_wvalid = 1'b1;
        cpu_bready = 1'b1;
        @(posedge clk);
        while (!(cpu_awready && cpu_wready)) @(posedge clk);
        // u_xbar's B-response routing is purely combinational off the
        // CURRENT m0_awvalid/address (it re-derives which slave to route
        // the response from every cycle, not a latched transaction ID) -
        // dropping awvalid/wvalid immediately after the AW/W handshake (as
        // real AXI4-Lite masters are normally free to do) makes the
        // crossbar lose track of which slave's bvalid to forward, so
        // bvalid then never reaches the master. Found via a real hang in
        // a custom testbench, not elaboration. Holding awvalid/wvalid
        // through bvalid is always spec-legal even where not required, so
        // this is a safe, universal fix for this BFM rather than a
        // DUT patch.
        while (!cpu_bvalid) @(posedge clk);
        cpu_awvalid = 1'b0; cpu_wvalid = 1'b0;
        @(posedge clk);
        cpu_bready = 1'b0;
    end
endtask

task axi_read;
    input  [31:0] addr;
    output [31:0] data;
    begin
        @(posedge clk);
        cpu_araddr = addr; cpu_arvalid = 1'b1;
        cpu_rready = 1'b1;
        @(posedge clk);
        while (!cpu_arready) @(posedge clk);
        // Same reasoning as axi_write: hold arvalid until rvalid, since the
        // crossbar's read-response routing is also purely combinational off
        // the current araddr/arvalid, not a latched transaction ID.
        while (!cpu_rvalid) @(posedge clk);
        data = cpu_rdata;
        cpu_arvalid = 1'b0;
        @(posedge clk);
        cpu_rready = 1'b0;
    end
endtask

// Drives por_n low for `cycles` clk periods then releases it - the only
// externally-controllable reset stimulus (wdt_rst_n is tied internally,
// not exposed at the top-level port list per tb_top_skeleton.v).
task pulse_reset;
    input integer cycles;
    integer i;
    begin
        por_n = 1'b0;
        for (i = 0; i < cycles; i = i + 1) @(posedge clk);
    end
endtask
