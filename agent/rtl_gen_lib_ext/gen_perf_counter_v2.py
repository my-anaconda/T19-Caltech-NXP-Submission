"""
Corrected perf_counter generator - fixes a real, direct contradiction
between the architecture doc and the organizer-provided rtl_gen_lib
generator's counting logic.

The architecture doc is explicit: "A perf_counter with 4 event channels,
EACH COUNTING POSITIVE EDGES of its event input." But the original
generator's increment logic is a plain level check -
`if(event_i) cnt_i<=cnt_i+1;` - which increments every single cycle
event_i happens to be held high, not once per rising edge. This matters
a lot in practice: two of the four documented channels are wired to
genuinely multi-cycle/level signals, not 1-cycle pulses - ch[0] is
ni_00's tl_a_valid (can stay asserted across a stalled multi-cycle NoC
transaction) and ch[1]/ch[2] are dma0_irq/dma1_irq (level IRQs that stay
high until explicitly cleared/re-armed, per the DMA engine's own
documented STATUS/IRQSTAT semantics) - under the original generator,
either of these would silently over-count by however many extra cycles
the source happened to stay high, not the number of actual events.
(ch[3], OR of the AES engines' 1-cycle `done` pulses, happens to be safe
either way, which is likely why this was never caught against a
1-cycle-pulse-only test.)

Fixed by adding a per-channel edge-detect register (mirroring the same
prev-value-and-AND-with-inverted-prev pattern already used correctly in
gen_irq_aggregator for its own edge_ev) and incrementing on the detected
rising edge instead of the raw level. Everything else (register map:
paddr==i*4 reads cnt_i, a write to paddr==0 clears all counters,
counter_width/channels parameterization) is unchanged from the original
generator.
"""
from gen_utils import hdr as _hdr


def gen_perf_counter_v2(spec):
    n = spec.get("name", "perf_counter")
    ch = int(spec.get("channels", 4))
    w = int(spec.get("counter_width", 32))
    ports = "\n".join(f"    input  wire        event_{i}," for i in range(ch))
    regs = "\n".join(f"    reg [{w-1}:0] cnt{i};" for i in range(ch))
    prev_regs = "\n".join(f"    reg ev_prev{i};" for i in range(ch))
    prev_clr = "\n".join(f"            ev_prev{i}<=0;" for i in range(ch))
    prev_upd = "\n".join(f"            ev_prev{i}<=event_{i};" for i in range(ch))
    edge_wires = "\n".join(f"    wire edge_{i} = event_{i} & ~ev_prev{i};" for i in range(ch))
    clr = "\n".join(f"            cnt{i}<=0;" for i in range(ch))
    inc = "\n".join(f"            if(edge_{i}) cnt{i}<=cnt{i}+1;" for i in range(ch))
    cases = "\n".join(f"        {i*4}: prdata=cnt{i};" for i in range(ch))
    code = _hdr(n, f"Perf counter {ch}ch {w}b, edge-triggered (v2 - fixed level-vs-edge counting bug)")
    code += f"""\
module {n} (
    input  wire pclk, presetn,
{ports}
    input  wire psel, penable, pwrite,
    input  wire [11:0] paddr, input  wire [31:0] pwdata,
    output reg  [31:0] prdata, output wire pready, pslverr
);
    assign pready=1; assign pslverr=0;
{regs}
{prev_regs}
    always @(posedge pclk or negedge presetn)
        if (!presetn) begin {prev_clr} end
        else begin {prev_upd} end
{edge_wires}
    always @(posedge pclk or negedge presetn)
        if (!presetn) begin {clr} end
        else begin
{inc}
            if (psel&&penable&&pwrite&&paddr==0) begin {clr} end
        end
    always @(*) case(paddr)
{cases}
        default: prdata=32'hDEAD_BEEF;
    endcase
endmodule
"""
    return {f"{n}.v": code}
