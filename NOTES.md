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
