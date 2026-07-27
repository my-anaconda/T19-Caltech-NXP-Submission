"""
Corrected apb_fabric generator - fixes a real, genuine structural bug in
the organizer-provided rtl_gen_lib version's slot-decode logic.

Bug (found by reading the generator source and tracing the ACTUAL address
that reaches it in the real top-level, before writing a single line of
testbench - the same kind of address-decode mismatch already found once
in axi_lite_crossbar, but this one is in a DIFFERENT generator and was
caught before wasting a real simulation run on it): the original
generator decodes which of its 5 slots to select with
    wire dec0 = m_psel && (m_paddr[31:12] == 20'h00000);
    wire dec1 = m_psel && (m_paddr[31:12] == 20'h00001);
    ... (dec2/dec3/dec4 similarly against 20'h00002/3/4)
i.e. it assumes `m_paddr` has ALREADY been re-based to a LOCAL address
space starting at 0x0000_0000, where the slot number sits directly in
bits[31:12]. But nothing in this architecture ever performs that
re-basing: the crossbar passes its S1 window's address straight through
unmodified (`assign s1_awaddr = waddr;` in axi_lite_crossbar, verified
directly in a real generated top-level: `.haddr(s1_awvalid ? s1_awaddr :
s1_araddr)` - no offset subtraction anywhere), and the architecture doc's
own address map documents these slots in GLOBAL terms (base
0xF000_0000, slot N at +N*0x1000). So a real CPU write to, say, GPIO0's
OUT register at the documented address 0xF000_1004 arrives at this
fabric with `m_paddr[31:12] == 20'hF0001`, which matches NONE of
`dec0`..`dec4` - every single APB peripheral access would permanently
`miss`, regardless of which peripheral or register.

Fix: decode against `m_paddr[15:12]` (the slot nibble within the fixed
64KB S1 window) instead of `m_paddr[31:12]` (which incorrectly folds in
the window's own fixed upper bits, 0xF000, into the slot comparison).
Everything else - per-slot signal routing, the S3 privilege filter, the
timeout/miss/pslverr logic - is unchanged from the original generator.
"""
from gen_utils import hdr as _hdr


def gen_apb_fabric_v2(spec):
    n = spec.get("name", "apb_fabric5")
    tmo = int(spec.get("timeout_cyc", 16))
    code = _hdr(n, f"APB3 5-slave fabric, priv-filter S3, {tmo}-cycle timeout (v2 - fixed slot decode)")
    code += f"""\
module {n} #(parameter TIMEOUT_CYC={tmo})(
    input  wire        pclk, presetn,
    input  wire        m_psel, m_penable, m_pwrite,
    input  wire [31:0] m_paddr, m_pwdata,
    input  wire [2:0]  m_pprot,
    output reg  [31:0] m_prdata,
    output wire        m_pready, m_pslverr,
    output wire s0_psel,s0_penable,s0_pwrite, output wire [11:0] s0_paddr,
    output wire [31:0] s0_pwdata, input wire [31:0] s0_prdata,
    input  wire s0_pready, s0_pslverr,
    output wire s1_psel,s1_penable,s1_pwrite, output wire [11:0] s1_paddr,
    output wire [31:0] s1_pwdata, input wire [31:0] s1_prdata,
    input  wire s1_pready, s1_pslverr,
    output wire s2_psel,s2_penable,s2_pwrite, output wire [11:0] s2_paddr,
    output wire [31:0] s2_pwdata, input wire [31:0] s2_prdata,
    input  wire s2_pready, s2_pslverr,
    output wire s3_psel,s3_penable,s3_pwrite, output wire [11:0] s3_paddr,
    output wire [31:0] s3_pwdata, input wire [31:0] s3_prdata,
    input  wire s3_pready, s3_pslverr,
    output wire s4_psel,s4_penable,s4_pwrite, output wire [11:0] s4_paddr,
    output wire [31:0] s4_pwdata, input wire [31:0] s4_prdata,
    input  wire s4_pready, s4_pslverr
);
    // Fixed (see module docstring): decode the slot NIBBLE within the
    // fixed 64KB window (bits[15:12]), not bits[31:12] - the address
    // reaching this fabric is never re-based to 0, so bits[31:16] are
    // always the window's own fixed upper bits (e.g. 0xF000), not 0.
    wire dec0=m_psel&&(m_paddr[15:12]==4'h0);
    wire dec1=m_psel&&(m_paddr[15:12]==4'h1);
    wire dec2=m_psel&&(m_paddr[15:12]==4'h2);
    wire dec3=m_psel&&(m_paddr[15:12]==4'h3);
    wire dec4=m_psel&&(m_paddr[15:12]==4'h4);
    wire priv=m_pprot[0];
    wire priv_err=dec3&&!priv;
    wire miss=m_psel&&!(dec0||dec1||dec2||dec3||dec4);
    reg [4:0] tcnt; reg terr;
    always @(posedge pclk or negedge presetn)
        if (!presetn) begin tcnt<=0; terr<=0; end
        else if (!m_psel||m_pready) begin tcnt<=0; terr<=0; end
        else if (tcnt==TIMEOUT_CYC-1) terr<=1;
        else tcnt<=tcnt+1;
    wire s0_ok=dec0, s1_ok=dec1, s2_ok=dec2, s3_ok=dec3&&priv, s4_ok=dec4;
    assign s0_psel=s0_ok; assign s1_psel=s1_ok; assign s2_psel=s2_ok;
    assign s3_psel=s3_ok; assign s4_psel=s4_ok;
    assign s0_penable=m_penable; assign s1_penable=m_penable;
    assign s2_penable=m_penable; assign s3_penable=m_penable; assign s4_penable=m_penable;
    assign s0_pwrite=m_pwrite; assign s1_pwrite=m_pwrite; assign s2_pwrite=m_pwrite;
    assign s3_pwrite=m_pwrite; assign s4_pwrite=m_pwrite;
    assign s0_paddr=m_paddr[11:0]; assign s1_paddr=m_paddr[11:0];
    assign s2_paddr=m_paddr[11:0]; assign s3_paddr=m_paddr[11:0]; assign s4_paddr=m_paddr[11:0];
    assign s0_pwdata=m_pwdata; assign s1_pwdata=m_pwdata; assign s2_pwdata=m_pwdata;
    assign s3_pwdata=m_pwdata; assign s4_pwdata=m_pwdata;
    always @(*)
        if      (s0_ok) m_prdata=s0_prdata;
        else if (s1_ok) m_prdata=s1_prdata;
        else if (s2_ok) m_prdata=s2_prdata;
        else if (s3_ok) m_prdata=s3_prdata;
        else if (s4_ok) m_prdata=s4_prdata;
        else            m_prdata=32'hDEAD_BEEF;
    wire err_cond=miss|priv_err|terr;
    wire slv_rdy=(s0_ok?s0_pready:1'b1)&(s1_ok?s1_pready:1'b1)&
                 (s2_ok?s2_pready:1'b1)&(s3_ok?s3_pready:1'b1)&(s4_ok?s4_pready:1'b1);
    assign m_pready  = err_cond ? 1'b1 : slv_rdy;
    assign m_pslverr = miss|priv_err|terr|
                       (s0_ok&s0_pslverr)|(s1_ok&s1_pslverr)|(s2_ok&s2_pslverr)|
                       (s3_ok&s3_pslverr)|(s4_ok&s4_pslverr);
endmodule
"""
    return {f"{n}.v": code}
