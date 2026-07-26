"""
Corrected axi_lite_sram generator - fixes a real, pre-existing bug in the
organizer-provided rtl_gen_lib version: its write-data-capture loop
hardcodes `for (bi=0; bi<4; bi=bi+1)`, touching only the first 4 bytes of
`mem[wr_addr_r]` regardless of the module's own DATA_W parameter. For any
instance configured with data_width=64 (which is what every node-local
SRAM in the hard-tier crypto_soc mesh uses, per the architecture doc),
this means bytes 4-7 of every word are NEVER written by ANY caller,
through ANY path - confirmed via real simulation (see NOTES.md "NoC mesh
end-to-end verified"): a full-stack CPU write correctly traversed two
router hops and landed with byte-perfect accuracy in the low 32 bits of
the target SRAM word, while the upper 32 bits stayed permanently 'x'
because the write loop's own hardcoded byte count never reaches them - a
generator bug, not a mesh-wiring bug (the read path already correctly
returns the full DATA_W-wide word; only the write path's byte loop and
its always-4-bit-wide `wstrb` port were wrong for DATA_W != 32).

Fix: derive the byte count and the wstrb port width from DATA_W, same as
every other generator in this library already does (e.g. gen_tilelink_ni's
own sw = dw // 8).
"""
from gen_utils import hdr as _hdr


def gen_axi_lite_sram_v2(spec):
    n = spec.get("name", "axi_lite_sram")
    d = int(spec.get("depth", 1024))
    dw = int(spec.get("data_width", 32))
    aw = int(spec.get("addr_width", 32))
    ab = max(1, (d - 1).bit_length())
    sw = dw // 8

    code = _hdr(n, f"AXI4-Lite slave SRAM depth={d} data_width={dw} (v2 - correct full-width wstrb)")
    code += f"""\
module {n} #(
    parameter DEPTH  = {d},
    parameter DATA_W = {dw},
    parameter ADDR_W = {aw},
    parameter ABITS  = {ab},
    parameter MASK_W = {sw}
)(
    input  wire            aclk, aresetn,
    // Write address channel
    input  wire [ADDR_W-1:0] awaddr, input wire awvalid, output reg awready,
    // Write data channel
    input  wire [DATA_W-1:0] wdata, input wire [MASK_W-1:0] wstrb,
    input  wire wvalid, output reg wready,
    // Write response
    output reg  [1:0] bresp, output reg bvalid, input wire bready,
    // Read address channel
    input  wire [ADDR_W-1:0] araddr, input wire arvalid, output reg arready,
    // Read data channel
    output reg  [DATA_W-1:0] rdata, output reg [1:0] rresp,
    output reg  rvalid, input wire rready
);
    reg [DATA_W-1:0] mem [0:DEPTH-1];
    reg [ABITS-1:0] wr_addr_r;
    reg pending_w;
    integer bi;

    // Write path
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            awready<=0; wready<=0; bvalid<=0; bresp<=0; pending_w<=0;
        end else begin
            awready <= !pending_w && awvalid && !awready;
            if (awvalid && awready) begin wr_addr_r<=awaddr[ABITS-1:0]; pending_w<=1; end
            wready <= pending_w && wvalid && !wready;
            if (pending_w && wvalid && wready) begin
                for (bi=0; bi<MASK_W; bi=bi+1)
                    if (wstrb[bi]) mem[wr_addr_r][bi*8+:8] <= wdata[bi*8+:8];
                pending_w<=0; bvalid<=1; bresp<=0;
            end
            if (bvalid && bready) bvalid<=0;
        end
    end

    // Read path
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin arready<=0; rvalid<=0; rdata<=0; rresp<=0; end
        else begin
            arready <= arvalid && !arready && !rvalid;
            if (arvalid && arready) begin
                rdata  <= mem[araddr[ABITS-1:0]];
                rresp  <= 0;
                rvalid <= 1;
            end
            if (rvalid && rready) rvalid<=0;
        end
    end
endmodule
"""
    return {f"{n}.v": code}
