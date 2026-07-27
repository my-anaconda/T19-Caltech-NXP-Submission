"""
Corrected tilelink_ni generator - fixes a real, genuine off-by-one race in
the organizer-provided rtl_gen_lib version's response-valid logic.

Bug (found via a real hang in a custom testbench, not elaboration): the
original generator computes
    assign axi_bvalid = (st==S_IDLE) && is_write && tl_d_valid && ...;
    assign axi_rvalid = (st==S_IDLE) && !is_write && tl_d_valid && ...;
i.e. it requires BOTH "I have already moved on to S_IDLE" AND "the
responder's tl_d_valid is still asserted" to be true in the SAME cycle.
But the NI only ever transitions S_WAIT->S_IDLE in reaction to tl_d_valid
(`S_WAIT: if (tl_d_valid) st<=S_IDLE;`), and the router on the other end
of that D-channel transitions out of its own reply state in that exact
same edge (its `S_REPLY: if (loc_d_ready) st<=S_IDLE;`, with tl_d_ready
unconditionally 1 during S_WAIT) - so by the very next cycle where NI's
own `st` FIRST reads as S_IDLE, the sender has already dropped tl_d_valid
in that same transition. The AND of "st==S_IDLE" and "tl_d_valid" can
structurally never both be true - axi_bvalid/axi_rvalid never actually
fire, only appearing to "work" in an unfixed setup because of an
unrelated bug elsewhere corrupting the signal to 'x' (which some
constructs treat as falsy) rather than a genuine 0 or 1.

Fix #1: check the response while STILL in S_WAIT (the same cycle
tl_d_ready is unconditionally 1, so the two are already guaranteed to
overlap), not after having already left it.

Fix #2 (found via the SAME real testbench, one category later - a second
back-to-back WRITE hung on its own AW handshake even though NI was
correctly back in S_IDLE): the original `axi_awready = (st==S_IDLE) &&
axi_awvalid && !is_write;` gates acceptance of a NEW write request on
`is_write` being 0 - but `is_write` is a REGISTER that holds the type of
the PREVIOUS transaction, not the current one, and it is never cleared
back to 0 after a write completes. So after any write, every subsequent
write's own AW handshake is permanently blocked (`!is_write` reads as
`!1` = 0 forever) - reads are unaffected since `axi_arready` never
references `is_write`. Fixed to match `axi_wready`'s own (correct)
condition at the time: accept a new write whenever both awvalid AND
wvalid are present, regardless of what the last transaction happened
to be.

Fix #3 (found via the dma_basic category - the dma_engine generator's
own master port asserts AWVALID and WVALID on genuinely SEPARATE
cycles, a fully decoupled AXI4-Lite master, unlike the CPU BFM used
elsewhere which happens to assert both together): fix #2's condition
still implicitly required BOTH channels valid in the SAME cycle, so it
worked for the CPU path but permanently stalled a master that presents
them one at a time - `m_awvalid` alone during dma_engine's own S_WR_ADDR
state is never joined by `m_wvalid` until a LATER cycle (S_WR_DATA), by
which point `m_awvalid` itself has already dropped. `aw_seen`/`w_seen`
now latch each channel's own handshake independently (mirroring the same
fix already applied to the router's local-SRAM-write path for the same
underlying reason - a downstream module presenting two logically-linked
signals across separate cycles), so the S_IDLE capture logic accepts
either simultaneous or fully-decoupled AW/W presentation correctly.
"""
from gen_utils import hdr as _hdr


def gen_tilelink_ni_v2(spec):
    n = spec.get("name", "tl_ni")
    dw = int(spec.get("data_width", 32))
    aw = int(spec.get("addr_width", 32))
    sw = dw // 8

    code = _hdr(n, f"TileLink-UL Network Interface (AXI4-Lite -> TL-UL) data={dw}b (v2 - fixed response-valid race)")
    code += f"""\
module {n} #(
    parameter DATA_W   = {dw},
    parameter ADDR_W   = {aw},
    parameter SOURCE_W = 4,
    parameter SIZE_W   = 3,
    parameter MASK_W   = {sw}
)(
    input  wire clk, rst_n,
    // AXI4-Lite master (upstream)
    input  wire [ADDR_W-1:0] axi_awaddr, input wire axi_awvalid, output wire axi_awready,
    input  wire [DATA_W-1:0] axi_wdata,  input wire [MASK_W-1:0] axi_wstrb,
    input  wire axi_wvalid, output wire axi_wready,
    output wire [1:0] axi_bresp, output wire axi_bvalid, input wire axi_bready,
    input  wire [ADDR_W-1:0] axi_araddr, input wire axi_arvalid, output wire axi_arready,
    output wire [DATA_W-1:0] axi_rdata,  output wire [1:0] axi_rresp,
    output wire axi_rvalid, input wire axi_rready,
    // TL-UL channel A (output to NoC)
    output wire [2:0]           tl_a_opcode,
    output wire [2:0]           tl_a_param,
    output wire [SIZE_W-1:0]    tl_a_size,
    output wire [SOURCE_W-1:0]  tl_a_source,
    output wire [ADDR_W-1:0]    tl_a_addr,
    output wire [MASK_W-1:0]    tl_a_mask,
    output wire [DATA_W-1:0]    tl_a_data,
    output wire                 tl_a_valid,
    input  wire                 tl_a_ready,
    // TL-UL channel D (input from NoC)
    input  wire [2:0]           tl_d_opcode,
    input  wire [1:0]           tl_d_param,
    input  wire [SIZE_W-1:0]    tl_d_size,
    input  wire [SOURCE_W-1:0]  tl_d_source,
    input  wire [DATA_W-1:0]    tl_d_data,
    input  wire                 tl_d_valid,
    output wire                 tl_d_ready
);
    // State machine: IDLE -> SEND_A -> WAIT_D
    localparam S_IDLE=2'd0, S_SEND=2'd1, S_WAIT=2'd2;
    reg [1:0] st;
    reg [ADDR_W-1:0] r_addr; reg [DATA_W-1:0] r_wdata;
    reg [MASK_W-1:0] r_mask; reg is_write;
    // Fix #3 (see module docstring): aw_seen/w_seen latch each write
    // channel's handshake independently, so a master that presents
    // AWVALID and WVALID on SEPARATE cycles (fully decoupled channels -
    // legal AXI4-Lite master behaviour, and exactly what the dma_engine
    // generator's own master port does) is captured correctly, not just
    // a master that happens to assert both simultaneously (like the CPU
    // BFM used elsewhere in this testbench, which is what fix #2 alone
    // was implicitly assuming).
    reg aw_seen, w_seen;
    reg [ADDR_W-1:0] aw_capture;
    reg [DATA_W-1:0] w_capture;
    reg [MASK_W-1:0] wstrb_capture;

    // Fixed: no longer gated on the stale `is_write` register from the
    // PREVIOUS transaction (see module docstring, fix #2) - and no
    // longer requires the OTHER channel simultaneously (fix #3): each
    // channel is independently accepted once, latched, and the S_IDLE
    // capture below combines whichever values are live this cycle with
    // whichever were already latched on an earlier cycle.
    assign axi_awready = (st==S_IDLE) && axi_awvalid && !aw_seen;
    assign axi_wready  = (st==S_IDLE) && axi_wvalid && !w_seen;
    assign axi_arready = (st==S_IDLE) && axi_arvalid && !axi_awvalid && !aw_seen && !w_seen;
    // Fixed: check the response while STILL in S_WAIT (same cycle
    // tl_d_ready is unconditionally 1 below), not after already leaving
    // it - see module docstring for why st==S_IDLE here never fires.
    assign axi_bvalid  = (st==S_WAIT) && is_write && tl_d_valid && (tl_d_opcode==3'd0);
    assign axi_bresp   = 2'b00;
    assign axi_rvalid  = (st==S_WAIT) && !is_write && tl_d_valid && (tl_d_opcode==3'd1);
    assign axi_rdata   = tl_d_data;
    assign axi_rresp   = 2'b00;
    assign tl_a_opcode = is_write ? 3'd0 : 3'd4;  // PutFullData or Get
    assign tl_a_param  = 3'd0;
    assign tl_a_size   = 3'd2;  // 4 bytes
    assign tl_a_source = 4'd0;
    assign tl_a_addr   = r_addr;
    assign tl_a_mask   = is_write ? r_mask : {{MASK_W{{1'b1}}}};
    assign tl_a_data   = r_wdata;
    assign tl_a_valid  = (st==S_SEND);
    assign tl_d_ready  = (st==S_WAIT) || axi_bready || axi_rready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st<=S_IDLE; r_addr<=0; r_wdata<=0; r_mask<=0; is_write<=0;
            aw_seen<=0; w_seen<=0; aw_capture<=0; w_capture<=0; wstrb_capture<=0;
        end else case(st)
            S_IDLE: begin
                if (axi_awvalid && axi_awready) begin aw_capture<=axi_awaddr; aw_seen<=1; end
                if (axi_wvalid && axi_wready) begin w_capture<=axi_wdata; wstrb_capture<=axi_wstrb; w_seen<=1; end
                if ((aw_seen || (axi_awvalid && axi_awready)) && (w_seen || (axi_wvalid && axi_wready))) begin
                    r_addr  <= aw_seen ? aw_capture : axi_awaddr;
                    r_wdata <= w_seen  ? w_capture  : axi_wdata;
                    r_mask  <= w_seen  ? wstrb_capture : axi_wstrb;
                    is_write<=1; st<=S_SEND; aw_seen<=0; w_seen<=0;
                end else if (axi_arvalid && !axi_awvalid && !aw_seen && !w_seen) begin
                    r_addr<=axi_araddr; is_write<=0; st<=S_SEND;
                end
            end
            S_SEND: if (tl_a_ready) st<=S_WAIT;
            S_WAIT: if (tl_d_valid) st<=S_IDLE;
            default: st<=S_IDLE;
        endcase
    end
endmodule
"""
    return {f"{n}.v": code}
