// Shared AXI4-Lite CPU bus-functional-model tasks for the medium-tier
// (noc_aes_soc) custom testbenches. `include`d by each per-category
// tb_medium_*.v file so every category drives the CPU bus the same way.
// Plain Verilog-2001 (iverilog -g2005 compatible) - no ANSI task ports,
// no `automatic`, every task body wrapped in begin/end.
//
// Unlike the hard tier, the CPU AXI4-Lite bus here is 64-bit
// (cpu_wdata[63:0]/cpu_wstrb[7:0]/cpu_rdata[63:0] per tb_top_skeleton.v),
// even though the actual NoC-mesh data path underneath is 32-bit (Step 4
// truncates cpu_wdata[31:0] on writes and zero-extends cpu_rdata[63:32] on
// reads - confirmed by reading the generated noc_aes_soc.v directly).
// These BFM tasks drive/observe only the low 32 bits of data, which is
// robust to that truncation regardless of exactly how a given
// regeneration implements the 64-to-32-bit bridging.

task axi_write;
    input [31:0] addr;
    input [31:0] data;
    begin
        @(posedge clk);
        cpu_awaddr = addr; cpu_awvalid = 1'b1;
        cpu_wdata = {32'h0, data}; cpu_wstrb = 8'hFF; cpu_wvalid = 1'b1;
        cpu_bready = 1'b1;
        // A 1ns settle delay (comfortably inside the 10ns clock period)
        // before the FIRST readiness check: reading a combinational
        // signal several levels of hierarchy away (cpu_awvalid ->
        // n00_awvalid -> axi_awvalid) in the SAME simulation time step as
        // the blocking assignment that drives it, with no intervening
        // clock edge, races the propagation delta-cycles - found via a
        // real hang even after removing the extra-edge bug below (the
        // very first check was reading stale, pre-propagation values).
        // Every check AFTER this one is naturally safe (gated by a real
        // @(posedge clk), which by IEEE scheduling semantics only resumes
        // after that edge's NBA updates have fully committed).
        #1;
        // Unlike the hard-tier BFM, do NOT insert an extra unconditional
        // @(posedge clk) here before polling awready/wready: the medium
        // tier's NI (u_ni_XY, tilelink_ni) can accept on the VERY SAME
        // cycle awvalid/wvalid are first raised (a genuine zero-wait-state
        // handshake, confirmed by reading u_ni_00.v directly - awready is
        // a plain `assign` off the current (pre-this-edge) state/valid,
        // no registered handshake stage). An extra blind edge before the
        // first poll always lands one cycle too late to see that window,
        // hanging forever - found via a real simulation hang against
        // t19_medium_test3, root-caused by tracing awready/st/is_write
        // directly. The hard-tier BFM's identical extra-edge pattern
        // happens to be masked there by u_xbar's own extra arbitration
        // latency, so it's deliberately left as-is (proven across all 96
        // hard-tier checks) - this is a tier-specific fix, not a general
        // one.
        while (!(cpu_awready && cpu_wready)) @(posedge clk);
        // Hold awvalid/wvalid through bvalid, same universal BFM lesson
        // as the hard tier (a combinational B-response path can lose
        // track of which transaction to ack if they drop early).
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
        // Same same-cycle-ready / settle-delay reasoning as axi_write above.
        #1;
        while (!cpu_arready) @(posedge clk);
        while (!cpu_rvalid) @(posedge clk);
        data = cpu_rdata[31:0];
        cpu_arvalid = 1'b0;
        @(posedge clk);
        cpu_rready = 1'b0;
    end
endtask

// Drives por_n low for `cycles` clk periods then releases it.
task pulse_reset;
    input integer cycles;
    integer i;
    begin
        por_n = 1'b0;
        for (i = 0; i < cycles; i = i + 1) @(posedge clk);
    end
endtask

function [31:0] node_addr;
    input [3:0] dx;
    input [3:0] dy;
    input [23:0] word;
    node_addr = {dx, dy, word};
endfunction
