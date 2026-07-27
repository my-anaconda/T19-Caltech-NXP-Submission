# T19 (Caltech) — NXP ICLAD 2026 Submission

Final agent for the NXP SoC Design Benchmark (`ICLAD26-NXP-Problems`) -
covers all three tiers (`easy`/`medium`/`hard`) via the same agent and the
`--problem` flag. This folder is self-contained: it does not require placing
anything inside the official hackathon repo. See `NOTES.md` for the full
design rationale, the medium/hard extension work, and comparison against
T19's 18 prior agent iterations.

## Layout

```
T19-Caltech-NXP-Submission/
├── agent/
│   └── t19_nxp_agent_final.py   ← the submission agent
├── scripts/
│   └── model_service.py         ← local Gemini Developer API proxy, for testing
├── custom_testbenches/
│   └── hard/                    ← self-authored hard-tier testbench suite (see below)
├── requirements.txt
├── NOTES.md                     ← design rationale / version comparison
└── README.md                    ← this file
```

## Prerequisites

0. Clone this repo, and clone the official problem repo (it provides
   `runner/run_benchmark.py`, `evaluator/evaluate.py`, `rtl_gen_lib/`, and the
   problem specs/testbenches - none of that is duplicated here):
   ```bash
   git clone https://github.com/my-anaconda/T19-Caltech-NXP-Submission.git
   git clone https://github.com/ICLAD-Hackathon/ICLAD26-NXP-Problems.git
   ```
   (`ICLAD26-NXP-Problems` is also reachable as a submodule of the top-level
   `ICLAD-Hackathon-2026` repo, at `problem-categories/ICLAD26-NXP-Problems`,
   if you're setting up the whole hackathon rather than just this problem.)
1. Python 3.8+, `iverilog`/`vvp` 10.0+ (see that repo's `DEPENDENCIES.md`).
2. `pip install -r requirements.txt` (just `google-genai`, needed by
   `scripts/model_service.py`).
3. A Gemini API key (from [ai.studio](https://ai.studio) - the frictionless
   GCP hackathon account gives a billing-enabled project with much higher
   quota than the free-tier Vertex AI Express Mode this used previously):
   ```bash
   export EXPRESS_MODE_KEY="your_actual_api_key_here"
   ```
   (The env var name `EXPRESS_MODE_KEY` is kept for compatibility with
   existing scripts, but `model_service.py`'s client now runs in plain
   Gemini Developer API mode, not Vertex AI Express Mode - see below.)

## Running

**Terminal 1** - start the local model service (implements the exact
`model_endpoint` contract from `AGENT_GUIDE.md`):

```bash
cd T19-Caltech-NXP-Submission
python3 scripts/model_service.py --port 8080
```

**Terminal 2** - run the official benchmark runner, pointing `--agent` at
this folder's agent and `--model-endpoint` at the service above:

```bash
cd <path-to>/ICLAD26-NXP-Problems
python3 runner/run_benchmark.py \
    --problem easy \
    --agent <path-to>/T19-Caltech-NXP-Submission/agent/t19_nxp_agent_final.py \
    --model gemini-3.5-flash \
    --model-endpoint http://127.0.0.1:8080 \
    --run-id t19_final_v1
```

Note: model name depends on which key is behind `EXPRESS_MODE_KEY`. With a
Gemini API key from a new/frictionless-hackathon GCP project (billing
enabled, higher quota - see `NOTES.md`), older names like `gemini-2.5-flash`
and `gemini-2.0-flash-exp` (the default baked into `run_benchmark.py`/
`AGENT_GUIDE.md`'s examples) return 404 "no longer available to new users" -
`gemini-3.5-flash` is confirmed working and is the only current-generation
name that still honors `thinking_config`/`thinking_budget=0`. Use whichever
model name is actually enabled for your key via `--model` as shown above.

This writes generated RTL to `ICLAD26-NXP-Problems/result/t19_final_v1/easy/`
and (since `--skip-eval` isn't passed) immediately runs the evaluator too.

### Evaluating separately

```bash
python3 evaluator/evaluate.py \
    --problem easy \
    --rtl_dir result/t19_final_v1/easy/ \
    --run_id  t19_final_v1

cat factors/t19_final_v1/easy/easy_score.json
```

**Important limitation**: the golden testbench (`problems/easy/golden_tb/`)
is intentionally hidden from participants, so this local evaluation step will
always report `"Golden TB not found"` / `score: 0.0` — that is expected and
is not a sign anything is broken. Local runs can only confirm two things pre-
submission:

1. **Generation completeness** - check that `result/t19_final_v1/easy/`
   contains all 9 expected files (8 IP `.v` files + `secure_periph_soc.v`).
2. **Syntactic validity and elaboration** - compile with the DUT itself as
   the elaboration root (`-s secure_periph_soc`). Note:
   `problems/easy/tb/tb_top_skeleton.v` is a port-contract *reference*, not a
   runnable testbench - it declares some DUT-input signals as `wire` while
   its own `initial` block procedurally assigns them (e.g. `uart_rx`,
   `uart_cts_n`), which is invalid Verilog and fails elaboration regardless
   of what RTL is submitted, so don't compile against it directly:
   ```bash
   cd ICLAD26-NXP-Problems
   iverilog -g2005 -o /tmp/smoke_test -s secure_periph_soc result/t19_final_v1/easy/*.v
   ```
   A clean exit confirms our modules parse, elaborate, and connect correctly
   as Verilog-2001 (`iverilog -g2005`-compatible) - confirmed via a real
   end-to-end run with `gemini-2.5-flash` during development: all 8 IP files
   + top-level generated correctly and this check passed with exit code 0.

Real correctness/efficiency scoring only happens against the hidden golden
testbench at organizer judging time.

## Gemini "thinking" gotcha (already handled in `scripts/model_service.py`)

Gemini 2.5 and 3.5 models (confirmed on both) spend part of `max_output_tokens`
on an internal "thinking" step before producing visible text. With a modest
token budget, thinking alone can exhaust it - `finish_reason` comes back
`MAX_TOKENS` with only a truncated fragment of real output (hit and fixed
during development). `model_service.py` sets
`thinking_config=ThinkingConfig(thinking_budget=0)` to disable this for this
structured-generation task, which is also cheaper and faster. Note: not every
model name honors this - "lite"/"latest"-alias model names
(`gemini-3.5-flash-lite`, `gemini-flash-latest`, etc.) rejected the explicit
`thinking_config` outright with a 400 error during testing; `gemini-3.5-flash`
accepts it. Keep this in mind if you swap in a different model server/config.

## `custom_testbenches/` — self-authored hard-tier verification suite

The `hard` tier's golden testbench is not released to participants (same as
`easy`/`medium`, see the limitation noted above), so local runs normally
can't confirm anything beyond elaboration. To get real functional coverage
before submission, this repo includes a from-scratch testbench suite —
`custom_testbenches/hard/` — that exercises every hard-tier IP category
against *actual iverilog/vvp simulation*, not just compilation:

```
custom_testbenches/hard/
├── run_suite.sh              ← driver: runs all 11 testbenches against one RTL output dir
├── tb_hard_common.vh         ← shared clock/reset/timeout/scoreboard macros
├── tb_hard_reset_sync.v
├── tb_hard_noc_local.v
├── tb_hard_noc_routing.v
├── tb_hard_aes_basic.v
├── tb_hard_dma_basic.v
├── tb_hard_apb_periph.v
├── tb_hard_irq_crypto.v
├── tb_hard_perf_counter.v
├── tb_hard_irq_periph.v
├── tb_hard_soc_cfg_regs.v
└── tb_hard_mailbox.v
```

Usage, once you have a generated `hard`-tier RTL output directory (e.g. from
the `Running` steps above with `--problem hard`):

```bash
custom_testbenches/hard/run_suite.sh <path-to>/ICLAD26-NXP-Problems/result/<run_id>/hard
```

Each testbench targets one IP category end-to-end (reset/clock-domain
synchronization, NoC local/routing, AES, DMA, APB peripherals, crypto IRQs,
performance counters, peripheral IRQs, SoC config-space registers, and the
mailbox) and reports `[PASS]`/`[FAIL]` per check. This suite is how the real
bugs described in `NOTES.md` were actually found — in both the organizer's
own RTL generators and the Step-4 LLM-generated top-level SoC integration —
each one root-caused against a real simulation failure and fixed, then
reverified with a completely fresh, unpatched regeneration. Current status:
**91/91 checks passing** across all eleven hard-tier categories on a fresh
regeneration. See `NOTES.md` for the category-by-category bug writeups.

## What's different from the starter/reference agents

See `NOTES.md` for the full rationale. In short: this agent uses the same
`model_endpoint` HTTP interface as `vertexai_express_agent.py` (mandatory per
`AGENT_GUIDE.md` - direct SDK calls, which every one of T19's own prior
versions used, are a contract violation), combined with the most reliable
prompt-engineering ideas from T19's own iteration history (directed-graph
topology extraction from the architecture diagram's SVG, and a hand-curated
per-IP-type YAML schema).
