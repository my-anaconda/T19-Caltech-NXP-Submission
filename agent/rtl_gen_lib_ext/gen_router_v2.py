"""
Corrected tilelink_router generator - supports real multi-hop XY forwarding.

Root problem with the organizer-provided rtl_gen_lib version (documented in
NOTES.md): every compass port (N/S/E/W) is generated with the SAME fixed
direction (A-channel input, D-channel output) on every instance - i.e. every
port only ever acts as a slave. Two router instances wired together via their
facing ports (e.g. router_00's East <-> router_10's West) therefore have BOTH
sides declared as inputs for the A-channel - there is no configuration of
top-level wiring that lets a packet actually traverse the link, since neither
side can ever drive a NEW request out toward the other.

Fix: each compass port gets TWO independent channel pairs instead of one:
  - a SLAVE pair (p{i}_s_*): this router receiving a request FROM that
    neighbor and replying to it - matches the original single-pair semantics.
  - a MASTER pair (p{i}_m_*): this router SENDING a request TO that neighbor
    (originating or forwarding) and receiving the reply.
At the top level, router A's p{X}_m_* (master, facing neighbor B) wires to
router B's p{Y}_s_* (slave, facing neighbor A) where X/Y are opposite compass
directions - and vice versa for the other traffic direction. This gives each
physical link real full-duplex capability.

Second fix, from a detail in the hard architecture doc's AXI-Lite SRAM
section ("the router drives its AXI ports directly - no NI on the local
path"): the router embeds its own tiny AXI4-Lite master, used only to
deliver locally-destined packets (from any of the 5 inbound sources) to this
node's own SRAM. The NI's local port (loc_a_in/loc_d_out) is used only for
this node's own CPU/DMA-originated traffic entering the mesh - never for
local delivery, which bypasses NI entirely per the doc.
"""
from gen_utils import hdr as _hdr


def gen_tilelink_router_v2(spec):
    n = spec.get("name", "tl_router")
    nx = int(spec["node_x"])
    ny = int(spec["node_y"])
    dw = int(spec["data_width"])
    aw = int(spec["addr_width"])
    sw = dw // 8

    code = _hdr(n, f"TileLink-UL router v2 (real multi-hop forwarding) node=({nx},{ny}) data={dw}b addr={aw}b")

    def chan_ports(prefix, a_dir, d_dir):
        """a_dir/d_dir: 'in' or 'out' for the A and D channel of this pair.
        Every output in this design is driven procedurally (always @(*) or
        always @(posedge)), so every output port must be declared `reg`, not
        `wire` - a plain `wire` output can only be driven by continuous
        assign. Inputs are always `wire`."""
        lines = []
        aq = "input " if a_dir == "in" else "output"
        a_type = "wire" if a_dir == "in" else "reg "
        aqr = "output" if a_dir == "in" else "input "
        aqr_type = "reg " if a_dir == "in" else "wire"
        dq = "output" if a_dir == "in" else "input "  # D flows opposite to A
        d_type = "reg " if a_dir == "in" else "wire"
        dqr = "input " if a_dir == "in" else "output"
        dqr_type = "wire" if a_dir == "in" else "reg "
        lines.append(f"    {aq} {a_type} [2:0]          {prefix}_a_opcode, {prefix}_a_param,")
        lines.append(f"    {aq} {a_type} [SIZE_W-1:0]   {prefix}_a_size,")
        lines.append(f"    {aq} {a_type} [SOURCE_W-1:0] {prefix}_a_source,")
        lines.append(f"    {aq} {a_type} [ADDR_W-1:0]   {prefix}_a_addr,")
        lines.append(f"    {aq} {a_type} [MASK_W-1:0]   {prefix}_a_mask,")
        lines.append(f"    {aq} {a_type} [DATA_W-1:0]   {prefix}_a_data,")
        lines.append(f"    {aq} {a_type}                {prefix}_a_valid,")
        lines.append(f"    {aqr} {aqr_type}                {prefix}_a_ready,")
        lines.append(f"    {dq} {d_type} [2:0]          {prefix}_d_opcode,")
        lines.append(f"    {dq} {d_type} [1:0]          {prefix}_d_param,")
        lines.append(f"    {dq} {d_type} [SIZE_W-1:0]   {prefix}_d_size,")
        lines.append(f"    {dq} {d_type} [SOURCE_W-1:0] {prefix}_d_source,")
        lines.append(f"    {dq} {d_type} [DATA_W-1:0]   {prefix}_d_data,")
        lines.append(f"    {dq} {d_type}                {prefix}_d_valid,")
        lines.append(f"    {dqr} {dqr_type}                {prefix}_d_ready,")
        return lines

    port_lines = []
    port_lines.append("    input  wire clk, rst_n,")
    port_lines.append("    // Local inject port (NI is master; this router is slave for entry traffic)")
    port_lines += chan_ports("loc", "in", "out")
    port_lines.append("    // Local SRAM AXI4-Lite master (router drives this node's SRAM directly, no NI)")
    port_lines.append("    output reg  [ADDR_W-1:0] sram_awaddr, output reg sram_awvalid, input wire sram_awready,")
    port_lines.append("    output reg  [DATA_W-1:0] sram_wdata,  output reg [MASK_W-1:0] sram_wstrb,")
    port_lines.append("    output reg  sram_wvalid, input wire sram_wready,")
    port_lines.append("    input  wire [1:0] sram_bresp, input wire sram_bvalid, output reg sram_bready,")
    port_lines.append("    output reg  [ADDR_W-1:0] sram_araddr, output reg sram_arvalid, input wire sram_arready,")
    port_lines.append("    input  wire [DATA_W-1:0] sram_rdata, input wire [1:0] sram_rresp,")
    port_lines.append("    input  wire sram_rvalid, output reg sram_rready,")
    dir_names = ["p0", "p1", "p2", "p3"]  # N, S, E, W
    for p in dir_names:
        port_lines.append(f"    // {p} slave (incoming from that neighbour) + master (outgoing to that neighbour)")
        port_lines += chan_ports(f"{p}_s", "in", "out")
        port_lines += chan_ports(f"{p}_m", "out", "in")
    # strip trailing comma on the very last port line
    ports_joined = "\n".join(port_lines)
    last_comma = ports_joined.rfind(",")
    ports_joined = ports_joined[:last_comma] + ports_joined[last_comma + 1:]

    code += f"""\
module {n} #(
    parameter NODE_X   = {nx},
    parameter NODE_Y   = {ny},
    parameter DATA_W   = {dw},
    parameter ADDR_W   = {aw},
    parameter SIZE_W   = 3,
    parameter SOURCE_W = 4,
    parameter MASK_W   = {sw}
)(
{ports_joined}
);
    // ------------------------------------------------------------------
    // Arbitration: 5 candidate inbound sources - loc_a_in (from NI) and the
    // 4 neighbour slave ports (p0_s_a..p3_s_a). Fixed priority p0>p1>p2>p3>loc.
    // Single-outstanding-transaction design (one request in flight at a time).
    // ------------------------------------------------------------------
    localparam S_IDLE=3'd0, S_SEND=3'd1, S_WAIT=3'd2, S_REPLY=3'd3;
    reg [2:0] st;
    reg [2:0]  o_opcode, o_param;
    reg [2:0]  o_size;
    reg [3:0]  o_source;
    reg [31:0] o_addr;
    reg [7:0]  o_mask;
    reg [63:0] o_data;
    reg [2:0]  origin;     // 0=loc 1=p0 2=p1 3=p2 4=p3
    reg [2:0]  dest_sel;   // 0=local(sram) 1=p0_m 2=p1_m 3=p2_m 4=p3_m
    reg [2:0]  r_opcode, r_param;
    reg [2:0]  r_size;
    reg [3:0]  r_source;
    reg [63:0] r_data;
    // The local SRAM's own AXI4-Lite slave (gen_sram_v2.py) implements a
    // strictly SEQUENTIAL two-phase write protocol - awready pulses first
    // (address phase), wready pulses later (data phase), and it NEVER
    // asserts both in the same cycle (verified: this is exactly what
    // caused a real, reproducible hang - the router got permanently stuck
    // in S_SEND for every local write, since `sram_awready && sram_wready`
    // is never true, even though the write's DATA still landed in SRAM
    // because the SRAM itself kept re-triggering off the router's
    // continuously-held awvalid - only the router's own FSM was wedged,
    // silently blocking every subsequent transaction). aw_seen/w_seen
    // latch each phase independently as it completes, so the SEND->WAIT
    // transition fires once both have been observed, on whichever cycles
    // they actually occur.
    reg aw_seen, w_seen;

    wire any_in = loc_a_valid | p0_s_a_valid | p1_s_a_valid | p2_s_a_valid | p3_s_a_valid;

    wire [3:0] sel_dest_x = p0_s_a_valid ? p0_s_a_addr[ADDR_W-1:ADDR_W-4] :
                            p1_s_a_valid ? p1_s_a_addr[ADDR_W-1:ADDR_W-4] :
                            p2_s_a_valid ? p2_s_a_addr[ADDR_W-1:ADDR_W-4] :
                            p3_s_a_valid ? p3_s_a_addr[ADDR_W-1:ADDR_W-4] :
                                           loc_a_addr[ADDR_W-1:ADDR_W-4];
    wire [3:0] sel_dest_y = p0_s_a_valid ? p0_s_a_addr[ADDR_W-5:ADDR_W-8] :
                            p1_s_a_valid ? p1_s_a_addr[ADDR_W-5:ADDR_W-8] :
                            p2_s_a_valid ? p2_s_a_addr[ADDR_W-5:ADDR_W-8] :
                            p3_s_a_valid ? p3_s_a_addr[ADDR_W-5:ADDR_W-8] :
                                           loc_a_addr[ADDR_W-5:ADDR_W-8];

    wire go_local = (sel_dest_x == NODE_X[3:0]) && (sel_dest_y == NODE_Y[3:0]);
    wire go_east  = (sel_dest_x >  NODE_X[3:0]);
    wire go_west  = (sel_dest_x <  NODE_X[3:0]);
    wire go_north = (sel_dest_x == NODE_X[3:0]) && (sel_dest_y >  NODE_Y[3:0]);
    wire go_south = (sel_dest_x == NODE_X[3:0]) && (sel_dest_y <  NODE_Y[3:0]);

    // grant/accept signals for the currently selected input, computed combinationally
    always @(*) begin
        loc_a_ready = 1'b0; p0_s_a_ready = 1'b0; p1_s_a_ready = 1'b0;
        p2_s_a_ready = 1'b0; p3_s_a_ready = 1'b0;
        if (st == S_IDLE && any_in) begin
            if (p0_s_a_valid)      p0_s_a_ready = 1'b1;
            else if (p1_s_a_valid) p1_s_a_ready = 1'b1;
            else if (p2_s_a_valid) p2_s_a_ready = 1'b1;
            else if (p3_s_a_valid) p3_s_a_ready = 1'b1;
            else if (loc_a_valid) loc_a_ready = 1'b1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; origin <= 3'd0; dest_sel <= 3'd0;
            o_opcode<=0; o_param<=0; o_size<=0; o_source<=0; o_addr<=0; o_mask<=0; o_data<=0;
            r_opcode<=0; r_param<=0; r_size<=0; r_source<=0; r_data<=0;
            aw_seen<=1'b0; w_seen<=1'b0;
        end else begin
            case (st)
                S_IDLE: if (any_in) begin
                    if (p0_s_a_valid) begin
                        origin<=3'd1; o_opcode<=p0_s_a_opcode; o_param<=p0_s_a_param; o_size<=p0_s_a_size;
                        o_source<=p0_s_a_source; o_addr<=p0_s_a_addr; o_mask<=p0_s_a_mask; o_data<=p0_s_a_data;
                    end else if (p1_s_a_valid) begin
                        origin<=3'd2; o_opcode<=p1_s_a_opcode; o_param<=p1_s_a_param; o_size<=p1_s_a_size;
                        o_source<=p1_s_a_source; o_addr<=p1_s_a_addr; o_mask<=p1_s_a_mask; o_data<=p1_s_a_data;
                    end else if (p2_s_a_valid) begin
                        origin<=3'd3; o_opcode<=p2_s_a_opcode; o_param<=p2_s_a_param; o_size<=p2_s_a_size;
                        o_source<=p2_s_a_source; o_addr<=p2_s_a_addr; o_mask<=p2_s_a_mask; o_data<=p2_s_a_data;
                    end else if (p3_s_a_valid) begin
                        origin<=3'd4; o_opcode<=p3_s_a_opcode; o_param<=p3_s_a_param; o_size<=p3_s_a_size;
                        o_source<=p3_s_a_source; o_addr<=p3_s_a_addr; o_mask<=p3_s_a_mask; o_data<=p3_s_a_data;
                    end else begin
                        origin<=3'd0; o_opcode<=loc_a_opcode; o_param<=loc_a_param; o_size<=loc_a_size;
                        o_source<=loc_a_source; o_addr<=loc_a_addr; o_mask<=loc_a_mask; o_data<=loc_a_data;
                    end
                    dest_sel <= go_local ? 3'd0 : go_east ? 3'd3 : go_west ? 3'd4 : go_north ? 3'd1 : 3'd2;
                    aw_seen <= 1'b0; w_seen <= 1'b0;
                    st <= S_SEND;
                end
                S_SEND: begin
                    case (dest_sel)
                        3'd0: if (o_opcode == 3'd4) begin
                                  if (sram_arready) st <= S_WAIT;
                              end else begin
                                  // aw_seen/w_seen latch each phase as it
                                  // completes (see declaration comment) -
                                  // sram_awready/wready never coincide.
                                  if (sram_awready) aw_seen <= 1'b1;
                                  if (sram_wready) w_seen <= 1'b1;
                                  if ((sram_awready || aw_seen) && (sram_wready || w_seen)) st <= S_WAIT;
                              end
                        3'd1: if (p0_m_a_ready) st <= S_WAIT;
                        3'd2: if (p1_m_a_ready) st <= S_WAIT;
                        3'd3: if (p2_m_a_ready) st <= S_WAIT;
                        3'd4: if (p3_m_a_ready) st <= S_WAIT;
                        default: st <= S_WAIT;
                    endcase
                end
                S_WAIT: begin
                    case (dest_sel)
                        3'd0: if (o_opcode == 3'd4) begin
                                  if (sram_rvalid) begin r_opcode<=3'd1; r_data<=sram_rdata; r_source<=o_source; st<=S_REPLY; end
                              end else begin
                                  if (sram_bvalid) begin r_opcode<=3'd0; r_data<=64'b0; r_source<=o_source; st<=S_REPLY; end
                              end
                        3'd1: if (p0_m_d_valid) begin r_opcode<=p0_m_d_opcode; r_data<=p0_m_d_data; r_source<=p0_m_d_source; st<=S_REPLY; end
                        3'd2: if (p1_m_d_valid) begin r_opcode<=p1_m_d_opcode; r_data<=p1_m_d_data; r_source<=p1_m_d_source; st<=S_REPLY; end
                        3'd3: if (p2_m_d_valid) begin r_opcode<=p2_m_d_opcode; r_data<=p2_m_d_data; r_source<=p2_m_d_source; st<=S_REPLY; end
                        3'd4: if (p3_m_d_valid) begin r_opcode<=p3_m_d_opcode; r_data<=p3_m_d_data; r_source<=p3_m_d_source; st<=S_REPLY; end
                    endcase
                end
                S_REPLY: begin
                    case (origin)
                        3'd0: if (loc_d_ready) st <= S_IDLE;
                        3'd1: if (p0_s_d_ready) st <= S_IDLE;
                        3'd2: if (p1_s_d_ready) st <= S_IDLE;
                        3'd3: if (p2_s_d_ready) st <= S_IDLE;
                        3'd4: if (p3_s_d_ready) st <= S_IDLE;
                        default: st <= S_IDLE;
                    endcase
                end
                default: st <= S_IDLE;
            endcase
        end
    end

    // ---- drive the chosen output (A-channel) during S_SEND/S_WAIT ----
    always @(*) begin
        {{sram_awaddr, sram_awvalid, sram_wdata, sram_wstrb, sram_wvalid, sram_bready,
          sram_araddr, sram_arvalid, sram_rready}} = 0;
        {{p0_m_a_opcode, p0_m_a_param, p0_m_a_size, p0_m_a_source, p0_m_a_addr, p0_m_a_mask, p0_m_a_data, p0_m_a_valid, p0_m_d_ready}} = 0;
        {{p1_m_a_opcode, p1_m_a_param, p1_m_a_size, p1_m_a_source, p1_m_a_addr, p1_m_a_mask, p1_m_a_data, p1_m_a_valid, p1_m_d_ready}} = 0;
        {{p2_m_a_opcode, p2_m_a_param, p2_m_a_size, p2_m_a_source, p2_m_a_addr, p2_m_a_mask, p2_m_a_data, p2_m_a_valid, p2_m_d_ready}} = 0;
        {{p3_m_a_opcode, p3_m_a_param, p3_m_a_size, p3_m_a_source, p3_m_a_addr, p3_m_a_mask, p3_m_a_data, p3_m_a_valid, p3_m_d_ready}} = 0;
        if (st == S_SEND || st == S_WAIT) begin
            case (dest_sel)
                3'd0: begin
                    if (o_opcode == 3'd4) begin // Get -> read
                        sram_araddr = o_addr; sram_arvalid = (st==S_SEND);
                        sram_rready = (st==S_WAIT);
                    end else begin // PutFullData -> write
                        sram_awaddr = o_addr; sram_awvalid = (st==S_SEND) && !aw_seen;
                        sram_wdata = o_data[DATA_W-1:0]; sram_wstrb = o_mask; sram_wvalid = (st==S_SEND) && !w_seen;
                        sram_bready = (st==S_WAIT);
                    end
                end
                3'd1: begin
                    p0_m_a_opcode=o_opcode; p0_m_a_param=o_param; p0_m_a_size=o_size; p0_m_a_source=o_source;
                    p0_m_a_addr=o_addr; p0_m_a_mask=o_mask; p0_m_a_data=o_data[DATA_W-1:0]; p0_m_a_valid=(st==S_SEND);
                    p0_m_d_ready = (st==S_WAIT);
                end
                3'd2: begin
                    p1_m_a_opcode=o_opcode; p1_m_a_param=o_param; p1_m_a_size=o_size; p1_m_a_source=o_source;
                    p1_m_a_addr=o_addr; p1_m_a_mask=o_mask; p1_m_a_data=o_data[DATA_W-1:0]; p1_m_a_valid=(st==S_SEND);
                    p1_m_d_ready = (st==S_WAIT);
                end
                3'd3: begin
                    p2_m_a_opcode=o_opcode; p2_m_a_param=o_param; p2_m_a_size=o_size; p2_m_a_source=o_source;
                    p2_m_a_addr=o_addr; p2_m_a_mask=o_mask; p2_m_a_data=o_data[DATA_W-1:0]; p2_m_a_valid=(st==S_SEND);
                    p2_m_d_ready = (st==S_WAIT);
                end
                3'd4: begin
                    p3_m_a_opcode=o_opcode; p3_m_a_param=o_param; p3_m_a_size=o_size; p3_m_a_source=o_source;
                    p3_m_a_addr=o_addr; p3_m_a_mask=o_mask; p3_m_a_data=o_data[DATA_W-1:0]; p3_m_a_valid=(st==S_SEND);
                    p3_m_d_ready = (st==S_WAIT);
                end
            endcase
        end
    end

    // ---- drive the D-channel reply back to the origin during S_REPLY ----
    always @(*) begin
        loc_d_opcode=0; loc_d_param=0; loc_d_size=0; loc_d_source=0; loc_d_data=0; loc_d_valid=0;
        p0_s_d_opcode=0; p0_s_d_param=0; p0_s_d_size=0; p0_s_d_source=0; p0_s_d_data=0; p0_s_d_valid=0;
        p1_s_d_opcode=0; p1_s_d_param=0; p1_s_d_size=0; p1_s_d_source=0; p1_s_d_data=0; p1_s_d_valid=0;
        p2_s_d_opcode=0; p2_s_d_param=0; p2_s_d_size=0; p2_s_d_source=0; p2_s_d_data=0; p2_s_d_valid=0;
        p3_s_d_opcode=0; p3_s_d_param=0; p3_s_d_size=0; p3_s_d_source=0; p3_s_d_data=0; p3_s_d_valid=0;
        if (st == S_REPLY) begin
            case (origin)
                3'd0: begin loc_d_opcode=r_opcode; loc_d_source=r_source; loc_d_data=r_data[DATA_W-1:0]; loc_d_valid=1'b1; end
                3'd1: begin p0_s_d_opcode=r_opcode; p0_s_d_source=r_source; p0_s_d_data=r_data[DATA_W-1:0]; p0_s_d_valid=1'b1; end
                3'd2: begin p1_s_d_opcode=r_opcode; p1_s_d_source=r_source; p1_s_d_data=r_data[DATA_W-1:0]; p1_s_d_valid=1'b1; end
                3'd3: begin p2_s_d_opcode=r_opcode; p2_s_d_source=r_source; p2_s_d_data=r_data[DATA_W-1:0]; p2_s_d_valid=1'b1; end
                3'd4: begin p3_s_d_opcode=r_opcode; p3_s_d_source=r_source; p3_s_d_data=r_data[DATA_W-1:0]; p3_s_d_valid=1'b1; end
            endcase
        end
    end

endmodule
"""
    return {f"{n}.v": code}


if __name__ == "__main__":
    for name, x, y in [("u_router_a", 0, 0), ("u_router_b", 1, 0), ("u_router_c", 1, 1)]:
        spec = {"name": name, "node_x": x, "node_y": y, "data_width": 64, "addr_width": 32}
        files = gen_tilelink_router_v2(spec)
        for fname, content in files.items():
            with open(fname, "w") as f:
                f.write(content)
            print(f"Wrote {fname} ({len(content)} chars)")
