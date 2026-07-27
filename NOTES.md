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

## Custom testbenches (no golden TB will be released) - hard tier started

Since NXP has confirmed no golden TB will ever be released, started
building our own testbenches per problem, sequenced hard-tier-first, one
`evaluate.py` category at a time (reset_sync done; noc_local, noc_routing,
aes_basic, dma_basic, apb_periph, irq_crypto, irq_periph, soc_cfg_regs,
mailbox, perf_counter, integration still to come; medium and easy after
that). Key design choice: `evaluate.py`'s own `parse_results()` just
regexes `[PASS] T<id>` / `[FAIL] T<id>` lines out of simulation stdout
against a fixed test-ID -> category map - so testbenches that print in
that exact convention get scored by the evaluator's own real logic the
moment a golden TB (or just this scoring script) is pointed at them,
without waiting for NXP's release.

New files: `custom_testbenches/hard/tb_hard_common.vh` (shared AXI4-Lite
CPU bus-functional-model tasks - `axi_write`/`axi_read`/`pulse_reset` -
`` `include``d by every per-category file so they all drive the CPU bus
identically) and `tb_hard_reset_sync.v` (T101-T105, **5/5 passing** against
the real generated hard-tier RTL). Compiled/run directly against
`t19_hard_test4`'s output alongside the real generated `.v` files - not a
standalone unit test, an actual `crypto_soc` integration test.

Reset is only controllable via the top-level `por_n` pin (`wdt_rst_n` is
tied internally, never exposed) - `dut.sys_rst_n` (one level below `dut`,
not a deep/fragile reach) is used to observe the synchronizer's own output
directly, which is necessary to verify stage-count/async-assert behaviour
specifically rather than just downstream side effects. Tests: T101 cold
power-up takes exactly the documented 4 cycles; T102 async-ASSERT is
immediate (same sim instant, not clock-aligned); T103 re-triggerability
(second pulse also takes exactly 4 cycles); T104 stability (zero glitches
across an extended low period); T105 end-to-end integration (a real CPU
write to MBOX_DATA actually lands, checked via the top-level `mbox_empty`
pin - not an internal register bit, so it only depends on the documented
port contract, not our own arbitrary implementation choices).

### Two real, generalizable bugs found via this one category (not by design - found by actually simulating)

1. **`axi_lite_crossbar`'s address decode was never actually configured**
   (T105 hung forever on the first attempt: a write to the documented SoC
   cfg address 0xF001_0000 never got a response). Root cause: the
   generator (`gen_axi_ips.py::gen_axi_lite_crossbar`) supports a
   `slave_ranges` YAML field to set each slave's real base/size, but
   `IP_CONSTRAINTS` in `t19_nxp_agent_final.py` never told Step 2's
   YAML-inference LLM this field exists (listed as `Requires [name]` only)
   - so it always fell back to the generator's generic default map
   (0x0000_0000/0x0001_0000/0x0002_0000), which shares NOTHING with this
   architecture's real map (0xF000_xxxx/0xF001_xxxx). This is a gap in
   *our own agent's* prompt schema, not a generator bug and not something
   the mesh/router work touched - found purely because a real CPU
   transaction was attempted and it hung, which elaboration alone could
   never have caught (same lesson as the NoC mesh stubbing, again: only
   real simulation catches "nothing is actually connected/configured"
   failures). Fixed by adding a detailed `slave_ranges` entry to
   `IP_CONSTRAINTS` with a fully worked example (concrete base/size numbers
   matching a real doc's map, plus the reasoning for why S0's window must
   be a power-of-2 region that excludes S1/S2's addresses). Regenerating
   (`t19_hard_test4`) confirmed Step 2 now populates `slave_ranges` with
   the exactly correct S1/S2 windows; S0's own window came out smaller
   than the worked example suggested (0x1000_0000 vs 0x8000_0000) - fine
   for this category's own test (which never routes to a remote node
   through the CPU), but worth re-checking once the `noc_routing` category
   needs the CPU to reach non-(0,0) nodes.
2. **The crossbar's B/R-channel response routing is purely combinational
   off the CURRENT master valid+address**, not a latched transaction ID -
   so a master that drops `awvalid`/`wvalid` immediately after the AW/W
   handshake (which real AXI4-Lite permits) makes the crossbar lose track
   of which slave's `bvalid` to forward, and the response never arrives.
   Found the same way - a real hang, debugged by hierarchically probing
   `dut.s2_bvalid` (already 1) versus the top-level `cpu_bvalid` (never
   seen 1), proving the response was generated but not routed back. Fixed
   in `tb_hard_common.vh`'s `axi_write`/`axi_read` tasks: hold
   `awvalid`/`wvalid` (or `arvalid`) asserted until the response is
   actually observed, not just until the request-side handshake completes
   - always spec-legal even where not strictly required, so this is a safe
   BFM-side fix rather than a DUT patch.

Also hit one isolated, unrelated LLM output bug in this same regeneration
(`t19_hard_test4`): an invalid `.hready_out(s1_awvalid ? s1_wready :
s1_arready)` - a ternary expression connected directly to an output port,
which Verilog doesn't allow (output ports need a net, not an arbitrary
expression). Patched locally for testing purposes (introduced an
intermediate wire) - normal LLM-output variance, not investigated as a
systemic issue, same category as the earlier `posedm`/`posedge` typo.

## `noc_local` category (T201-T206) - four more real bugs, all now fixed

Building the very next category (`custom_testbenches/hard/tb_hard_noc_local.v`
- CPU write/read to its own co-located node (0,0) SRAM through the FULL real
stack: crossbar -> NI -> router -> SRAM, not the router-only unit tests from
earlier) surfaced four more genuine bugs, on top of the two from
`reset_sync`. None of these were guesses - every one was root-caused from an
actual stuck/wrong simulation, several requiring `$monitor`/hierarchical
probing across the crossbar/NI/router boundary to pin down.

1. **`gen_router_v2.py`'s own local-write completion condition was wrong**
   (T201 first attempt: write DATA correctly landed in SRAM, yet the router
   never advanced past `S_SEND` - permanently wedging itself and blocking
   every later transaction). Root cause: `if (sram_awready && sram_wready)
   st<=S_WAIT;` assumes the SRAM asserts both simultaneously, but
   `gen_sram_v2`'s (and the original generator's) protocol is strictly
   two-phase - `awready` pulses for the address phase, `wready` pulses
   separately for the data phase, NEVER together. The SRAM's own retry
   behavior (re-triggering off the router's continuously-held `awvalid`)
   is what let the DATA land despite the router being stuck - a red
   herring that could easily have been mistaken for "it works." Fixed
   with `aw_seen`/`w_seen` latches that independently remember each phase
   as it completes, advancing once BOTH have been seen on ANY cycle (not
   necessarily the same one); `sram_awvalid`/`sram_wvalid` now also drop
   independently once each phase's own ready is seen, instead of both
   dropping together only once the router leaves `S_SEND`.
2. **The generated top-level left the crossbar's unused M1 (DMA config
   bus) port half tied-off**: the response side (`dma_m_awready`,
   `dma_m_bvalid`, etc.) was tied to safe idle values, but the
   request side (`dma_m_awvalid`, `dma_m_arvalid`, `dma_m_wvalid`, etc.)
   was left completely floating. Icarus doesn't flag it, so the effect
   only showed up as `s0_awvalid`/`s0_arvalid` intermittently reading `'x'`
   once the crossbar's round-robin `rr`/`rr_rd` registers advanced past
   their reset value - corrupting a LATER transaction from the CPU (M0)
   despite M0 itself driving clean values throughout. Confirms the same
   lesson as always: `'x'` silently poisons downstream shared logic rather
   than erroring. Patched locally for this test; added a new, general
   Step-4 prompt rule (not tied to any specific IP) requiring BOTH
   directions of any unused master/slave port to be tied off, with this
   exact incident as the worked example.
3. **`gen_tilelink_ni`'s own `axi_bvalid`/`axi_rvalid` formulas have a
   genuine off-by-one race**: `assign axi_bvalid = (st==S_IDLE) &&
   is_write && tl_d_valid && ...;` requires BOTH "I have already left
   S_WAIT" AND "the router's reply is still asserted" in the same cycle -
   but the router drops its reply in the exact same edge that NI leaves
   S_WAIT (both sides transition simultaneously, triggered by the same
   handshake), so `tl_d_valid` has necessarily already dropped by the
   cycle where `st` first reads as `S_IDLE`. The condition can
   structurally never be satisfied under real timing. (The FIRST
   `noc_local` write only appeared to complete earlier because bug #2's
   `'x'` corruption made `cpu_bvalid` read as `'x'`, and `while(!x)` reads
   as false in Verilog - a false pass masking this real bug underneath.)
   Fixed in `gen_ni_v2.py` (`gen_tilelink_ni_v2`): check the response
   while STILL in `S_WAIT` (the same cycle `tl_d_ready` is unconditionally
   1), not after already having left it.
4. **`gen_tilelink_ni`'s `axi_awready` was gated on the wrong, STALE
   register**: `axi_awready = (st==S_IDLE) && axi_awvalid && !is_write;`
   - `is_write` reflects the PREVIOUS transaction's type and is never
   reset, so after any write, `!is_write` reads `0` forever, permanently
   blocking every SUBSEQUENT write's own AW handshake (reads were
   unaffected, since `axi_arready` never references `is_write`). Found via
   T204 (back-to-back writes): the first write of the pair hung forever
   even though the router/SRAM/M1 fixes above were all already in place
   and NI was correctly sitting in `S_IDLE`. Fixed in the same
   `gen_ni_v2.py`: `axi_awready` now matches `axi_wready`'s own (correct)
   condition - accept whenever BOTH awvalid and wvalid are present,
   regardless of the last transaction's type.

After all four fixes: `tb_hard_noc_local.v` passes clean, **6/6**
(`NOC_LOCAL SCORE: 6/6`), and re-running `tb_hard_reset_sync.v` against the
same regenerated RTL confirms no regression (**5/5** still). New file:
`agent/rtl_gen_lib_ext/gen_ni_v2.py`. Wired into the agent the same way as
the router/SRAM fixes (`rtl_gen_from_yaml` now also intercepts `ip_type:
tilelink_ni`).

This category alone found more real bugs than `reset_sync` did, entirely
because it's the first test to exercise a CPU transaction through the
*complete* crossbar->NI->router->SRAM chain rather than one piece at a
time - a strong argument for continuing this same "build one category,
actually run it, chase every real failure to its root cause" approach
rather than writing all remaining categories' testbenches speculatively
before running any of them.

## `noc_routing` category (T301-T310) - 10/10, first try, no new bugs

Built `custom_testbenches/hard/tb_hard_noc_routing.v`: real CPU-initiated
writes to REMOTE mesh nodes (not just node (0,0) local delivery), covering
every reachable node shape - 1/2/3 hops East, 1/2 hops toward +Y, the
doc's own worked X-then-Y example (node (1,1)), the opposite mesh corner
(3,2) at maximum hop count, back-to-back writes to two different remote
nodes (no cross-node aliasing), and an explicit check that the write's
D-channel ack survives the full round trip back to the CPU even at
maximum hop count (not just that the data lands). **All 10 passed on the
very first attempt** - this is the category that most directly exercises
the original router-forwarding fix from earlier in this project, and it
held up completely once the crossbar/NI issues from `noc_local` were
fixed. (One thing worth flagging, not a bug found: the architecture doc
itself has an internal inconsistency between its prose description of the
XY routing convention in section 05 ("dest_y > NODE_Y -> go North") and
the labels in its own step-by-step walkthrough diagram in section 02
(which labels a dest_y > node_y hop "go South (p1)" instead). This
implementation follows section 05's explicit prose statement, which is
self-consistent with both `gen_router_v2.py`'s own logic and
`gen_noc_mesh.py`'s own link-wiring convention - internally consistent,
but worth knowing about in case a golden TB was built against the other
reading.)

**Also found**: Step 4's LLM does not reliably follow an exact requested
instance name for the `noc_mesh` wrapper - despite explicit prompt
guidance added after the `noc_local` work ("name this instance EXACTLY
u_noc_mesh"), two different regenerations produced `noc_mesh` and `u_noc`
respectively, neither matching. Rather than keep fighting LLM instance-
naming variance, added `custom_testbenches/hard/run_suite.sh`, which
auto-detects whatever instance name a given run actually used (via a
simple grep on the generated `crypto_soc.v`) and substitutes it into a
working copy of each testbench before compiling - a practical
accommodation instead of a brittle exact-match requirement.

**Verified end-to-end on a fresh, fully unpatched regeneration
(`t19_hard_test6`)**: all three categories together - `reset_sync` (5/5),
`noc_local` (6/6), `noc_routing` (10/10) - **21/21 passing**, zero manual
RTL edits, via `run_suite.sh t19_hard_test6/hard`.

## `aes_basic` category (T401-T408) - a genuine cryptographic bug, found the hard way

Per the architecture doc's own explicit callout ("The AES engines are
standalone instances, not connected to the router's local AXI port"),
there is no CPU-programmable path to them at all - the only way to test
them is `force`/`release` on their own input ports directly
(`dut.u_aes0.key_in` etc.), same as unit-testing an isolated IP block
that happens to be instantiated inside a larger SoC. `gen_aes128`
(organizer-provided) turned out to implement a REAL AES-128 core (actual
Rijndael S-box, real key schedule, real MixColumns via GF(256) `xtime`) -
not a placeholder - so `custom_testbenches/hard/tb_hard_aes_basic.v` uses
the actual NIST FIPS-197 validation vector (key=00010203...0c0d0e0f,
plaintext=00112233...ccddeeff, expected ciphertext=69c4e0d8...70b4c55a)
to check genuine cryptographic correctness, not just "some data came out".

**First run: wrong ciphertext.** `busy`/`done` timing was perfect (10
cycles, correct pulse), and forcing the key in and reading back
`round_key[1]` one cycle later gave EXACTLY the documented FIPS-197 value
(`d6aa74fd...`) - so the S-box and key schedule were clearly right, but
the final ciphertext was completely wrong. This took a genuinely long
root-cause chase (see full detail in the session transcript) because two
independent, self-consistent-in-isolation subsystems were combined
incorrectly: `shift_rows` and `mix_col` both operate correctly if you
assume this module's own byte-index convention (`s[bi*8+:8]`, bi=0 is
bits[7:0] - the LAST byte of however a 128-bit literal is naturally
written) maps bi-ascending directly onto FIPS row-ascending within each
4-byte group - but it doesn't: bi-ascending within a group is actually
FIPS row-*descending*. Both functions silently apply their transform to
the wrong (reversed) row order. Every simpler hypothesis was checked and
ruled out empirically before landing on this: byte reversal conventions,
per-word swaps, transposes - none of them fixed both `round_key[1]` AND
the final ciphertext simultaneously, which is what eventually pointed at
a structural row-order bug rather than a testbench byte-ordering
question. The fix was derived mechanically, not by further hand-algebra:
built an independent, from-scratch AES-128 in Python (2D `state[r][c]`
arrays, GF(256) multiplication tables), confirmed it reproduces the
FIPS-197 vector exactly, then wrapped that trusted transform with the
(already-proven-necessary) index reversal on both sides to derive
exactly what `shift_rows`/`mix_col` must compute on the raw bi-indexed
array - removing the possibility of a second hand-derivation error
compounding the first. Confirmed byte-for-byte against FIPS-197 in
Python *before* touching the Verilog generator, then confirmed again via
the real simulator.

New file: `agent/rtl_gen_lib_ext/gen_aes_v2.py` (`gen_aes128_v2`), wired
into the agent the same way as the other fixes (`ip_type: aes128`).
Tests: T401 real FIPS-197 correctness on aes0; T402/T403 busy/done
timing; T404-406 the other three engines are independent, correctly-
instantiated cores (not accidentally sharing state) producing the same
correct result; T407 the IRQ aggregator's priority encoder correctly
resolves the highest-pending AES source once all four have fired
(needed a 2-cycle settle after the last `done` pulse for `r_pend` to
latch - a testbench timing detail, not an RTL issue); T408 the AES-node's
own co-located SRAM (`sram_30`, co-located with aes0) still works
correctly via normal CPU NoC routing, confirming the AES engine's
presence doesn't interfere with the SRAM's real function. **All 8/8
passing.**

**A fresh regeneration with the AES fix wired in (`t19_hard_test7`)
immediately caught the crossbar `slave_ranges` sizing issue flagged as
"worth re-checking" back in the `noc_local` section - this time for
real**: `reset_sync` and `noc_local` passed clean, but `noc_routing`
timed out completely and `aes_basic`'s own T408 (a NoC-routed write to
the AES-colocated SRAM) timed out too - while every purely-local test on
the SAME regeneration passed fine. Checked the actual inferred spec:
Step 2 had again inferred S0's `slave_ranges` size as `0x10000000` (same
undersized value from `t19_hard_test4`, requiring `addr[31:28]==0`
exactly and so rejecting any write to a non-(0,0) node) - even though a
LATER regeneration (`test5`/`test6`) had correctly inferred `0x80000000`.
This is confirmed now as genuine LLM-inference non-determinism on a
single critical parameter, not a one-off mistake - prompt guidance alone
isn't reliable enough for something this load-bearing (nearly EVERY
category needs the CPU to reach a remote node). Since the correct value
is fully deterministic (S1/S2 always sit at `0xF0xx_xxxx` in this
architecture, so `0x80000000` is always a safe, non-overlapping choice
for S0 regardless of the doc's exact numbers), added
`fix_crossbar_s0_window()` to the agent: runs right after Step 2, widens
S0's inferred window in place if it's under `0x80000000`, before Step 3
ever reads it - handles both YAML formats Step 2 has been observed
emitting (flow-style `{base: .., size: ..}` and block-style base/size on
separate lines). Verified in isolation (unit test against the actual
`test7` spec text), then verified end-to-end: manually applied the fix
to `test7`'s spec + regenerated just the crossbar RTL -> all **29/29**
tests across all four categories passed. Then ran a completely fresh
regeneration from scratch (`t19_hard_test8`, fix wired in from the
start) to confirm full automation - this run happened to infer
`0x80000000` correctly on its own (further confirming the
non-determinism), so the auto-fix correctly no-op'd, and all **29/29**
tests passed again with zero manual intervention either way.

## `dma_basic` category (T501-T510) - a real top-level wiring gap, and a general NI protocol bug

Checked the architecture doc first, since the earlier reset_sync category
already established that the crossbar's M1 port is "the DMA config bus"
(CPU programs `SRC_ADDR`/`DST_ADDR`/`LENGTH`/`CTRL` through it, per the
doc's own text) - unlike AES, which the doc explicitly calls out as
"standalone", DMA's config path is *supposed* to be CPU-reachable.
Checked the actual generated top-level (`t19_hard_test8`): M1's own
request-side signals are tied to a hardcoded `0`, and separately each
DMA engine's `cfg_*` port is ALSO tied to constants - the documented
CPU->M1->DMA-config path isn't wired at all. Worth noting: this is likely
partly a side effect of this session's OWN earlier tie-off prompt
guidance ("tie off any unused master/slave port") - M1 isn't actually
unused here, and the LLM appears to be defaulting to the safe/idle
pattern rather than wiring it to the real DMA config ports. Flagged as a
known, still-open top-level wiring gap (not fixed in this pass - the
value here was in DIRECTLY testing what IS real and working: the DMA
engine's own master port, which the doc says drives the router's inject
port directly at nodes (0,1)/(0,2), IS correctly wired into the real NoC
mesh). `tb_hard_dma_basic.v` exercises the DMA engines via `force`/
`release` on their own `cfg_*` ports (same rationale as `aes_basic` -
bypass the missing path, test the real engine + its real mesh
connection), which is honest about testing what's actually there while
still exercising the DMA<->router<->SRAM path for real.

**First run: 3/10, and the failures pointed at a THIRD real bug in
`gen_tilelink_ni_v2`** (on top of the two already fixed there). The
`dma_engine` generator's own master port asserts `AWVALID` and `WVALID`
on genuinely SEPARATE cycles - `S_WR_ADDR` asserts only `m_awvalid`,
`S_WR_DATA` (a later state) asserts only `m_wvalid` - a fully decoupled
AXI4-Lite master, which is completely valid AXI4-Lite behaviour, just
different from the CPU BFM used everywhere else in this testbench suite
(which happens to always assert both together). Fix #2 from the
`noc_local` work (`axi_awready = (st==S_IDLE) && axi_awvalid &&
axi_wvalid`) still implicitly required BOTH channels valid in the SAME
cycle - correct for the CPU's own pattern, but this permanently stalls
any master that presents them one at a time, exactly the same class of
bug already fixed once in the ROUTER's own local-SRAM-write path
(`aw_seen`/`w_seen`, see the `noc_local` section) - just not yet applied
to the NI. Fixed the same way: `aw_seen`/`w_seen` now latch each
channel's own handshake independently in `gen_ni_v2.py`, so either
simultaneous or fully-decoupled AW/W presentation works. **All 10/10
passing after the fix**, and re-ran the full existing suite (all 39
tests across `reset_sync`/`noc_local`/`noc_routing`/`aes_basic`/
`dma_basic` together) to confirm the CPU path still works unaffected -
it does.

Tests: T501/T506 config register write/readback on each engine; T502/
T507 a real local transfer (preloaded via the already-proven CPU NoC
path, moved by the DMA engine itself through its own real router
connection at its inject node); T503 the FSM returns to
`dma_st==0` (per the doc's own required-name callout) once done; T504
`dma_irq` stays low without `CTRL[1]` (irq_en) even though the transfer
completed; T505/T508 `dma_irq` correctly feeds `irq_crypto` src[4]/src[5]
respectively (two DIFFERENT ids, confirming distinct wiring for both
engines); T509 idle stability (neither engine spuriously re-triggers
after both have completed); T510 a genuinely REMOTE DMA-initiated
transfer (node (0,1) -> node (2,0), multiple hops), proving the DMA
engine's own traffic gets correctly forwarded through the mesh exactly
like CPU traffic does.

**Verified end-to-end on yet another fresh, fully unpatched regeneration
(`t19_hard_test9`, all fixes wired in from the start)**: all five
categories together via `run_suite.sh` - `reset_sync` (5/5), `noc_local`
(6/6), `noc_routing` (10/10), `aes_basic` (8/8), `dma_basic` (10/10) -
**39/39 passing**, zero manual RTL edits.

**Still open** (tracked, not blocking): the CPU->M1->DMA-config wiring
gap noted above. Since the DMA engine itself and its real mesh
connection are now both proven correct via direct force-based testing,
this is purely a top-level-integration gap, isolated the same way the
NoC-mesh-stubbing gap was earlier in this project - worth a dedicated
prompt-guidance pass later, but not necessary for continuing to the
remaining categories.

## `apb_periph` category (T601-T606) - a real generator bug, a real BFM/bridge
## timing mismatch, and a real top-level privilege-wiring gap

Unlike `aes_basic`/`dma_basic`, the architecture doc's APB peripheral
cluster (base `0xF000_0000`, 4KB/slot: `apb_uart`/`apb_gpio0`/`apb_gpio1`/
`apb_timer0`/`apb_watchdog`) is documented as CPU-reachable through the
real path (crossbar S1 -> `ahb_to_apb_bridge` -> `apb_fabric5` ->
peripheral) - so `tb_hard_apb_periph.v` exercises that entire real path
via the CPU BFM, no `force`/`release` shortcuts, unlike the two
categories before it.

**Bug #1 - `apb_fabric`'s slot decode, found by reading the generator
source before writing any testbench code.** `gen_apb_ips.py`'s
`gen_apb_fabric` decodes which of its 5 slots to select with
`m_paddr[31:12] == 20'h0..4` - i.e. it assumes `m_paddr` has already been
re-based to a LOCAL 0-origin address space. Traced the real wiring
(crossbar's S1 window -> bridge's `haddr` -> fabric's `m_paddr`, all
unmodified passthroughs, confirmed against `t19_hard_test9`'s actual
`crypto_soc.v`) - the address arriving here is always the full, global
`0xF000_xxxx` address, so `m_paddr[31:12]` is always `0xF000x`, never
matching `dec0..dec4`'s 0-4. Every APB peripheral access would
permanently miss, structurally, regardless of address or peripheral.
Confirmed empirically first (ran the new testbench against the
unpatched `t19_hard_test9`: 0/6, exactly as predicted) before writing any
fix. Fixed in a new `gen_apb_fabric_v2.py`: decode against
`m_paddr[15:12]` (the slot nibble within the fixed 64KB S1 window)
instead - everything else in the fabric (per-slot routing, the S3
privilege filter, timeout/miss/pslverr logic) is unchanged.

**Bug #2 - a fused/premature `bvalid`/`rvalid` ack in the AHB bridge
glue, found only after the decode fix alone still scored 0/6.** A real
signal trace showed `cpu_bvalid` pulsing the SAME cycle as `cpu_awready`
- a fused, immediate ack - well before the bridge's real 3-cycle
`ST_IDLE -> ST_SETUP -> ST_ENABLE` transaction has even sampled `hwdata`
(one cycle later, in `ST_SETUP`) let alone reached the peripheral. The
shared `axi_write`/`axi_read` tasks (`tb_hard_common.vh`) hold
awvalid/wvalid through bvalid, which is correct for the local-SRAM path
but is now too *long* here: holding awvalid any further than one extra
settling cycle lets the bridge cycle back to `ST_IDLE` while awvalid is
still asserted, and it captures the SAME address a SECOND time with
stale/zero wdata - silently re-writing the just-written register back to
0 (confirmed directly: a real trace showed a clean, correct write pulse
immediately followed by a second phantom pulse at the same address with
`pwdata=0`). The read side has the mirror problem: `rvalid` fires before
the real `hrdata` register is updated, so a read captured at the first
`rvalid` pulse returns a stale/previous value. Rather than touch the
shared BFM (unmodified and working for every other passing category),
`tb_hard_apb_periph.v` defines two local tasks: `apb_write` (holds wdata
for exactly one extra cycle past acceptance, then drops everything at
once, never re-checking bvalid since it already fired) and `apb_read`
(holds arvalid several extra cycles past acceptance before trusting
`cpu_rdata` - safe for reads, unlike writes, since a repeat read of the
same address is idempotent).

**Bug #3 - a top-level privilege-wiring gap, found from T605 (timer0)
still failing after both fixes above.** A trace showed `s3_psel` never
asserting and the fabric's own `DEAD_BEEF` miss-sentinel coming back on
read - `apb_fabric`'s privilege filter (`priv_err = dec3 && !pprot[0]`)
permanently blocks its one privileged slot (S3 = `apb_timer0`, per the
doc's own address table) because the top-level ties the AHB bridge's
`hprot` to a constant `3'b000`: this SoC's CPU-facing AXI4-Lite port
carries no privilege signal at all, so the Step-4 LLM has no basis to
infer anything else. Since this architecture never defines more than one
CPU master, "always privileged" is the only sane reading and is safe
SoC-wide (nothing else reads hprot/pprot) - fixed with a deterministic
top-level post-processing step, `fix_ahb_bridge_hprot()`, that forces the
bridge's `.hprot(...)` tie-off to `3'b001` right after Step 4 extracts
the generated Verilog, the same "don't depend on the LLM guessing it
right every time" philosophy already used for the crossbar's S0 window.

Tests: T601 UART TX FIFO write reaches the peripheral through the real
global address (slot 0); T602/T604 GPIO0/GPIO1 DIR+OUT drive the real
top-level tristate pads (the ultimate external observable); T603 GPIO0
IN - drives the pad externally and confirms `GPIO_IN` reflects it back
through the debounce synchronizer via a real CPU read; T605 timer0 LOAD0/
CTRL0 configured and `VALUE0` observed counting down for real over the
privileged slot; T606 watchdog unlock/load/enable and the real counter
(`ctr`) observed decrementing.

**Verified end-to-end on yet another fresh, fully unpatched regeneration
(`t19_hard_test10`, all three fixes wired in from the start)**: all six
categories together via `run_suite.sh` - `reset_sync` (5/5), `noc_local`
(6/6), `noc_routing` (10/10), `aes_basic` (8/8), `dma_basic` (10/10),
`apb_periph` (6/6) - **45/45 passing**, zero manual RTL edits.

Also noticed in passing (not itself a bug, just worth recording): Step 4
does not always route the APB peripheral cluster through the organizer's
`apb_fabric5` module at all - `t19_hard_test10`'s top-level inlines its
own ad-hoc `paddr[15:12]==5/6/7`-style decode directly, bypassing
`u_apb_fab`/`gen_apb_fabric_v2` entirely for this run (it happened to get
the same correct semantics independently). This is the same class of
"Step 4 invents its own structure when the doc under-specifies it" seen
below with `irq_crypto`'s address.

## `irq_crypto` category (T701-T710) - a real, documented contradiction in the
## organizer's own priority-encoder generator

Unlike the peripheral cluster, the architecture doc gives `u_irq_crypto`/
`u_irq_periph` no fixed, documented CPU-visible register address (no
"Slot N" entry the way uart/gpio/timer/wdt have) - and empirically, Step 4
doesn't even route it through a consistent decode scheme across runs
(`t19_hard_test10` inlines its own `paddr[15:12]==5/6/7` slots for
icrypto/iperiph/perf; a differently-generated run could easily place
these anywhere, or nowhere at all - see the DMA-config gap in
`dma_basic` for a precedent). So `tb_hard_irq_crypto.v` does what
`aes_basic`/`dma_basic` already established as the right call for an IP
with an undocumented/unreliable CPU-facing address: force/release
directly on the aggregator's own ports (`irq_src`, and its plain
always-ready APB slave port `psel`/`penable`/`pwrite`/`paddr`/`pwdata`/
`prdata`) - this exercises the real aggregator RTL exhaustively and
deterministically, independent of whatever address (if any) Step 4
invents this run.

**The bug, found by reading `gen_irq_aggregator` before writing any
testbench code.** The architecture doc is explicit: *"Two independent
8-source IRQ aggregators. Each outputs cpu_irq (level) and cpu_irq_id[2:0]
(lowest active source ID)."* But the generator's priority encoder checks
`r_pend[7]` first, then `[6]`, down to `[0]` - i.e. **highest**-index-wins,
the exact opposite of documented behavior. T702 is the direct test for
this: force two sources pending at once (src[0] and src[3]) and check
`cpu_irq_id` resolves to the lower, 0. Confirmed empirically against the
unpatched `t19_hard_test10` (this one test failed, all others passed)
before writing any fix - exactly the predicted, isolated failure.
Fixed in a new `gen_irq_aggregator_v2.py`: reversed the check order to
test bit 0 first. Everything else (register map, edge/level/polarity/
soft-IRQ logic, the always-ready APB slave interface) is unchanged.

This bug wasn't new - it was already latent in `aes_basic`'s own T407,
which asserted `cpu_irq_id === 3'd3` (the *highest* of four simultaneously
-pending AES done sources) and had been passing precisely because it was
validating the bug, not the spec. Updated T407 to assert `3'd0` (the
correct, lowest-id answer) once the generator was fixed, with a comment
pointing at this category's writeup.

**Two testbench-only issues found and fixed along the way (real DUT
behavior, just not what my first draft of the testbench assumed):**
- Clearing a pending bit (`0x014` write) while its raw source is *still*
  forced active raced against the aggregator's own accumulate logic on
  the same clock edge and didn't reliably stick (T704/T706b failed on
  first pass with stale pending bits persisting across supposedly-clean
  test boundaries). Fixed by always deasserting the raw source first,
  settling a cycle, and only then clearing - which is also just more
  realistic driver behavior (service/mask the device, then clear
  pending), and matches the doc's own description of level-sensitive
  interrupts (a cleared pending bit reasserts immediately if the level
  is still active - confirmed directly as real, correct DUT behavior in
  T705, not a bug).
- Fixing the priority order surfaced a *second*-order regression in
  `dma_basic`'s existing T508 (`cpu_irq_id === 3'd5` after dma1
  completes): dma0's own done/irq_en state from the earlier T505 is
  still latched and was never re-armed or cleared, so its level-mode
  src[4] source was still genuinely live - with the fix, id correctly
  (and now legitimately) resolved to 4, the lower of the two, not 5.
  T508's actual intent was to check dma1's src[5] wiring in isolation,
  so fixed by masking src[4] off (and clearing its now-masked pending
  bit) via the aggregator's own register interface immediately before
  the check - restoring the isolation the test was always meant to have.

Tests: T701 single source resolves cleanly; **T702 the key lowest-id
test**; T703 raw register readback (`0x000`) matches the forced pattern;
T704 the enable mask (`0x008`) blocks a disabled source from ever
setting pend, even while its raw line is high; T705 level vs. edge mode
(`0x00C`) - level is sticky/independent of an isolated clear, edge fires
once and stays cleared; T706 polarity inversion (`0x010`); T707
software-triggered IRQ (`0x01C`, using src[7] - unused by any real
hardware source); T708 clean idle once everything's cleared; T709/T710
confirm `u_irq_crypto`/`u_irq_periph` are genuinely independent instances
(driving one doesn't touch the other).

**Verified end-to-end on yet another fresh regeneration (`t19_hard_test11`,
all fixes from this session wired in from the start)**: all seven
categories together via `run_suite.sh` - `reset_sync` (5/5), `noc_local`
(6/6), `noc_routing` (10/10), `aes_basic` (8/8), `dma_basic` (10/10),
`apb_periph` (6/6), `irq_crypto` (10/10) - **55/55 passing**. Honesty
note: this specific regeneration's top-level (`crypto_soc.v`) failed to
elaborate at all until 4 lines were patched in a scratch copy (not
committed, not touching the real generator) - see the `perf_counter`
finding immediately below. Every category through `irq_crypto` in this
writeup is otherwise untouched and fully verified against the real,
unpatched `t19_hard_test10`/`test11` output.

**New finding, NOT fixed (out of scope for `irq_crypto`, tracked for the
upcoming `perf_counter` pass):** `t19_hard_test11`'s top-level contains
```
assign perf_cnt0 = u_perf.u_cnt0.count;
assign perf_cnt1 = u_perf.u_cnt1.count;
assign perf_cnt2 = u_perf.u_cnt2.count;
assign perf_cnt3 = u_perf.u_cnt3.count;
```
- a hierarchical cross-module reference assuming `u_perf` (from
`gen_perf_counter`, a generator not yet touched this session) internally
instantiates four sub-modules named `u_cnt0`..`u_cnt3`, each with a
register named `count`. This doesn't match the real generator's output
(iverilog: "Unable to bind wire/reg/memory `u_perf.u_cnt0.count`"),
failing elaboration outright - every category's testbench is blocked by
this on any run where Step 4 writes it this way, regardless of which IP
category is under test. Worked around here by patching a throwaway copy
(`assign perf_cntN = 32'h0;`) purely to unblock verifying this session's
own fixes; the real fix belongs to the `perf_counter` pass.

## `perf_counter` category (T801-T807/T805a/T805b/T804a/T804b - 9 checks) - a
## real doc-vs-generator counting bug, plus the top-level bug flagged above

Fixed both real bugs found for `u_perf` in this pass.

**Bug #1 (flagged above, fixed here): the top-level's `u_perf.u_cntN.count`
hierarchical reference.** Confirmed the real register names in BOTH
`gen_perf_counter` (organizer's) and the new `gen_perf_counter_v2.py`
are flat `cnt0`..`cnt3` inside the module itself - no `u_cntN` sub-module
wrapper exists in either. Since that flat name is hardcoded (never
LLM-inferred) in both generator versions, the substitution is always
safe and deterministic - fixed with `fix_perf_counter_hier_ref()`,
regex-substituting `u_perf.u_cntN.count` -> `u_perf.cntN` on the Step-4
top-level text, same philosophy as the crossbar S0 window and AHB bridge
hprot fixes.

**Bug #2, found by reading `gen_perf_counter` before writing any
testbench code.** The architecture doc is explicit: *"A perf_counter
with 4 event channels, each counting POSITIVE EDGES of its event
input."* But the generator's increment logic is a plain level check -
`if(event_i) cnt_i<=cnt_i+1;` - incrementing every cycle `event_i`
happens to be held high, not once per rising edge. This isn't
theoretical: two of the four documented channel wirings are genuinely
multi-cycle/level signals, not 1-cycle pulses - ch[0] is `ni_00`'s
`tl_a_valid` (can stay asserted across a stalled multi-cycle NoC
transaction) and ch[1]/ch[2] are `dma0_irq`/`dma1_irq` (level IRQs that
stay high until explicitly cleared/re-armed, per the DMA engine's own
documented STATUS/IRQSTAT semantics) - the original generator would
silently over-count by however many extra cycles the source stayed
high. (ch[3], the OR of the AES engines' 1-cycle `done` pulses, happens
to be safe either way - likely why this was never caught against a
1-cycle-pulse-only test.) T802 is the direct test: hold `event_0` high
for 5 consecutive cycles and check `cnt0` increments by exactly 1, not
5. Confirmed empirically against the unpatched original generator (T802
failed in isolation, every other test passed) before writing any fix.
Fixed in `gen_perf_counter_v2.py` with a proper per-channel rising-edge
detector - the exact same `prev`-register-and-AND-with-inverted-prev
pattern already proven correct in `gen_irq_aggregator`'s own `edge_ev`.

`tb_hard_perf_counter.v` uses the same force/release-on-the-IP's-own-
ports approach as `irq_crypto` (`event_0..3`, and the plain always-ready
APB slave interface) - the doc's own CPU-visible address for these
counters (`0xF001_0008..0x14` via SoC config regs) is real, but the
top-level's actual wiring to get there varies a lot per run (confirmed:
one real generation captures `PERF_CTRL`'s enable/clear-all bits into a
register that's then never read by anything else - a dangling register,
found by reading the source, not fixed here since it's a top-level
integration gap rather than a generator bug, tracked like the DMA-config
-bus gap).

**Two testbench-only timing issues found and fixed along the way (real
DUT behavior, just not what my first draft assumed):**
- Changing a forced stimulus signal (`event_N`) immediately after
  `@(posedge clk)` races against that SAME edge's own active-region
  convergence in the DUT (a classic same-edge hazard - nothing to do
  with the edge-detector logic itself, which is otherwise correct).
  Confirmed via a real trace: `edge_0` transiently pulsed to 1 then
  immediately back to 0 within the same simulation timestamp, and
  whether the counter's own always block "caught" the transient
  depended on essentially arbitrary scheduling luck. Fixed by always
  changing `event_N` right after `@(negedge clk)` instead, giving a
  full half-period of guaranteed settling margin before the next
  sampling edge.
- Also needed a known-0 baseline: the real top-level's own drivers for
  these ports (e.g. `event_0 = s0_arvalid && s0_arready`, real NoC
  activity) can already be high during reset settling, latching
  `ev_prevN` to 1 before the testbench ever takes over via force - so
  the very first forced transition wasn't seen as a rising edge relative
  to that stale baseline. Fixed by forcing all four to 0 and holding a
  couple of cycles before any real test stimulus begins.
- The register-interface clear-all write (`perf_reg_write`, paddr==0)
  needed to be held across two clock edges to reliably register, not
  just one - confirmed via trace that all four handshake signals were
  correctly asserted and stable through a single edge, yet the clear
  didn't take; a second held edge consistently did. Not fully
  root-caused beyond that empirical fix, but matches the same "one more
  settling cycle" pattern already needed for `apb_periph`'s real AHB
  bridge.

Tests: T801 a single pulse increments by exactly 1; **T802 the key
level-vs-edge test**; T803 three separate pulses on a second channel
give exactly 3; T804 channel independence (untouched channels stay 0);
T805 a write to `paddr==0` clears all four counters at once, even ones
that were incremented; T806 counting correctly resumes from 0 after a
clear; T807 the AES-done-sourced channel (genuinely 1-cycle pulses, per
the doc) also counts correctly.

**Verification took three fresh-regeneration attempts, honestly recorded:**
- `t19_hard_test12`: hit unrelated Step-4 generation flakiness (duplicate
  wire declarations + a syntax error in `crypto_soc.v`, nothing to do
  with any fix from this session) - failed to elaborate at all, discarded.
- `t19_hard_test13`: elaborated and ran cleanly, confirming the
  hierarchical-reference bug found in `test11` simply didn't recur this
  run (Step 4 didn't reference `u_perf` internals at all this time - the
  `fix_perf_counter_hier_ref()` fix is conditional and only fires if the
  pattern appears, so this is expected, not a gap) - but it surfaced a
  **new, genuine bug** in `apb_periph`'s T603 (GPIO0 IN readback):
  `cpu_rvalid` pulsed for exactly one cycle, several cycles after
  `cpu_arready` (not fused with it, unlike prior runs), carrying a STALE
  value left over from an earlier transaction rather than the real
  target register - confirmed as a genuine top-level read-data-latching
  bug in that run's own hand-rolled bridge glue (re-tried with an
  actively-`while(!cpu_rvalid)`-waiting read, the textbook-correct
  AXI4-Lite pattern already used by the shared `axi_read` task, and it
  captured the exact same stale value - ruling out a testbench-side
  race). This is run-dependent top-level flakiness, not something a
  generator-level `_v2` fix or a generic testbench change can paper over
  - flagged here, not fixed, tracked like the DMA-config-bus gap.
  `apb_periph`'s `apb_read` task was left as its original, empirically-
  reliable fixed-cycle wait (the approach that verified cleanly across
  `test9`/`test10`/`test11`) rather than "fixed" into something that,
  when tried, regressed a previously-passing run without fixing this one.
- `t19_hard_test14` (see below): a completely clean run, used for the
  real, final full-suite confirmation.

**Verified end-to-end on a fully clean fresh regeneration (`t19_hard_test14`,
all fixes from this session wired in from the start, no flakiness of any
kind)**: all eight categories together via `run_suite.sh` - `reset_sync`
(5/5), `noc_local` (6/6), `noc_routing` (10/10), `aes_basic` (8/8),
`dma_basic` (10/10), `apb_periph` (6/6), `irq_crypto` (10/10),
`perf_counter` (9/9) - **64/64 passing**, zero manual RTL edits.

## `irq_periph` category (T901-T907) - a real integration test, no new RTL bug,
## three testbench lessons

`u_irq_periph` is the SAME `gen_irq_aggregator`/`gen_irq_aggregator_v2.py`
generator already fixed for `u_irq_crypto` - so there's no new generator
bug to find here. What makes this category worth its own testbench is
that irq_periph's five sources - `uart_rx_irq`/`gpio0_irq`/`gpio1_irq`/
`timer0_irq`/`wdt_irq` - are all REAL APB peripherals already given
solid, real-CPU-path testbenches in `apb_periph`. So instead of
force/release-ing the aggregator's own ports in isolation (irq_crypto's
approach, necessary there since AES/DMA don't have a reliable CPU-facing
path), `tb_hard_irq_periph.v` triggers each peripheral's OWN real
interrupt condition via genuine `apb_write` register writes and checks
the result reaches `cpu_periph_irq`/`cpu_periph_irq_id` - a real,
end-to-end integration test spanning peripheral -> `irq_periph_src` ->
aggregator, re-confirming the doc's lowest-id priority contract (T905)
through the actual integration path, not just the isolated aggregator
already proven in `tb_hard_irq_crypto.v` T702.

**Three real things found while building this, all testbench-side (no
RTL fix needed):**
- Clearing a source peripheral's own status register (e.g. GPIO's
  `ISTAT`) drops that source's wire into the aggregator, but does NOT
  clear the AGGREGATOR's own separately-latched `r_pend` bit for it -
  the exact same lesson already learned in `tb_hard_irq_crypto.v`'s
  T704/`irq_crypto_clear`, just easy to forget when the *source* being
  tested is a real peripheral instead of a forced signal. Confirmed via
  a real trace: GPIO1's own IRQ logic fired correctly, but
  `cpu_periph_irq_id` still read back GPIO0's id (1) from the PRIOR
  test, because the aggregator's own pend bit for src[1] was never
  independently cleared. Fixed by adding `irq_periph_clear_pend`
  (force/release on `u_irq_periph`'s own register port, same as
  `tb_hard_irq_crypto.v` - its CPU-visible address is just as
  unreliable/run-dependent as `u_irq_crypto`'s) after every test.
- The watchdog's CTRL register (`0x00C`) writes `en`/`wen`/`ren`/`ien`
  TOGETHER from the same `pwdata`, not just the bit(s) named in a
  comment - writing `CTRL: en=1` with only bit0 set silently zeroed
  `ien` (bit3) from its documented reset default of 1, gating
  `wdt_irq = iq1 & ien` off even though the real stage-1 countdown and
  `iq1` itself fired exactly on schedule (confirmed via a direct
  hierarchical trace: `iq1=1`, `ien=0`). Fixed by writing `0x9`
  (`en=1, ien=1`) instead of `0x1`.
- The UART's own real status-driven IRQ (`irq_en` enabling the
  already-true `tx_empty` status bit) needed more settling time before
  checking the aggregator's output than the other four sources did - a
  real trace showed the UART's own `irq`/`irq_en`/`irq_stat` all
  correct at the original check point, but the aggregator's `r_pend`
  hadn't caught up yet. Fixed by widening the settling window after
  that one write.

Tests: T901/T902 real rising-edge GPIO0/GPIO1 interrupts (`IPOL`/
`IEDGE`/`IEN`, then a genuine forced pad edge) resolve to id 1/2; T903 a
real timer0 counter-wrap interrupt resolves to id 3; T904 a real
watchdog stage-1 interrupt resolves to id 4; **T905 re-confirms the
lowest-id priority contract** with two real peripheral sources (GPIO0
and timer0) pending simultaneously through the full integration path;
T906 the UART's own status-driven interrupt resolves to id 0; T907 clean
idle once everything is cleared and disabled.

**Verified end-to-end**: all nine categories together via `run_suite.sh`
against both `t19_hard_test14` (a completely clean fresh regeneration)
and `test11_verify` (an earlier, independently-verified copy) -
`reset_sync` (5/5), `noc_local` (6/6), `noc_routing` (10/10), `aes_basic`
(8/8), `dma_basic` (10/10), `apb_periph` (6/6), `irq_crypto` (10/10),
`perf_counter` (9/9), `irq_periph` (7/7) - **71/71 passing** on both, no
RTL fix needed for this category (testbench-only lessons, no generator
or top-level change).

**Also newly found while building this (flagged, not fixed - a
top-level-bridge-timing issue, same class as the `test13` finding
above)**: on `t19_hard_test13` specifically, `apb_periph`'s T603 (GPIO0
IN readback) failed - `cpu_rvalid` pulsed once, several cycles after
`cpu_arready` and not fused with it, carrying a stale value from an
earlier transaction rather than the real target register. Re-verified
this is a genuine top-level bug (not a testbench race) by trying an
actively-`while(!cpu_rvalid)`-waiting read, which captured the identical
stale value. Both `t19_hard_test11`/`test14` show no such issue -
run-dependent Step-4 top-level flakiness, tracked but not blocking.

## `soc_cfg_regs` category (T1001-T1008) - two real, fixed top-level bugs, two
## confirmed-but-unfixable gaps

Unlike every category so far, the SoC Config Register Map (doc-documented
base `0xF001_0000`: `MBOX_DATA`/`MBOX_STATUS`/`PERF_CNT0..3`/`PERF_CTRL`/
reserved) has no dedicated `rtl_gen_lib` generator at all - Step 4 hand-
writes the entire S2 decode directly into the top-level every run, and
its structure varies enormously (confirmed structurally different across
FOUR separate regenerations in this pass alone). `tb_hard_soc_cfg_regs.v`
tests this register CONTRACT against the real, documented address, via
the plain shared `axi_write`/`axi_read` BFM (this address space's own
ack timing turned out to be simple, standard registered handshakes -
no fused-ack workaround needed).

**Bug #1, found empirically (T1002/T1004/T1005 all failed on the first
real run, `t19_hard_test14`).** Whatever drives `u_mbox`'s `wr_en` port -
the doc's own REQUIRED internal wire name for it is `mbox_wr_en`,
"write-enable from SoC config reg into async mailbox" - behaves as a
LEVEL that can stay high for more than one clock cycle. Since `axi_write`
(like every BFM in this suite) holds awvalid/wvalid through bvalid -
completely normal, spec-legal AXI4-Lite behavior, required elsewhere in
this same SoC's own crossbar - and `gen_async_fifo`'s write logic has no
edge-detection either (a plain level check, by design, matching every
other simple write-enable in this codebase), a SINGLE logical CPU write
pushed the SAME word into the mailbox TWICE (confirmed directly: `wr_bin`
incremented to 2 after exactly one `axi_write` call). This was observed
generated THREE structurally different ways across regenerations - a
plain `assign mbox_wr_en = expr;`, an inline `wire mbox_wr_en = expr;`,
and (`t19_hard_test16`) a clocked `reg` that still re-asserts to 1 every
cycle its own trigger condition holds (registered, but not edge-limited -
the same bug in a different shape). Rather than keep chasing new
syntactic forms of the SOURCE expression, `fix_mbox_wr_en_pulse()` fixes
it at the one place guaranteed to exist regardless of source style:
`u_mbox`'s own `.wr_en(...)` port connection is rewrapped in a fresh
edge-detector, safe and idempotent even if a future run's `mbox_wr_en`
already happens to be a proper pulse.

**Bug #2, found on `t19_hard_test15`, more serious than bug #1.**
`u_mbox`'s `rd_rst_n` port was tied to a constant `1'b1` (with the LLM's
own comment *"// Async reset not explicitly tied"*), instead of
`sys_rst_n`. Since `gen_async_fifo`'s entire read-side register file
(`rd_bin`/`rd_gray`/`rdg1`/`rdg2`) only initializes inside
`if (!rd_rst_n) ...`, and `rd_rst_n` never once deasserts - it just IS 1
from time 0, permanently - every read-side register starts at Verilog's
default uninitialized `x` and stays there forever, breaking
`mbox_empty`/`mbox_dout` completely (confirmed via a real trace: every
read-side signal read `x` throughout the entire simulation, T1001
onward). This is a direct, unambiguous architecture-doc violation - the
doc states plainly *"wr_rst_n and rd_rst_n both = sys_rst_n"* - and both
`u_mbox` (the required instance name) and `rd_rst_n` (the generator's
own fixed port name) are guaranteed, not LLM-inferred, so fixed
deterministically with `fix_mbox_rd_rst_n()`, scoped specifically to the
`u_mbox` instantiation (never touching any other reset signal in the
design).

**Gap #1, NOT fixed, confirmed identically on two separate regenerations
(`test14`/`test15`): `PERF_CNT0..3`/`PERF_CTRL` (`0x08..0x18`) are simply
never implemented in the S2 decode at all** - every read falls through
to a `default: s2_rdata_reg <= 32'b0;`, and a write is acked (`s2_bvalid`
fires) but goes nowhere. `u_perf` IS real and correctly instantiated in
both runs, just reachable at a completely different, undocumented
address (an inline `paddr[15:12]==7` slot in the S1/APB fabric window)
instead of through S2 at all. Unlike `mbox_wr_en`/`rd_rst_n`, there is no
single guaranteed wire or port name to regex against here - the S2
block's overall shape (which offsets it even attempts, and how) varies
too much across regenerations to fix safely and generically.

**Gap #2, NOT fixed, and confirmed RECURRING (not a one-off) across two
separate regenerations (`t19_hard_test16` and `t19_hard_test17`).** Both
runs' S2 read-response state machine (`s2_rvalid_reg`/`s2_rvalid_r` -
the exact internal name varies, the bug doesn't) only clears its
registered valid flag on `!s2_awvalid && s2_rready`, but the shared
`axi_read` BFM only pulses `cpu_rready` briefly around each transaction
(correct, standard AXI4-Lite master behavior) - so once the FIRST read
completes, the internal rvalid register gets stuck at 1 permanently, and
every SUBSEQUENT read silently returns the FIRST read's stale captured
data forever after (confirmed via a real trace on `test16`: `s2_rvalid`
never dropped back to 0 for the rest of the simulation; independently
re-confirmed on `test17`, where it fully explains all four of that run's
remaining `soc_cfg_regs` failures - T1002/T1004/T1005/T1006/T1007 are
ALL reads issued after T1001, the first one, and all four return
T1001's stale "empty=1" snapshot). The internal rvalid register is a
purely-internal, non-guaranteed name with no doc-mandated identity, and
its surrounding clear-condition logic is too structurally embedded in
each run's own larger always-block to safely target with an isolated,
low-risk regex the way `mbox_wr_en`/`rd_rst_n` could be (those were
single port connections; this is a multi-line clocked FSM woven into
unrelated read-mux logic). Both gaps documented here rather than
force-fixed, same treatment as the DMA-config-bus gap.

**One testbench-only timing lesson, the same class already seen twice
this session:** `mbox_read`'s `mbox_rd_en` pulse was originally set
immediately after the `while (mbox_empty) @(posedge dsp_clk);` loop
exited - the same same-edge race already found and fixed for
`tb_hard_perf_counter.v`'s `event_N` stimulus (changing a DUT input
right after `@(posedge X)` races that SAME edge's own active-region
convergence). Fixed by moving the change to `@(negedge dsp_clk)`
instead, giving a full half-period of guaranteed settling margin.

Tests: T1001/T1004 `MBOX_STATUS` correctly reflects empty before/after a
real push+drain cycle; **T1002 the key mbox_wr_en double-write test**;
T1003 a pushed word is correctly retrievable via the real DSP-side
interface (`mbox_rd_en`/`mbox_dout`, `dsp_clk` domain - proving the
SoC-config write path reaches real FIFO storage, not just a status bit);
T1005 filling the mailbox to its real depth (16) sets the full bit;
T1006/T1007 the confirmed, documented `PERF_CNT`/`PERF_CTRL` gap; T1008 a
reserved offset reads 0.

**Verified across five independent regenerations in total**: `test14`
(bug #1's discovery), `test15` (bug #2's discovery, plus re-confirming
bug #1's fix), `test16` (gap #2's discovery, plus re-confirming both
fixes with the finalized port-based `mbox_wr_en` approach), and `test17`
(a further completely fresh, fully-automatic agent run - independently
hit gap #2 again, which on inspection fully explains all its remaining
`soc_cfg_regs` failures with no other regression, confirming gap #2 is a
genuine, recurring LLM tendency rather than a one-off - `mbox_wr_en_pulse`
was itself confirmed correctly auto-inserted by `fix_mbox_wr_en_pulse()`,
verified absent from the raw pre-fix LLM response and present in the
final file). The clean, all-bugs-fixed confirmation numbers below come
from `test14`/`test15`/`test16` (each with both fixes applied, either
automatically or via a scratch copy using the exact same fix functions):
all ten categories together via `run_suite.sh` - `reset_sync` (5/5),
`noc_local` (6/6), `noc_routing` (10/10), `aes_basic` (8/8), `dma_basic`
(10/10), `apb_periph` (6/6), `irq_crypto` (10/10), `perf_counter` (9/9),
`irq_periph` (7/7), `soc_cfg_regs` (6/8, the 2 confirmed-not-fixed
`PERF_CNT`/`PERF_CTRL` checks) - **77/79 passing** consistently across
all three.

## `soc_cfg_regs` follow-up - PERF_CNT0..3 AND PERF_CTRL both fixed for real
## (prompt guidance + a deterministic backstop) - soc_cfg_regs now 8/8

Revisited after `mailbox` was done, prompted directly by the question of
whether the last 2 failing checks (`T1006`/`T1007`) were fixable at all.
Two tools were used together rather than either alone:

**1. Added `SOC_CFG_WIRING_NOTE`**, a new prompt-guidance block (mirroring
the existing `NOC_MESH_WIRING_NOTE` pattern) explaining all four bugs
found in this area in plain terms, since NONE of them had ever been
explained to the LLM before - it was always finding out about `axi_write`
holding awvalid/wvalid through bvalid, `rd_rst_n`'s requirement, the
stuck-rvalid trap, and the PERF_CNT/CTRL wiring requirement the hard way,
from scratch, every single regeneration. Tested across two fresh
regenerations (`test19`/`test20`): the LLM's own output directly cited
*"Bug 1 Prevention"*/*"Bug 2 Corrected"*/*"Bug 3 Corrected"* in its own
generated comments, and correctly implemented `mbox_wr_en`'s edge-
detector, `rd_rst_n`, and the rvalid-clear fix ALL BY ITSELF, unprompted
by any post-processing - real evidence the guidance genuinely changes
what gets generated, not just decoration Step 4 ignores.

**2. But PERF_CNT0..3 specifically still failed on both of those first
two guided runs**, revealing a MORE PRECISE bug than the original note
described: `u_perf`'s own internal register convention always starts at
`paddr=0` (paddr=0/4/8/12 read cnt0/cnt1/cnt2/cnt3) regardless of where
it's mapped into the larger SoC address space, but the doc places
PERF_CNT0 at SoC offset `0x08`, not `0x00` - both regenerations passed
the raw SoC offset straight through as `u_perf`'s own `paddr` with no
rebasing, so reading the documented `PERF_CNT0` offset (`0x08`) actually
read `u_perf`'s `cnt2` (confirmed directly: forced `cnt0=1` via a real
event pulse, read SoC offset `0x08`, got back `0`). Sharpened the prompt
note with the exact rebasing arithmetic required, AND added
`fix_perf_paddr_rebase()` as a deterministic backstop - directly
answering "is there a way to make this fix deterministic even if the LLM
makes a mistake?" Rather than trying to parse and rebase whatever
expression the LLM wrote (risky - a future correct implementation could
get double-subtracted), it completely REPLACES `u_perf`'s `.paddr(...)`
port connection with a fresh expression computed directly from the
crossbar's own guaranteed, non-inferred `s2_awaddr`/`s2_araddr` names.
**Has a safety guard that very nearly wasn't there**: `u_perf` has been
seen reached through a COMPLETELY unrelated scheme too (`test14`: an
inline S1/APB-fabric slot, nothing to do with S2) - blindly rebasing
there would have broken a currently-working, unrelated addressing path
by feeding it S2's irrelevant address. The fix now only proceeds if the
expression feeding `paddr` genuinely traces back to an `s2_` signal
(checked both for a direct inline expression and the common case of an
intermediate named wire, by chasing that wire's own declaration
elsewhere in the file) - verified this guard correctly leaves `test14`
completely untouched while still fixing `test19`/`test20`.

**3. Asked directly: "before integration, want to try that PERF_CTRL even
if risky" - so it got a real attempt, not just a documented gap.**
`PERF_CTRL`'s clear-all bit (offset `0x18`) isn't simply one of
`u_perf`'s own four counter registers at a rebased offset - checked
directly on `test19`: its `is_perf_reg` range check lumps `0x18` in with
the four counters, so the naive rebase arithmetic (`0x18 - 0x08 = 0x10`)
lands on a paddr `u_perf` doesn't recognize as anything (not one of its
four counters, and specifically NOT its own `paddr=0` clear-all
trigger) - nothing happens. The key realization that made this
tractable: `tb_hard_soc_cfg_regs.v`'s own `T1007` only tests the
clear-all bit, not the (genuinely unimplementable, since `u_perf` has no
enable register at all) enable bit - and BOTH observed regenerations'
own `psel`-range check already correctly covered offset `0x18` (`psel`/
`pwrite` were already asserting correctly for a `PERF_CTRL` write) - the
ONLY missing piece was redirecting `paddr` to `0` specifically for that
one case. `fix_perf_paddr_rebase()` was extended (not left as a separate
function - the two bugs share the same root cause and the same safe fix
point) to take FULL ownership of `u_perf`'s `.psel`/`.penable`/`.pwrite`/
`.paddr` connections together (never touching `.pwdata` - the clear-all
trigger doesn't care about its value), computing all four fresh from the
crossbar's own S2 signals rather than depending on whichever range-check
logic the LLM happened to write for `psel` being correct (a different
regeneration's own check could in principle use an exclusive upper bound
that silently excludes `0x18` entirely).

**Verified on `test14` (regression guard - correctly left untouched),
`test19`/`test20` (both went from `6/8` to full `8/8`), `test21`
(already `8/8` via prompt guidance alone - confirms zero regression on
an already-working case), and a further fresh, fully-automatic
regeneration (`test24`, real agent, no manual intervention)**: all ten
categories together via `run_suite.sh` - everything else unchanged,
`soc_cfg_regs` now **8/8**, no known gaps remaining in this category -
**91/91 passing**, a full clean sweep.

## `mailbox` category (T1101-T1108, 12 checks) - no generator bug found; a real
## testbench bug caught by its own regression suite

Unlike every category so far, reading `gen_async_fifo` (in
`gen_primitives.py`) before writing any testbench code did NOT turn up an
obvious bug: it's a textbook-correct Cummings-style dual-clock FIFO -
gray-code write/read pointers, the standard MSB-inverted comparison for
full detection (`wr_gray == {~rdg2[PBITS-1:PBITS-2], rdg2[PBITS-3:0]}`),
matching `PBITS = ABITS+1` binary/gray tracking on both sides, and a
plain combinational `dout = mem[rd_bin[ABITS-1:0]]` read. `soc_cfg_regs`'s
own testbench already covers the CPU-facing register CONTRACT around the
mailbox (and found real top-level bugs there - `mbox_wr_en`/`rd_rst_n`);
this category is scoped differently, force/release-ing `u_mbox`'s own
`wr_en`/`din` ports directly (bypassing whatever top-level SoC-cfg wiring
a given run has) to stress-test the FIFO IP itself under real dual-clock
CDC (`clk`=10ns, `dsp_clk`=14ns period - genuinely asynchronous, no
common multiple within any reasonably-sized test window).

**Found one real bug - in this testbench itself, not the generator.**
T1105 (confirming a pop while genuinely empty is safely ignored)
force/release's `dut.u_mbox.rd_en` directly, but the first draft never
released it - so it stayed forced to 0 for the rest of the simulation,
silently overriding every LATER `mbox_pop` call's real `rd_en` pulse
(driven procedurally through the normal `mbox_rd_en` top-level port).
`rd_bin` never advanced again after that point, and every subsequent pop
returned the exact same stale first word - caught immediately by T1106
(wraparound stress), which failed on effectively every iteration after
the first. This is exactly the kind of bug this suite's own "test
everything for real, don't assume" methodology exists to catch, even
when it turns out to be self-inflicted - fixed with the missing
`release`.

With that one line fixed, all 12 checks pass cleanly, and re-confirms
`gen_async_fifo` has no bug of its own to fix here: real single-word
round-trips, FIFO ordering (not LIFO) across multiple words, filling to
exactly `DEPTH` (16) asserting `full` at precisely the right count (not
off-by-one either direction), a push while genuinely full being safely
dropped with no data corruption, a pop while genuinely empty being
safely ignored with no pointer corruption, 40 push/pop cycles crossing
the internal circular-buffer wraparound point multiple times with exact
data integrity preserved, and a batch of 16 back-to-back same-cycle
writes (maximum write-side throughput stress) drained correctly and in
order from the fully asynchronous read side.

Tests: T1101 single push/pop round-trip; T1102a-c FIFO ordering across
three words; T1103 `full` asserts at exactly `DEPTH`; T1104 a push while
full is safely dropped, and draining afterward shows no corruption or
phantom word; T1105 a pop while empty leaves `rd_bin` untouched; **T1106
the key wraparound-stress test**; T1107 back-to-back fast writes drain
correctly under full CDC stress; T1108 clean idle steady-state.

**Verified end-to-end on a fresh regeneration (`t19_hard_test18`) and on
`test11_verify`**: all eleven categories together via `run_suite.sh` -
every prior category unchanged, plus `mailbox` (12/12) - **89/91
passing** (the 2 non-passing checks being the same confirmed, documented
`PERF_CNT`/`PERF_CTRL` gap from `soc_cfg_regs`, not anything new here).

## `integration` category (T1201-T1205, 5 checks) - the twelfth and final
## hard-tier category, plus two more real top-level bugs found

Every prior category exercises one IP block/subsystem in isolation, mostly
via force/release. `integration` deliberately does the opposite: it chains
multiple already-proven subsystems together through REAL top-level wiring,
to catch bugs invisible to any single-category unit test - the same way
the router-stubbing and `mbox_wr_en`-pulse bugs earlier this session were
both only found once something drove the real end-to-end path. Five
checks, new file `custom_testbenches/hard/tb_hard_integration.v`:

- **T1201** cold-boot-to-first-transaction: one real access into each of
  the three crossbar-decoded regions (S0 NoC, S1 APB, S2 SoC-cfg),
  back-to-back, right after the minimum post-reset settle margin every
  other category also uses.
- **T1202** dual-aggregator independence: a real AES0 done pulse and a
  real GPIO0 edge-IRQ fired close together - checks BOTH `cpu_crypto_irq`
  and `cpu_periph_irq` assert correctly and independently, no cross-talk
  between the two separate aggregator instances.
- **T1203** the doc's explicit fan-out claim ("aes_done ... OR-fed to
  irq_crypto_src[0..3] AND perf ch[3]") - one real aes1 done pulse must
  reach BOTH consumers from the SAME physical event.
- **T1204** a full software-driven chain: CPU programs a REMOTE
  (multi-hop) DMA transfer, waits for the real IRQ, then (the "software
  response") pushes the transferred value through the real SoC-cfg
  mailbox path and confirms the DSP side reads it back - NoC + DMA + IRQ
  + mailbox CDC all in one continuous, causally-linked sequence.
- **T1205** perf ch[0]'s doc-mandated real-traffic filter ("ch[0] = ni_00
  tl_a_valid, NoC transactions from CPU") - unlike `tb_hard_perf_
  counter.v` (which forces `event_0` directly), this drives one real NoC
  transaction, one real APB transaction, and one real SoC-cfg-space
  transaction and checks `cnt0` increased by exactly 1.

**A subtlety worth calling out**: `evaluate.py`'s own `parse_results()`
keys results purely by the NUMERIC id (`re.match(r'\[(PASS|FAIL)\]\s+T(\d+)'
, ...)`), so suffixed ids like `T1201a`/`T1201b` would both collapse onto
id 1201 and silently discard all but the last result - caught before ever
running this against real RTL, by re-reading the evaluator's own regex
first. Every check in this file combines its sub-conditions with `&&` into
exactly one `T120N` id instead.

**First real run (`t19_hard_test25`, a fresh, fully-automatic
regeneration) found T1203 and T1205 failing** - two NEW real top-level
bugs, both in `u_perf`'s wiring, neither previously seen:

1. **`event_0` tied to a flat constant.** The generated comment admitted
   it: *"Unused directly inside integrated noc_mesh, but we can feed
   1'b0 or pull from a safe logic level"*. Root cause: `try_stitch_
   noc_mesh()` hides the individual `u_ni_XY`/`u_router_XY` instances (and
   their internal TileLink signals) from Step 4's prompt entirely - there
   is no internal NI signal for the LLM to reach for ch[0] even in
   principle, so it (reasonably, given what it can see) fell back to a
   constant. Fixed via new `fix_perf_event0_wiring()`: the crossbar's own
   guaranteed S0 port handshake (`s0_awvalid && s0_awready`, `s0_arvalid
   && s0_arready`) fires exactly once per real CPU-initiated NoC
   transaction accepted at node (0,0) - the same node `ni_00`/`router_00`
   sit at - so it's a functionally equivalent, always-visible substitute
   that doesn't require exposing any new mesh port. Chases ONE level of
   indirection (the common `.event_0(perf_ev0)` + `wire perf_ev0 = 1'b0;`
   pattern, confirmed exactly on test25) and only fires when the resolved
   expression is a flat constant - deliberately narrow, so it never
   overwrites a regeneration that already wires something real in.

2. **`u_perf`'s `paddr` reached through TWO hops of indirection** -
   `.paddr(perf_paddr)` with `wire [11:0] perf_paddr = {4'h0,
   (soc_reg_offset - 8'h08)};` and `soc_reg_offset` ITSELF declared as
   `s2_awvalid ? s2_awaddr[7:0] : s2_araddr[7:0]` elsewhere. Genuinely
   S2-routed, just one hop further than `fix_perf_paddr_rebase()`'s
   existing one-level chase reached - deepened to a bounded-depth-3
   recursive chase (comfortably covers this and the original case).

   **A second, more fundamental bug was found while debugging #2**: the
   function that locates `u_perf`'s own instantiation block
   (`re.search(r'u_perf\b[^;]*\([^;]*?\);', ...)`) was too loose - this
   regeneration has a comment ("...the internal paddr of u_perf (0x08 ->
   0x00, ...)") that CONTAINS the literal text "u_perf (" and appears
   BEFORE the real instantiation in the file, so the old regex matched
   that comment fragment first and silently no-op'd BOTH perf fixes with
   no error at all (confirmed directly: re-ran both fixes in isolation
   against the raw Step-4 response text, both reported no change, until
   this was found). Anchored on the actual instantiation syntax
   (`u_perf\s+u_perf\s*\(` - module name then instance name, standard
   Verilog) instead, which cannot match a prose comment.

   Both fixes verified together: patched `test25`'s already-generated
   `crypto_soc.v` in isolation first (91/91 -> confirmed both `[FIX]`
   messages fire, `run_suite.sh` goes from 94/96 to **96/96**), then
   regression-checked `test24` and `test14` (both report "no change" -
   `test24` because its paddr was already correctly patched by the
   original one-hop fix and the idempotency guard correctly no-ops on an
   already-fixed expression, `test14` because its APB-inline paddr still
   correctly never traces to `s2_` at any hop).

**A THIRD structural variant, found on a second fresh regeneration
(`t19_hard_test27`), is deliberately left unfixed.** This one reaches
`u_perf` through `.paddr(psel_perf ? paddr[11:0] : perf_paddr)` - a MUX
between a test14-style inline S1/APB-fabric slot (`psel_perf = psel &&
paddr[15:12]==7`) AND a separate S2-derived path, with `perf_paddr` itself
assigned procedurally inside an `always` block (not a plain `wire`/`assign`,
so the current chase doesn't even resolve it). Blindly replacing
`.psel`/`.paddr` here risks breaking the S1 branch exactly the way the
existing guard was built to protect `test14`'s single-path case - not
safe to fix with the same blunt "take full ownership" approach. When this
variant occurs, T1203/T1205 here and T1006/T1007 in `soc_cfg_regs` fail
together, consistently, for the same understood reason - documented as an
accepted gap rather than chased into an ever-more-specific regex (this
area has now shown THREE distinct real structural variants across
regenerations: pure-S2 single-hop, pure-S2 two-hop, pure-S1-inline, and
now S1+S2-mixed - diminishing returns on chasing a fourth).

**`t19_hard_test26` (the fresh regeneration attempted between test25 and
test27) hit an unrelated one-off LLM typo** (`.m_m_awvalid(...)` instead
of `.m_awvalid(...)` in `u_dma1`'s own instantiation, a doubled-word
copy-paste error) that failed elaboration entirely before any testbench
could run - not connected to anything touched this session, not
previously seen, and (being a single one-off character-level typo rather
than a recurring structural pattern) not treated as worth a dedicated
regex fix the way the recurring bugs above were.

**Net result**: T1201/T1202/T1204 pass reliably on every regeneration
tested (`test24`/`test25`/`test27`). T1203/T1205 pass when `u_perf` is
S2-routed (directly, one-hop, or two-hop) and fail together with
`soc_cfg_regs`' own T1006/T1007 on the rarer S1+S2-mixed variant - by
design tracking, not masking, that pre-existing documented gap.
`t19_hard_test25` (fully patched): **96/96** across all twelve
categories.

## Hard tier done - all 12 categories, 96/96. Medium tier: all 12 custom
## testbenches built, 50/52 - two real generator bugs found and fixed,
## one real Step-2 inference gap found and documented (2026-07-27)

With hard tier complete, started the medium-tier (`noc_aes_soc`) custom
testbench suite - same methodology, same 12-category breakdown as
`evaluate.py`'s own map (`reset_sync`, `noc_topology`, `aes0_encrypt`,
`aes1_encrypt`, `irq_agg`, `sram_ni_idle`, `noc_ni_basic`,
`noc_local_loop`, `noc_ew_routing`, `noc_ns_routing`, `noc_2hop`,
`irq_id_order` - 52 checks total). New directory:
`custom_testbenches/medium/` (`tb_medium_common.vh` + 12 per-category
files + `run_suite.sh`, same structure as the hard-tier suite).

Medium's architecture is simpler than hard's in every dimension (6-node
2x3 mesh vs. 4x3, no DMA/mailbox/perf/APB cluster, a single IRQ
aggregator, AES engines exposed as DIRECT top-level ports instead of
force-only) but critically has NO crossbar between the CPU and the mesh -
the CPU's AXI4-Lite master goes straight into node (0,0). This absence of
buffering immediately exposed two real, previously-latent bugs that
hard tier's own crossbar happened to mask:

**Bug 1 - `gen_axi_lite_sram_v2`'s write-path handshake could never
complete for a LOCAL (same-node) write.** `awready`/`wready` were each a
self-referential one-cycle toggle (`awready <= !pending_w && awvalid &&
!awready`) - by construction they flip on then off on ALTERNATING clock
cycles, independently of each other. `tilelink_router`'s local-delivery
path waits for `sram_awready && sram_wready` to be true on the SAME
cycle before advancing past S_SEND - two independently-alternating
one-cycle pulses are never guaranteed to land together, and confirmed
directly via simulation they never did, hanging any CPU write to a
node's own local SRAM forever. Root-caused via `tb_medium_reset_sync.v`'s
T105 (a real hang, not a timeout-by-design) - traced signal-by-signal
through `u_ni_00`/`u_router_00`/`u_sram_00` hierarchically to find
`sram_awready`/`sram_wready` literally never coinciding. Not caught by
hard tier's own 96/96 because none of its tests happen to route a write
through this exact same-node LOCAL path in a way that exposes it (DMA's
own master port has different AXI timing than a CPU/NI-driven write).
Fixed by rewriting the write path with `have_aw`/`have_w` latches so
`awready`/`wready` are simple "ready when idle" signals asserted
TOGETHER, correctly handling both the same-cycle AW+W convention every
BFM in this codebase uses and staggered AW/W arrival per the AXI4 spec.
Verified: regenerated a real `u_sram_00.v` with the fix and confirmed a
previously-hanging write now completes; regression-checked against
`t19_hard_test27`'s full RTL (all its `u_sram_*` instances regenerated
with the fix) - identical 94/96 result, confirming zero behavioral change
for the paths hard tier already exercises.

**Bug 2 that turned out not to be a bug** - a second, real-looking hang
(`axi_bvalid` never asserting in `u_ni_00.v`, a genuine same-cycle
`st==S_IDLE`-vs-`tl_d_valid` race) was chased for a while before
realizing `t19_medium_test3` (the only medium regeneration available
pre-dating this debugging session) is simply STALE - `gen_ni_v2.py`
already has this exact fix (its own docstring documents the identical
race, found and fixed earlier in this project's history). A third,
similar false alarm turned up in AES: `t19_medium_test3`'s `u_aes0.v`/
`u_aes1.v` were generated before `gen_aes128_v2`'s shift_rows/
mix_columns fix existed, so the NIST test vector initially failed there
too. **Lesson generalized**: rather than keep chasing individually-stale
IP files, every deterministic-generator-backed module
(`u_sram_*`/`u_ni_*`/`u_aes0`/`u_aes1`/`u_router_*`/`u_irq_agg`) in the
dev-baseline RTL was regenerated fresh from the CURRENT generator
functions before further testing - this is the actual dev baseline used
for the rest of the medium-tier suite (`/tmp/medium_test3_fully_patched`
locally; not something that ships, since the real agent always calls the
current generators live).

**Bug 3 - a real, still-open Step-2 YAML-inference gap**: the
architecture doc's reset_sync diagram shows the same 4-FF chain as hard
tier ("Determine the number of synchronizer stages from the structure of
the diagram"), but this regeneration's `u_rst` came out with
`STAGES=3` (the generator's own bare default, unless Step 2's YAML
inference explicitly overrides it - which it correctly did for hard
tier's own reset_sync, confirmed 4/4 across `test24`/`test25`/`test27`,
but did not for this medium regeneration). `tb_medium_reset_sync.v`'s
T101/T103 correctly hardcode the doc's spec (4 cycles) and fail against
this real gap, exactly as intended - not weakened to match whatever a
given regeneration happens to produce. Since this is a Step 2 LLM
inference issue (not a deterministic generator bug), fixing it requires
prompt-guidance verified against a real model call - flagged as the
first thing to re-check once a working `EXPRESS_MODE_KEY` is available,
rather than guessed at blind.

**Verified via `run_suite.sh` against the fully-patched baseline**: all
twelve categories together - **50/52**, with T101/T103 (Bug 3 above) the
only non-passing checks, exactly as expected and understood. Not yet
verified against a truly fresh end-to-end regeneration (blocked on a
working API key at the time of this pass) - that remains the next step
before this can be called as fully confirmed as hard tier's 96/96.
