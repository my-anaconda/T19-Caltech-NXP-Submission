// Shared AHB-Lite CPU bus-functional-model tasks for the easy-tier
// (secure_periph_soc) custom testbenches. `include`d by each per-category
// tb_easy_*.v file. Adapted directly from the organizer's own
// tb_top_skeleton.v ahb_write/ahb_read tasks (same drive-on-negedge,
// poll-hready convention) so every category drives the bus identically
// and matches the reference timing exactly.

task ahb_write;
    input [31:0] addr, data;
    input [2:0]  prot;
    begin
        @(negedge clk);
        cpu_haddr=addr; cpu_htrans=2'b10; cpu_hwrite=1;
        cpu_hprot=prot; cpu_hwdata=data;
        cpu_hsize=3'b010; cpu_hburst=0;
        @(posedge clk); #1;
        while (!cpu_hready) begin @(posedge clk); #1; end
        @(negedge clk); cpu_htrans=2'b00; cpu_hwrite=0;
        @(posedge clk); #1;
    end
endtask

task ahb_read;
    input  [31:0] addr;
    input  [2:0]  prot;
    output [31:0] rdata;
    output [1:0]  resp;
    begin
        @(negedge clk);
        cpu_haddr=addr; cpu_htrans=2'b10; cpu_hwrite=0;
        cpu_hprot=prot; cpu_hsize=3'b010; cpu_hburst=0;
        @(posedge clk); #1;
        while (!cpu_hready) begin @(posedge clk); #1; end
        rdata = cpu_hrdata; resp = cpu_hresp;
        @(negedge clk); cpu_htrans=2'b00;
        @(posedge clk); #1;
    end
endtask

// Privileged-access convenience wrapper (hprot[0]=1), needed for the
// watchdog slave (S3).
task ahb_write_priv;
    input [31:0] addr, data;
    begin
        ahb_write(addr, data, 3'b001);
    end
endtask

task ahb_read_priv;
    input  [31:0] addr;
    output [31:0] rdata;
    output [1:0]  resp;
    begin
        ahb_read(addr, 3'b001, rdata, resp);
    end
endtask

// Unprivileged-access convenience wrapper (hprot[0]=0).
task ahb_write_user;
    input [31:0] addr, data;
    begin
        ahb_write(addr, data, 3'b000);
    end
endtask

task ahb_read_user;
    input  [31:0] addr;
    output [31:0] rdata;
    output [1:0]  resp;
    begin
        ahb_read(addr, 3'b000, rdata, resp);
    end
endtask
