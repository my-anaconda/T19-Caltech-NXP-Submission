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

Second fix (found via tb_medium_reset_sync.v's T105 against a real
regeneration, t19_medium_test3): the original write-path `awready`/`wready`
were each a SELF-REFERENTIAL one-cycle toggle (`awready <= !pending_w &&
awvalid && !awready`) - each one flips on then off on alternating clock
cycles by construction, independently of the other. `tilelink_router`'s
own local-delivery path (the only caller that matters here - the router
drives this SRAM directly, no NI in between) waits for `sram_awready &&
sram_wready` to be true on the SAME cycle before advancing past S_SEND.
Two independently-alternating one-cycle pulses are never guaranteed to
land on the same cycle - confirmed directly via simulation: they never
did, for any number of cycles observed, hanging the router (and therefore
every CPU write to a node's own local SRAM) forever. Not caught earlier
because the hard tier's own 96/96 passing custom-testbench suite never
happens to route a write through this exact LOCAL (dest_sel==0) path in
a way that exposed it (DMA's own master port has different timing than a
CPU/NI-driven write); the medium tier's simpler topology hits it
immediately since the CPU enters directly at node (0,0), its own local
node. Rewritten below using simple state latches (`have_aw`/`have_w`)
so awready/wready are plain "ready when idle" signals (asserted together,
not oscillating), correctly handling both the same-cycle AW+W convention
every BFM in this codebase uses AND staggered AW/W arrival per the AXI4
spec.
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

    // Write path - awready/wready are plain "ready when idle" signals
    // (asserted TOGETHER whenever neither AW nor W has already been
    // latched for the in-flight transaction), not the self-referential
    // toggle this had before. have_aw/have_w let AW and W arrive on
    // different cycles (per the AXI4 spec) while still completing in a
    // single cycle for the same-cycle AW+W convention every BFM in this
    // codebase actually uses.
    reg have_aw, have_w;
    reg [DATA_W-1:0] w_data_r;
    reg [MASK_W-1:0] w_mask_r;
    wire do_aw = awvalid && awready;
    wire do_w  = wvalid && wready;

    always @(*) begin
        awready = !pending_w && !have_aw;
        wready  = !pending_w && !have_w;
    end

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            bvalid<=0; bresp<=0; pending_w<=0; have_aw<=0; have_w<=0;
            wr_addr_r<=0; w_data_r<=0; w_mask_r<=0;
        end else begin
            if (do_aw) begin wr_addr_r <= awaddr[ABITS-1:0]; have_aw <= 1'b1; end
            if (do_w)  begin w_data_r  <= wdata; w_mask_r <= wstrb; have_w <= 1'b1; end
            if (!pending_w && (have_aw || do_aw) && (have_w || do_w)) begin
                for (bi=0; bi<MASK_W; bi=bi+1)
                    if (do_w ? wstrb[bi] : w_mask_r[bi])
                        mem[do_aw ? awaddr[ABITS-1:0] : wr_addr_r][bi*8+:8] <=
                            (do_w ? wdata[bi*8+:8] : w_data_r[bi*8+:8]);
                pending_w<=1; bvalid<=1; bresp<=0; have_aw<=0; have_w<=0;
            end
            if (bvalid && bready) begin bvalid<=0; pending_w<=0; end
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
