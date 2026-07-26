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
