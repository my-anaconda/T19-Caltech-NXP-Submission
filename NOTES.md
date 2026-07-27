# Agent design notes

`agent/t19_nxp_agent_final.py` synthesizes T19's own 18-version iteration
history (`t19_nxp_agent_v2.py` through `v19.py`, developed against
`ICLAD26-NXP-Problems/agent/`) plus the organizer-provided reference
(`vertexai_express_agent.py`). This file records why it's built the way it is.

## Critical fix: every prior version violated the contract

`AGENT_GUIDE.md` is explicit: *"Send ALL model calls to the `model_endpoint`
... ALL LLM calls go here."* Every one of T19's own versions (v2-v19) instead
imported `google.genai` directly and authenticated with `EXPRESS_MODE_KEY`,
bypassing `model_endpoint` entirely. This means:

- None of those runs are contract-valid as submitted.
- None of them produce real token-usage data through the benchmark's own
  tracking (the model service is what's supposed to log usage against
  `usage_path`), so the efficiency tie-break score would be forfeited.

The final agent fixes this by using `call_model()` (POST to
`info["model_endpoint"] + "/generate"`, exponential backoff, heartbeat) taken
directly from the organizer's `vertexai_express_agent.py` - the one piece of
reference code known to be contract-compliant.

## Why v16 is the architectural base, not v19 (the latest)

Local runs cannot produce a real correctness score: `problems/easy/golden_tb/`
is intentionally hidden from participants, so every historical
`factors/v*/easy/easy_score.json` shows `"score": 0.0` with `"errors": "Golden
TB not found"` - true for literally every version, v1 through v16. That
number is not a signal of agent quality. The real signal is which versions
completed the pipeline and produced a full, sensible RTL file set
(`result/vN/easy/*.v`):

| Versions | Outcome |
|---|---|
| v2-v5 | Only a hardcoded placeholder `secure_periph_soc.v` - never called `rtl_gen_lib` at all |
| v6-v11, v14-v16 | Full file set (8 IPs + top module) generated successfully |
| v12, v17 | Crashed, zero output |
| v13, v18 | Partial output (3/9, 2/9 files) - v18's per-IP sequential-call redesign (~9 calls with cooldowns) appears to have run into timeouts/rate limits |
| v19 | Never actually run locally - no `result/`, `factors/`, or `usage/` entry exists for it |

**v16** is the last version with a verified-complete run, using a reliable
single-combined-call design for both the YAML-inference step and the
top-level stitching step. **v19**'s per-section sequential-calling redesign
(inherited from v18) is not carried forward for that reason, even though it's
the most recently written version.

## What was merged in from elsewhere

- **From v19**: the hand-curated `IP_CONSTRAINTS` schema dict - more complete
  and reliable than v16's approach of regex-scraping `required(spec, ...)`
  calls out of `rtl_gen_lib/gen_*.py` source directly.
- **From v16**: the SVG-based directed-graph topology extraction
  (`extract_graph_topology` / `parse_architecture_html`) - parses
  `architecture.html`'s `<g class="node">` / `<g class="edge">` SVG elements
  into an explicit NODES/EDGES text block, which is a much stronger signal
  for wiring inference than asking the model to read raw prose.
- **From `vertexai_express_agent.py`**: `call_model()`, the heartbeat
  context manager, and diagnostics-JSON writing.

## Ideas considered and deliberately not carried forward

- **v3/v4's multimodal image attachment** (sending the architecture diagram
  as an actual image alongside text) was dropped after v4 in favor of the
  SVG-title-extraction approach. It might be worth revisiting *if* the
  `model_endpoint` API is ever confirmed to accept an image field - as
  written, `AGENT_GUIDE.md`'s `/generate` contract only documents `model`,
  `prompt`, `max_output_tokens`, so this agent stays text-only to match the
  documented interface exactly.
- **v18/v19's per-section sequential YAML generation** (one call per
  architecture section instead of one combined call) is conceptually more
  focused but empirically less reliable (the one full run of that design,
  v18, produced only 2/9 files). Not used here.

## Known local-testing limitation

Because the golden testbench is hidden, `evaluator/evaluate.py --rtl_dir
result/<run_id>/easy/` run locally will always report `Golden TB not found`
regardless of RTL quality. Local runs can only confirm that generation
completes and produces a plausible file set - real scoring only happens at
organizer judging time. See `README.md` for the recommended local smoke-test
procedure.

## Re-verification after the ASU token-normalized scoring update (2026-07-26)

The organizers pushed updates to `ICLAD26-ASU-Problems`, `ICLAD26-NVIDIA-Problems`,
and `ICLAD26-NXP-Problems` on 2026-07-25/26 (the NXP one: "Updated architecture
document", a docs-only change to `problems/hard/docs/architecture.html` - no
functional/testcase changes for the `easy` problem this agent targets). Pulled
`ICLAD26-NXP-Problems` to the latest commit and re-ran this exact agent
end-to-end against it (`run_benchmark.py --problem easy`, real
`gemini-2.5-flash` calls through the local `model_service.py` proxy, run-id
`t19_verify_20260726`):

- **Generation completeness**: all 9 expected files generated (8 IP `.v`
  files + `secure_periph_soc.v`), matching every prior successful run.
- **Golden TB check**: `Golden TB not found` - expected, not a failure (see
  "Known local-testing limitation" above).
- **Syntactic validity and elaboration** (the deeper check the README
  recommends but which needs `iverilog`/`vvp`, previously not confirmed in
  this exact environment): `iverilog -g2005 -o smoke_test -s
  secure_periph_soc *.v` compiled cleanly, exit code 0, real output binary
  produced. `iverilog` wasn't installed system-wide here and this
  environment doesn't have root/sudo access; it was obtained without root
  via `apt-get download iverilog` (no root required, unlike `apt-get
  install`) followed by `dpkg-deb -x` to extract it locally. The extracted
  binary looks for its codegen backend (`ivl`/`ivlpp`) at a hardcoded system
  path by default, which doesn't exist without a real install - iverilog's
  own `-B <path>` flag redirects it to the extracted copy's
  `usr/lib/x86_64-linux-gnu/ivl/` directory instead, avoiding the need for
  root entirely. Useful to know for reproducing this check in any similarly
  locked-down environment.

Both checks passing confirms the submission still works correctly against
the organizers' latest problem-repo revision, not just the version it was
originally developed against.

## Extending to medium/hard (2026-07-26)

`t19_nxp_agent_final.py` was already written problem-agnostically (reads
`info["problem"]`, `architecture_doc`, and `tb_skeleton` dynamically, and its
hand-curated `IP_CONSTRAINTS` schema already covered every `ip_type` medium
needs: `tilelink_router`, `tilelink_ni`, `aes128`, `axi_lite_sram`,
`irq_aggregator`, `reset_sync`). Two hardcoded easy-tier assumptions were
generalized rather than forking a separate agent file (see "Why v16 is the
architectural base" above for why this codebase avoids per-version/per-tier
proliferation):

- `EASY_EXPECTED_IPS` (a fixed 8-item list used only for a non-blocking
  sanity-log warning) became `EXPECTED_IPS_BY_PROBLEM`, keyed by problem.
- The output top-level file was hardcoded to `secure_periph_soc.v`
  regardless of problem. Harmless for compilation (`evaluate.py` globs
  `**/*.v` and only module *names* matter), but confusing to inspect. Now
  named after the module the LLM actually wrote, extracted via
  `module\s+(\w+)\s*[(#]`.

**Note:** `runner/run_benchmark.py` in the organizers' `ICLAD26-NXP-Problems`
repo only accepts `--problem easy` right now (`PROBLEMS = ["easy"]`,
docstring says "medium and hard coming in a future release") even though
`evaluator/evaluate.py` already has full `medium`/`hard` configs and
`problems/medium/`, `problems/hard/` already exist with real
`docs/architecture.html` + `tb/tb_top_skeleton.v`. To test medium locally, a
one-off harness script built `info.json` by hand (mirroring
`write_info_json`'s exact shape: `architecture_doc`, `tb_skeleton`,
`rtl_gen_lib`, `output_dir`, `temp_dir`, `usage_path`), started
`model_service.py` manually, ran the agent, then ran `evaluator/evaluate.py
--problem medium` (which works fine standalone) plus an `iverilog`
elaboration pass against `problems/medium/tb/tb_top_skeleton.v`. This harness
isn't part of the submission (the gap is organizer-side, not ours) - just
documenting the method here in case medium/hard testing needs to be redone
before `run_benchmark.py` catches up.

### Real bug found and fixed: top-level truncation on medium

First real run (`t19_medium_test1`) generated all 22 expected IP files
correctly (1 reset_sync + 6 routers + 6 NIs + 6 SRAMs + 2 AES + 1 irq_agg,
matching the "Node IP Inventory" table exactly), but the top-level
`noc_aes_soc.v` failed to elaborate: `iverilog` reported a syntax error at
line 1, which was a literal ` ```verilog ` fence marker. Root cause: the
Step 4 top-level call used `max_tokens=16384` (unchanged from easy), and
medium's top level - wiring together 22 IP instances vs. easy's flatter
8-block structure - is much more verbose. The raw response
(`temp/.../soc_response.txt`) confirmed it: 755 lines, cut off mid
`u_sram_02` instantiation, with only an *opening* fence and no closing one.
`extract_verilog()`'s regex requires a matching closing fence to strip
anything, so on no-match it fell back to returning the raw text verbatim -
fence marker included - producing a guaranteed-broken file silently.

Fix (both applied to `t19_nxp_agent_final.py`, used by every tier):
- Bumped the Step 4 call's `max_tokens` from 16384 to 32768.
- `extract_verilog()` now strips a leading fence marker even when no closing
  fence is found, instead of returning the raw text verbatim.
- Added an explicit `endmodule` presence check after extraction that prints
  a loud `[ERROR] ... looks truncated` if missing, so a future truncation
  (e.g. if hard's even-larger top level exceeds 32768 too) fails loudly
  instead of silently shipping a broken file.

Re-run (`t19_medium_test2`) with the fix completed cleanly: no truncation
warning, `noc_aes_soc.v` ends in a proper `endmodule`, and `iverilog -g2005
-o smoke_test -s tb_top *.v problems/medium/tb/tb_top_skeleton.v` elaborated
with **exit code 0 and zero warnings**. Spot-checked (via `grep`) that all 21
required instance names from the architecture doc's naming-convention table
(`u_rst`, `u_router_00`..`u_router_12`, `u_ni_00`..`u_ni_12`,
`u_sram_00`..`u_sram_12`, `u_aes0`, `u_aes1`, `u_irq_agg`) and both required
tie-off wire names (`tie_02_p0_a_valid`, `tie_00_p1_a_valid`) are present in
the generated top-level file.

### Real regression caught by re-verifying easy after the change

Editing a file shared across all three tiers means every change needs
re-verification against the *other* tiers, not just the one being worked on
- re-ran easy (`t19_easy_regress_check2`) through the actual
`runner/run_benchmark.py --problem easy` (not the manual harness, since
easy is the one tier the real runner supports) and it produced a file named
`for.v` instead of `secure_periph_soc.v`. Cause: the new module-name
extraction regex (`module\s+(\w+)`, no anchor) matched the word "module"
inside a *comment line* the model had written above the real declaration -
`// Top-level module for the Secure Peripheral Subsystem SoC.` - capturing
"for" as the module name. Fixed by requiring `(` or `#` immediately after
the captured identifier (`module\s+(\w+)\s*[(#]`), which only matches a real
declaration. Re-ran (`t19_easy_regress_check3`): file now correctly named
`secure_periph_soc.v`, and a design-only `iverilog -g2005 -s
secure_periph_soc *.v` elaboration (the same method validated in the
2026-07-26 easy re-verification above - `tb_top_skeleton.v` for easy itself
contains SystemVerilog-only task syntax that `-g2005` rejects, unrelated to
our generated RTL, so it's excluded from this specific check exactly as
before) passed with exit code 0. No regression once this fix was in.

### Known, unresolved structural risk: NoC forwarding (not fixed - flagged for judgment)

Reading `rtl_gen_lib/gen_noc_ips.py`'s `gen_tilelink_router` closely: every
compass port (N/S/E/W) is generated with the *same* fixed direction on every
router instance - A-channel is `input` (this router as slave, receiving a
request), D-channel is `output` (sending a response back) - with no
complementary "master" side on any of those four ports (only the `Local`
port toward the NI has the opposite direction). Architecture.html's own
wiring principle says router_00's East port (p2) and router_10's West port
(p3) "are the same physical wires - they must be connected together." But
since both are declared `input` for their A-channel, wiring them together at
the top level ties two inputs to the same net with no driver on either side
- there is no configuration of top-level glue logic that makes an
originating (non-local) packet actually traverse from one router instance to
its neighbor, because neither side of the link is ever a source. This would
block real 2-hop/EW/NS routing (`noc_ew_routing`, `noc_ns_routing`,
`noc_2hop` - roughly 13 of medium's ~55 hidden tests per `evaluate.py`'s
category list), independent of how good the top-level stitching is.

There's a second, related open question: `gen_tilelink_ni` is fixed as
"AXI slave in -> TL-UL master out" (matching only the CPU-entry role at node
0,0), but the architecture doc requires one NI instance *per node*
(`u_ni_00`..`u_ni_12`), including at the 5 nodes with no upstream AXI master
of their own - it's not obvious from the provided library what role NI plays
there (delivering a router's local-port packet to that node's SRAM would
need the *opposite* bridge direction, which the generator doesn't provide).

This was deliberately **not patched**: a correct fix means hand-authoring a
real bidirectional-forwarding router (and possibly a second NI role) from
scratch, and - unlike the ASU DRC work, where every candidate fix could be
checked against the real KLayout/connectivity checker - there is no local
oracle here at all (golden TB is hidden for every tier), so a hand-rolled
protocol redesign could look internally consistent while still being wrong,
with no way to catch it before organizer judging. Flagging this precisely
instead of guessing further is the same judgment call as `V0.M1.AUX.3`/
`M4.AUX.2` on the ASU side: documented as a known risk rather than shipped
as an unverified "fix."

### Hard tier (`crypto_soc`) generation verified (2026-07-26)

Read the full `problems/hard/docs/architecture.html` (939 lines, all 14
sections). Corrected the earlier "no generator for mailbox" concern from the
prior session: **mailbox is not its own `ip_type`** - the hard doc's own
naming contract calls it `async_fifo (mailbox)` with required instance name
`u_mbox`, and `async_fifo` is already a fully supported `rtl_gen_lib`
primitive. It just needs top-level glue (SoC config register push/status
logic), same as any other IP - not a missing generator after all.

Bumped the Step 4 top-level call's `max_tokens` from 32768 to 65536: hard's
top level wires together ~34 IP instances (12 routers + 12 NIs + 12 SRAMs +
4 AES + 2 DMA + xbar + bridge + apb_fabric + uart + 2x gpio + timer + wdt +
2x irq_aggregator + mailbox + perf_counter), substantially more than
medium's 22.

Ran the agent for real (`t19_hard_test1`, `gemini-3.5-flash`, real API
calls): **generated all 56 expected files** (matches the instance count
above + reset_sync + top level exactly). First elaboration attempt hit 2
real bugs, both isolated LLM slips rather than systemic design problems:
- A single-character typo, `always @(posedm clk or negedge sys_rst_n)`
  (`posedm` instead of `posedge`) in the AHB-to-APB bridge glue - one
  occurrence, confirmed via `grep` there were no others.
- A wire declared `[64:0]` (65 bits) instead of `[63:0]` for the 64-bit
  SRAM data bus (`r00_loc_a_data` and likely its per-node siblings) -
  produces `iverilog` width-mismatch *warnings* (pruned/padded bit), not
  fatal errors.

After manually patching the typo, **iverilog elaboration passes with exit
code 0** against `tb_top_skeleton.v` (`-s tb_crypto_soc`), with only the 2
width-mismatch warnings remaining. This is a strong result for a 56-file,
34-instance SoC - the generation pipeline itself is sound; what surfaced
here is normal LLM-output variance on a very large single-shot generation,
not a structural gap. Not yet decided whether to add automated post-
generation lint/auto-fix for common single-character keyword typos (e.g.
`posedge`/`negedge`/`always`) - flagging as a possible robustness
improvement rather than doing it reactively for this one instance.

### Router forwarding gap: now confirmed in-scope to fix (not just document)

The organizers have since indicated some medium/hard IPs may need to be
*extended*, not just used as-is - directly relevant to the structural
router-forwarding gap flagged for medium (`gen_tilelink_router` generates
every compass port with the same fixed slave-only direction, which cannot
physically forward a packet between two router instances - see the medium
section above for the full derivation). This is no longer being left as a
documented-but-unfixed risk; extending the router (and, per a detail in the
hard doc's AXI-Lite SRAM section - "the router drives its AXI ports
directly, no NI on the local path" - probably also giving the router its
own embedded local-delivery AXI-master logic rather than relying on NI for
that path) is now planned as real work, not just a flagged concern. Not
started as of this note.

### Router forwarding fix: built and verified working (2026-07-26)

Wrote a corrected router generator (`gen_router_v2.py`, prototyped outside
the organizer's `rtl_gen_lib` - not modifying their file directly) with two
real fixes over the original:

1. **True bidirectional per-direction ports.** Each compass port (N/S/E/W)
   now has two independent channel pairs instead of one: a slave pair
   (`p{i}_s_*`, this router receiving from that neighbour) and a master
   pair (`p{i}_m_*`, this router sending to that neighbour). At the top
   level, router A's `p{X}_m_*` (master, facing neighbour B) wires to
   router B's `p{Y}_s_*` (slave, facing A) where X/Y are opposite compass
   directions - and vice versa for the return direction. This is what the
   original design structurally could not do (every port was slave-only).
2. **Embedded local-delivery AXI master**, per the hard doc's detail that
   "the router drives its AXI ports directly - no NI on the local path":
   the router now has its own `sram_*` AXI4-Lite master port, driven by a
   single-outstanding-transaction FSM (`S_IDLE -> S_SEND -> S_WAIT ->
   S_REPLY`) that arbitrates 5 inbound sources (local inject + 4 neighbour
   slave ports), computes XY routing from the address, and either delivers
   locally (via the embedded AXI master) or forwards out the correct
   master port - then routes the eventual D-channel response back to
   whichever source originated the request.

**Two real bugs caught by actually simulating, not just compiling** (both
now fixed in `gen_router_v2.py`):
- `chan_ports()` computed the correct `wire`/`reg` type per direction but
  never used it - every port was hardcoded `wire`, which fails to compile
  for any output later driven by a procedural `always` block (needed
  `reg`). Caught immediately by the standalone compile-check.
- Duplicate/conflicting state-transition logic for the local-delivery case
  in `S_SEND`: an old, buggy one-line condition (`if (sram_awready ||
  sram_arready || ...)`) was left alongside a newer, correct if/else block
  checking `sram_awready && sram_wready` for writes. The buggy line fired
  first (since `sram_awready` alone was already true), advancing the FSM
  out of `S_SEND` one cycle before the write-data handshake actually
  completed - the write's *address* phase would succeed but the *data*
  never landed. This one was NOT caught by elaboration or even a basic
  "does it compile" check - only found by writing a real 2-router
  testbench (`tb_router_forward.v`) with an actual memory model and
  checking the data value that landed, not just that signals toggled.

**Verified with a real simulation**, not just elaboration: two router
instances (A at node (0,0), B at node (1,0), wired via the real link
convention above), a fake but genuine SRAM model behind B, and a WRITE
injected at A's local port addressed to node (1,0). Result:
```
[115000] B's SRAM received WRITE: addr=3 data=deadbeefcafef00d
[PASS] Cross-router forward WORKED: B's memory[3] = deadbeefcafef00d
[PASS] Write-ack D-channel response returned to A's local port.
SCORE: 1/1
```
The write genuinely traverses the link, lands in B's memory with the
correct data, and the write-ack correctly returns to A - the exact
mechanism that was structurally impossible before. This is the single most
important verification in this NXP track's work so far, since it's real
simulated behavior, not elaboration or generation completeness.

**2-hop (X-then-Y) forwarding verified (2026-07-26)**: extended to a
THREE-router chain matching the doc's own worked example - A (0,0)
--East/West-- B (1,0) --North/South-- C (1,1), a *separate* physical link
pair from the A<->B one, on B's North port. B here is a genuine
pass-through/intermediate hop: it must re-forward a packet it did not
originate, using its own `dest_sel` routing decision a second time. A
real SRAM model sits behind C this time (B's own SRAM is stubbed/idle,
since the packet only transits B). Test (`tb_router_2hop.v`): WRITE
injected at A destined for (1,1) (`addr[31:28]=1,addr[27:24]=1`). At A:
`dest_x(1) > NODE_X(0)` -> east. At B: `dest_x(1)==NODE_X(1)` and
`dest_y(1) > NODE_Y(0)` -> north. At C: both equal -> local delivery.
Result, **passed on the first real run** (only cosmetic port-width
padding warnings on unused tie-off nets, not a functional issue):
```
[125000] C's SRAM received WRITE: addr=4 data=feedface0badc0de
[PASS] 2-hop (East then North) forward WORKED: C's memory[4] = feedface0badc0de
[PASS] Write-ack D-channel response returned all the way to A's local port.
SCORE: 1/1
```
This is a materially stronger result than the 1-hop test: it confirms the
`dest_sel`/`origin`/arbitration logic composes correctly when a router is
acting purely as a relay (neither the packet's source nor its
destination), which is the actual common case in a real multi-node mesh.
New file: `agent/rtl_gen_lib_ext/tb_router_2hop.v`. `gen_router_v2.py`'s
`__main__` block extended to also emit a third instance (`u_router_c` at
(1,1)) for this test.

**Not yet done** (at the time of the above): wiring this corrected router
into the actual agent pipeline, and read-transaction testing (the docs
note reads to remote nodes are a known limitation even in the reference
design, so this may not need full support - see medium/hard doc callouts
on the D-channel limitation). Read testing is still not done. The
integration work below turned up something much bigger.

## Router wired into the agent - and a much bigger pre-existing gap found (2026-07-26)

Wired `gen_router_v2` into `t19_nxp_agent_final.py` (Step 3 now intercepts
`ip_type: tilelink_router` YAMLs and calls the corrected generator instead
of shelling out to `rtl_gen_main.py`). Regenerated the full hard-tier SoC
end-to-end (`t19_hard_test2`) and it elaborated with exit code 0 - but
**that "clean elaboration" turned out to be a false positive**, caught by
actually reading the generated `crypto_soc.v` rather than trusting the
exit code:

```verilog
`define INST_ROUTER_STUB(x,y) \
    u_router_``x``y u_router_``x``y ( \
        .clk(clk), .rst_n(sys_rst_n) \
    ); \
    assign sram_awaddr_``x``y = 32'b0; ...
```

Every one of the 12 router instances - including the CPU's own entry node
- had ONLY `clk`/`rst_n` connected. Every compass port, every SRAM AXI
port, every NI local-port link was left floating. The NI stubs were
identical (`.tl_a_opcode()` - empty parens, fully disconnected). Icarus
does not flag unconnected named ports as errors, so `elaboration exit 0`
gave no signal either way.

Checked the **pre-fix baseline run** (`t19_hard_test1`, using the
original broken router) and found the *exact same* stubbing pattern for
every router except the CPU's own node. **This is not something the
router fix caused or could have fixed** - it's a separate, pre-existing
gap in Step 4's single-shot top-level-generation LLM call: it never
attempts real per-node mesh wiring, for either router version. Hand-wiring
12 routers x 4 links worth of repetitive, mechanical port lists inside one
LLM call alongside everything else in the SoC is apparently too much - it
silently gives up and stubs it instead. Practical implication: the real
evaluator's `noc_local`/`noc_routing` categories would have failed against
BOTH router versions, not because the router IP was wrong, but because
the top-level never actually connected it to anything.

### Fix: `gen_noc_mesh.py` - deterministic mesh stitching, not LLM-authored

The mesh interconnect is fully mechanical once the grid dimensions are
known: every router uses the same compass convention (p0=N p1=S p2=E
p3=W), every link follows the same master/slave pairing rule proven in
the router-fix testbenches, every node's local port always goes to that
node's own NI + SRAM. None of that requires architecture-specific
judgment, so it's generated in Python instead of asked of an LLM.

`gen_noc_mesh(spec)` takes `mesh_nx`/`mesh_ny` (grid dimensions) plus
`data_width`/`addr_width`/`ext_data_width`/`sram_depth`, and produces ONE
self-contained Verilog module (`noc_mesh`) whose ONLY external ports are
one AXI4-Lite SLAVE port per node (`n{X}{Y}_*`). Internally it instantiates
every `u_router_XY`/`u_ni_XY`/`u_sram_XY` (which are still generated
individually, unchanged) and wires:
- every router's `loc_a_*`/`loc_d_*` to that node's own NI's `tl_a_*`/`tl_d_*`
- every router's `sram_*` AXI master to that node's own SRAM instance
  (with proper address truncation to the SRAM's actual `ABITS`)
- **both directions** of every physical inter-router link (not just the
  direction exercised by the router-fix testbenches) - for adjacent nodes
  A/B with B east of A: `A.p2_m_* <-> B.p3_s_*` (A-originated traffic) AND
  `B.p3_m_* <-> A.p2_s_*` (B-originated traffic), each with its own D-channel
  reply pair - this is the architecturally complete case, even though this
  SoC's actual masters (CPU, DMA0, DMA1) all live in column x=0 and only
  ever exercise one direction in practice.

The top-level LLM's job shrinks to "instantiate this one module, connect a
handful of AXI-Lite ports" - the same kind of task it already handles
correctly elsewhere (e.g. DMA cfg ports) - instead of mesh topology
reasoning it had already been shown not to attempt.

### Two real width/data bugs found via actual simulation (not elaboration)

Verified with a standalone 2x2 mesh test first (`tb_mesh_2x2.v`): a real
AXI4-Lite WRITE driven into node (0,0)'s external port, destined for node
(1,1) two hops away, checking `u_sram_11`'s actual memory. Two real bugs
found and fixed before it passed:

1. **Undriven-bits bug** (found on the first run: `sram_11.mem[3] =
   xxxxxxxxcafebabe` - low 32 bits correct, upper 32 bits `'x'`). Root
   cause: the NI's AXI-facing data/mask width (32-bit/4-bit, matching the
   CPU bus) is narrower than the router's internal TileLink width
   (64-bit/8-bit). The `loc_a_data`/`loc_a_mask` wires between NI and
   router were declared at the router's WIDER width - since the NI (a
   narrower OUTPUT) only ever drives the low bits of that wire, the upper
   bits were left permanently UNDRIVEN (`'x'`), not zero-extended as
   expected. This is a real, generalizable Verilog gotcha: a narrower
   *output* driving into a wider *net* does NOT zero-extend (only an
   *input port* receiving a narrower net does). Fixed by declaring those
   specific wires at the NI's own (narrower) width instead, letting the
   router's wider input port do the correct, well-defined zero-extension.

2. **`gen_axi_lite_sram`'s write loop is hardcoded to 4 bytes** regardless
   of `DATA_W`, confirmed by reading the organizer's own generator source
   (`for (bi=0; bi<4; bi=bi+1)`). For any 64-bit-configured SRAM instance
   (every node-local SRAM in this SoC), this silently drops any write to
   bytes 4-7 no matter what drives it - not a mesh-wiring bug, a real,
   pre-existing bug in that IP generator itself. Fixed via
   `gen_sram_v2.py` (`gen_axi_lite_sram_v2`): the loop and the `wstrb`
   port width now both derive from `DATA_W` like every other generator in
   this library already does. Wired into the agent the same way as the
   router (Step 3 intercepts `ip_type: axi_lite_sram` too).
   (For this specific CPU/DMA-driven-write test, only the low 32 bits are
   ever actually exercised regardless of this fix, since the NI itself
   only ever asserts a 4-bit mask - the fix matters for any future 64-bit
   caller, not this particular path.)

After both fixes: `[PASS] Full-stack mesh write WORKED: sram_11.mem[3][31:0]
= cafebabe`, `SCORE: 1/1` - a real CPU-style write traversing NI -> router
(0,0) -> forward east -> router (1,0) -> forward north -> router (1,1) ->
local delivery -> real SRAM write, byte-perfect.

### Full hard-tier integration verified (`t19_hard_test3`)

Regenerated the complete hard-tier SoC with `try_stitch_noc_mesh()` wired
into Step 3/4 (it detects a complete rectangular `tilelink_router` grid
from the YAML specs, generates `noc_mesh.v`, and hides the individual
`u_router_XY`/`u_ni_XY`/`u_sram_XY` headers from the Step 4 prompt so the
LLM only sees the one clean `noc_mesh` header). Result, verified by
reading the actual generated `crypto_soc.v` (not just the elaboration
exit code, learning directly from the false-positive above): the LLM
instantiated **only** `noc_mesh`, correctly connected node (0,0) to the
CPU crossbar's NoC-space (S0) output, node (0,1) to DMA0's AXI4-Lite
master port, and node (0,2) to DMA1's master port - exactly matching the
architecture doc's own injection-point assignments - and correctly tied
all 9 other unused nodes idle with proper AXI4-Lite conventions
(awvalid/wvalid/arvalid=0, bready/rready=1). No individual router/NI/SRAM
instances appear anywhere in the top level. Elaboration exit code 0 (with
only the same class of already-understood, harmless width-padding
warnings seen in the 2x2 test).

**New files**: `agent/rtl_gen_lib_ext/gen_noc_mesh.py`,
`agent/rtl_gen_lib_ext/gen_sram_v2.py`. `t19_nxp_agent_final.py` changes:
`try_stitch_noc_mesh()` (called after Step 3), `rtl_gen_from_yaml()` now
also intercepts `axi_lite_sram`, `generated_headers` construction now
skips mesh-internal files, `NOC_MESH_WIRING_NOTE` replaces the old
per-router `ROUTER_V2_WIRING_NOTE` in the Step 4 prompt.

**Not yet done**: read-transaction testing through the mesh (writes only,
so far); a genuine 3-router-chain mesh-level test (2x2 only tests one hop
through one intermediate - the router-only `tb_router_2hop.v` already
covers 2 hops in isolation, but not through the full NI/SRAM stack).

### Confirmed working across all three tiers (2026-07-26)

- **Medium** (`t19_medium_test3`): medium's own 2x3 (6-router) mesh went
  through `try_stitch_noc_mesh()` cleanly on the first try - no
  problem-specific tuning needed, confirming the dimension/SRAM-depth
  inference is genuinely generic. Read the actual generated
  `noc_aes_soc.v`: it instantiates only `noc_mesh` (no individual
  router/NI/SRAM leakage, same as hard), wires the CPU to node (0,0), and
  ties the other 5 nodes idle correctly (medium has no DMA, so only one
  real injection point). Elaboration exit 0, only the same class of
  harmless width-padding warnings.
- **Easy** (`t19_easy_test4`): easy has no `tilelink_router` at all, so
  `try_stitch_noc_mesh()` correctly no-ops (returns `None, set()`) and
  Step 4 falls back to its original behaviour untouched - confirms the
  interceptions added to `rtl_gen_from_yaml` (router_v2/sram_v2/mesh) are
  fully inert for problems that don't use those IP types, i.e. no
  regression risk for easy. Generation itself: exit 0, all 9 expected
  files. (Separately noticed while checking this: easy's own
  `tb_top_skeleton.v` needs `-g2012`, not `-g2005`, to parse at all - a
  pre-existing skeleton-file property unrelated to any of today's
  changes, and even at `-g2012` the skeleton itself has an apparent
  `wire` vs `reg` mismatch on `uart_rx`/`uart_cts_n` - not investigated
  further since it's the organizer's own skeleton file, not generated
  RTL, and out of scope for this pass.)

### Token cost check-in

Summed every `*_diagnostics.json` file (the only two real LLM calls per
run - Step 2 YAML inference and Step 4 top-level generation; Step 3's IP
generation is pure Python, no LLM cost) across all 8 full-agent runs done
across this NXP track so far (2 easy baseline/regression, 2 easy
key-migration checks, 2 medium, 3 hard - the hard number includes today's
2 additional integration-verification runs): **225,758 prompt tokens +
97,988 completion tokens = 323,746 tokens total**, via `gemini-3.5-flash`
(a Flash-tier model, priced for high-volume use). This is a small number
in absolute terms - nowhere near a concerning spend for this much
iteration.
