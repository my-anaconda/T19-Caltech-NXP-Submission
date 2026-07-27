#!/usr/bin/env python3
"""
T19 (Caltech) — NXP ICLAD 2026 SoC Design Benchmark Agent
===========================================================
Final submission agent. Synthesizes the best pieces of T19's own v2-v19
iteration history (see NOTES.md for the full comparison) on top of the
organizer-provided vertexai_express_agent.py reference:

  - Architecture parsing + directed-graph topology extraction: from v16/v19
    (parses the architecture.html's SVG <g class="node/edge"> elements into an
    explicit NODES/EDGES topology, which is far more reliable than asking the
    model to infer wiring purely from prose).
  - Strict per-IP-type YAML constraint schema: from v19 (hand-curated
    IP_CONSTRAINTS dict, more complete/reliable than v16's regex-scraped
    "required(spec, ...)" schema extraction).
  - Single combined YAML-inference call (not v18/v19's per-section sequential
    calling): v16's single-call design was the last version with a fully
    verified, complete local run; v18's per-section approach empirically
    produced partial output (timeout/rate-limit exhaustion from ~9 sequential
    calls with cooldowns), so that regression is NOT carried forward here.
  - Model access: v2 through v19 all called Google's genai SDK directly using
    EXPRESS_MODE_KEY, which violates AGENT_GUIDE.md's explicit contract
    ("Send ALL model calls to the model_endpoint... ALL LLM calls go here").
    This agent instead POSTs to info["model_endpoint"] exactly like
    vertexai_express_agent.py's call_model(), so token usage is correctly
    logged by the benchmark's own model service and the run is contract-valid.

Usage (via the benchmark runner):
  python3 runner/run_benchmark.py --problem easy \\
      --agent /path/to/T19-Caltech-NXP-Submission/agent/t19_nxp_agent_final.py \\
      --model gemini-2.0-flash-exp --run-id t19_final_v1
"""

import argparse
import json
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from contextlib import contextmanager
from pathlib import Path

RETRYABLE_HTTP_STATUS = {429, 500, 502, 503, 504}

# Two fixes to the organizer-provided rtl_gen_lib, both verified via real
# simulation (see NOTES.md) rather than elaboration alone:
#
# 1. gen_router_v2.py: the original tilelink_router generator has a
#    structural bug - every compass port is generated with a fixed direction
#    (A-channel input only), so no two router instances can ever forward a
#    packet to each other. gen_router_v2.py fixes this with bidirectional
#    per-port channels (proven via real 1-hop and 2-hop simulation).
#
# 2. gen_noc_mesh.py: even with a correct router IP, empirically the
#    top-level-generation LLM call does NOT attempt real per-node mesh
#    wiring - for a 4x3 (12-router) mesh it silently instantiated every
#    router with ONLY clk/rst_n connected, leaving everything else
#    floating (Icarus does not flag unconnected named ports, so this
#    "elaborated cleanly" while doing nothing). This happened identically
#    for both router versions, so it's a separate, pre-existing gap: the
#    mesh interconnect is fully mechanical once the grid dimensions are
#    known, so it's generated programmatically instead of asked of the LLM.
#    The result is ONE self-contained "noc_mesh" module whose only external
#    ports are one AXI4-Lite slave port per node - the LLM's job shrinks to
#    "instantiate this one module and connect a handful of AXI-Lite ports",
#    which is the same kind of task it already handles correctly elsewhere
#    (e.g. DMA cfg ports), instead of hand-wiring 12 routers.
NOC_MESH_WIRING_NOTE = """
IMPORTANT - the NoC mesh (all tilelink_router / tilelink_ni / axi_lite_sram
instances) has ALREADY been fully wired into ONE module called "noc_mesh"
(see its header below). Do NOT instantiate u_router_*/u_ni_*/u_sram_*
individually - instantiate ONLY the noc_mesh module. Its external ports are
one AXI4-Lite SLAVE port per node, named n{{X}}{{Y}}_* (e.g. n00_awaddr,
n01_awvalid, ...) where X,Y are that node's mesh coordinates. Per the
architecture doc's own node/injection-point assignments: connect the
node(s) where the CPU and/or DMA engines inject traffic into the mesh to
their corresponding n{{X}}{{Y}}_* port (CPU's crossbar NoC-space output and
each DMA engine's AXI4-Lite master port are AXI4-Lite masters; noc_mesh's
n{{X}}{{Y}}_* ports are AXI4-Lite slaves, so this is a direct master-to-slave
connection). Every node's n{{X}}{{Y}}_* port that has no real external master
driving it must be tied idle exactly like any other unused AXI4-Lite slave
port in this design (awvalid=0, wvalid=0, arvalid=0, bready=1'b1,
rready=1'b1). Name this instance EXACTLY "u_noc_mesh" (i.e. write
`noc_mesh u_noc_mesh ( ... );`, not e.g. `noc_mesh noc_mesh ( ... );`) -
custom testbenches probe into this instance by that fixed hierarchical
path, so an inconsistent instance name breaks them even though the RTL
itself is otherwise correct.
"""

SOC_CFG_WIRING_NOTE = """
IMPORTANT - SoC Configuration Register space (crossbar's S2 window,
MBOX_DATA/MBOX_STATUS/PERF_CNT0-3/PERF_CTRL) correctness. These four
specific bugs were each found via real simulation across multiple
regenerations of this exact design - not hypothetical, all confirmed:
1. The mailbox FIFO's wr_en input must be driven by a genuine
   SINGLE-CYCLE PULSE, never a raw combinational level like
   "s2_awvalid && s2_wvalid && (addr==MBOX_DATA)". A real CPU AXI4-Lite
   master is completely free to hold awvalid/wvalid asserted for MORE
   than one clock cycle (normal, spec-legal behavior) - the FIFO itself
   has no edge-detection on wr_en and will silently write the SAME word
   into the FIFO once per cycle for as long as wr_en stays high. Add an
   explicit registered edge-detector (a 1-cycle-delayed copy of the
   write-trigger condition, ANDed with its own logical inverse) between
   that condition and the FIFO's actual wr_en port.
2. The mailbox FIFO's rd_rst_n port (its independent DSP-clock-domain
   reset) MUST be tied to sys_rst_n, exactly like wr_rst_n - never tie
   it to a constant such as 1'b1. If rd_rst_n never actually asserts,
   every read-side register (read pointer, synchronized gray-code
   pointers) stays at its default uninitialized value forever,
   permanently breaking the mailbox's entire DSP-side read interface -
   this is NOT a "leave it disconnected for now" situation.
3. Any registered read-response valid flag for this slave port (its own
   rvalid output) must reliably return to 0 once the CPU master has
   consumed the response. A common but WRONG pattern is clearing it only
   when "(!arvalid && rready)" - a real master may only pulse rready
   briefly around when it first observes rvalid, not hold it through a
   later cycle where arvalid also happens to have already dropped, so
   this condition can be missed entirely and the valid flag gets stuck
   at 1 forever, causing every SUBSEQUENT read to silently return stale
   data from the very first read. Instead, clear it unconditionally on
   the same cycle rready is observed high while the flag is already set
   (i.e. "if (rvalid_reg && rready) rvalid_reg <= 0;" as its own
   independent clearing path, evaluated regardless of arvalid's current
   state that cycle).
4. PERF_CNT0/1/2/3 and PERF_CTRL (whatever SoC config offsets the
   architecture doc assigns them) must be REAL, functional connections
   to the perf_counter IP's own APB-style register interface (its own
   internal address convention is FIXED and NOT the same as the SoC
   config offsets: its own paddr=0/4/8/12 read cnt0/cnt1/cnt2/cnt3
   respectively, and a write to its own paddr=0 clears all four) - do
   not leave these as a stub that always returns 0 or accepts writes
   that go nowhere. Drive the perf_counter instance's own psel/penable/
   pwrite/paddr/pwdata whenever the SoC config address decodes into this
   range, and return ITS real prdata output, not a locally tracked
   placeholder value. CRITICAL: the SoC config offset for PERF_CNT0 is
   almost certainly NOT 0x00 (e.g. the doc may assign PERF_CNT0 to SoC
   offset 0x08) - you MUST REBASE the address before driving
   perf_counter's own paddr port (perf_paddr = soc_offset - <the SoC
   offset where PERF_CNT0 itself lives>, NOT the raw soc_offset passed
   through unmodified), or you will read/write the WRONG counter (e.g.
   passing SoC offset 0x08 straight through as perf_counter's own
   paddr=0x08 actually hits ITS cnt2, not cnt0, since perf_counter's own
   addressing always starts at 0 regardless of where it's mapped into
   the larger SoC address space). Double-check this arithmetic against
   the doc's own explicit PERF_CNT0..3/PERF_CTRL offset table before
   finalizing.
"""

# ---------------------------------------------------------------------------
# Strict per-IP-type YAML schema (from t19_nxp_agent_v19.py - hand-curated,
# more complete/reliable than scraping required() calls out of gen_*.py source)
# ---------------------------------------------------------------------------
IP_CONSTRAINTS = """
# APB IPs
- ahb_to_apb_bridge: Requires [name]
- apb_uart: Requires [name, fifo_depth, default_div]
- apb_gpio: Requires [name, gpio_width, debounce_sync]
- apb_timer: Requires [name, channels, width]
- apb_watchdog: Requires [name]
- irq_aggregator: Requires [name]
- apb_fabric: Requires [name, timeout_cyc, address_map]. 'address_map' must be a list of dictionaries with keys: slave, name, base_addr, range, privilege.

# AXI IPs
- axi_lite_sram: Requires [name, depth, data_width, addr_width]
- dma_engine: Requires [name, burst_len]
- axi_lite_crossbar: Requires [name]. Optional: [slave_ranges] - a list of
  exactly 3 dicts (one per slave S0/S1/S2, IN ORDER), each with keys 'base'
  and 'size' (both integers, hex-string like "0xF0010000" is also accepted).
  A slave's decode hits when (addr & ~(size-1)) == base - so 'size' MUST be
  a power of 2 and 'base' MUST be aligned to it (base % size == 0).
  THIS FIELD IS CRITICAL: if omitted, the generator silently defaults to
  base=0x00000000/0x00010000/0x00020000 with size=0x10000 each - a generic
  placeholder address map that will NOT match this architecture's real one
  (found via an actual failed CPU transaction in a custom testbench, not
  just elaboration: a write to the documented SoC-cfg address hung forever
  because nothing decoded to it). ALWAYS derive the real base/size values
  for S0/S1/S2 from the architecture doc's own address map table/diagram.
  Worked example matching a real architecture doc that said "S1 (APB):
  0xF000_0000-0xF000_FFFF", "S2 (SoC cfg): 0xF001_0000-0xF001_FFFF",
  everything else routes to S0 (NoC):
    slave_ranges:
      - {base: 0x00000000, size: 0x80000000}   # S0: top address bit = 0,
                                                 # covers every valid NoC
                                                 # destination address
                                                 # without overlapping S1/S2
      - {base: 0xF0000000, size: 0x00010000}    # S1: exactly 0xF000_xxxx
      - {base: 0xF0010000, size: 0x00010000}    # S2: exactly 0xF001_xxxx
  Generalize this pattern (S0 = the largest power-of-2-aligned window that
  excludes S1/S2's addresses; S1/S2 = their documented small windows) to
  whatever base addresses THIS architecture doc actually specifies - do not
  reuse these exact numbers if the doc's addresses differ.

# NoC/Security IPs
- tilelink_router: Requires [name, node_x, node_y, data_width, addr_width]. Optional: [num_ports]
- tilelink_ni: Requires [name]
- aes128: Requires [name, pipeline_stages]

# Primitive IPs
- sync_fifo: Requires [name, depth, data_width]. Optional: [fwft, almost_full_thresh, almost_empty_thresh]
- async_fifo: Requires [name, depth, data_width]
- sram_sp: Requires [name, depth, data_width]
- sram_dp: Requires [name, depth, data_width]
- reset_sync: Requires [name, stages]
- cdc_sync: Requires [name, data_width]. Optional: [kind]
- perf_counter: Requires [name, channels, counter_width]
"""

# Per-problem IP-block checklists (per AGENT_GUIDE.md / README.md's "IP Blocks"
# lists for each tier). Used only to sanity-log what's missing after YAML
# inference - does not force generation. "medium"/"hard" list the ip_type
# names (some instantiated multiple times under different `name`s).
EXPECTED_IPS_BY_PROBLEM = {
    "easy": [
        "reset_sync", "ahb_to_apb_bridge", "apb_fabric", "apb_uart",
        "apb_gpio", "apb_timer", "apb_watchdog", "irq_aggregator",
    ],
    "medium": [
        "reset_sync", "tilelink_router", "tilelink_ni", "axi_lite_sram",
        "aes128", "irq_aggregator",
    ],
    "hard": [
        "reset_sync", "tilelink_router", "tilelink_ni", "axi_lite_sram",
        "axi_lite_crossbar", "aes128", "dma_engine", "apb_fabric",
        "apb_gpio", "apb_uart", "irq_aggregator", "perf_counter", "mailbox",
    ],
}


# ---------------------------------------------------------------------------
# Heartbeat (from vertexai_express_agent.py / v19)
# ---------------------------------------------------------------------------
@contextmanager
def heartbeat(message, interval_seconds=15):
    """Log elapsed time every interval_seconds while a block runs."""
    stop_event = threading.Event()

    def run():
        start = time.monotonic()
        while not stop_event.wait(interval_seconds):
            elapsed = int(time.monotonic() - start)
            print(f"[INFO] {message} ({elapsed}s elapsed)", file=sys.stderr, flush=True)

    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    try:
        yield
    finally:
        stop_event.set()
        thread.join(timeout=1)


# ---------------------------------------------------------------------------
# Model endpoint client (from vertexai_express_agent.py - the mandated
# interface: ALL model calls go through info["model_endpoint"], never a
# direct SDK/API call. This is the fix for the critical contract violation
# present in every one of T19's own v2-v19 agent versions.)
# ---------------------------------------------------------------------------
def parse_error_payload(error_text):
    try:
        payload = json.loads(error_text)
    except json.JSONDecodeError:
        return {"error": error_text}
    return payload if isinstance(payload, dict) else {"error": error_text}


def should_retry(status_code, payload):
    if payload.get("retryable") is True:
        return True
    return status_code in RETRYABLE_HTTP_STATUS


def write_diagnostics(path, diagnostics, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    data = dict(diagnostics or {})
    data["text_chars"] = len(text or "")
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def call_model(endpoint, prompt, model, max_tokens=8192, max_retries=5, diagnostics_path=None):
    """POST to the benchmark model endpoint with heartbeat + exponential backoff.

    Note: the /generate API only accepts {model, prompt, max_output_tokens} -
    there is no separate system_prompt/temperature field, so callers must fold
    any system instructions into `prompt` itself before calling this.
    """
    if not endpoint:
        raise RuntimeError(
            "model_endpoint missing from info.json. Run via runner/run_benchmark.py "
            "(or pass --model-endpoint pointing at a running model service)."
        )

    url = endpoint.rstrip("/") + "/generate"
    body = json.dumps({
        "model": model,
        "prompt": prompt,
        "max_output_tokens": max_tokens,
    }).encode("utf-8")

    delay = 2
    for attempt in range(1, max_retries + 1):
        print(f"[INFO] Model request attempt {attempt}/{max_retries} using {model}",
              file=sys.stderr, flush=True)
        try:
            req = urllib.request.Request(
                url, data=body,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with heartbeat("Waiting for model response"):
                with urllib.request.urlopen(req, timeout=300) as resp:
                    payload = json.loads(resp.read().decode("utf-8"))

            text = payload.get("text") or ""
            diagnostics = payload.get("diagnostics") or {}
            if diagnostics_path:
                write_diagnostics(diagnostics_path, diagnostics, text)
            if not text.strip():
                print(f"[WARN] Model returned empty text. Diagnostics: {diagnostics}",
                      file=sys.stderr, flush=True)
            return text

        except urllib.error.HTTPError as exc:
            err_payload = parse_error_payload(exc.read().decode("utf-8", errors="replace"))
            if not should_retry(exc.code, err_payload):
                raise RuntimeError(f"Model non-retryable error {exc.code}: {err_payload}")
            if attempt == max_retries:
                raise RuntimeError(f"Model retry limit reached after {exc.code}: {err_payload}")
            print(f"[WARN] Retryable error {exc.code}. Retry in {delay}s ({attempt}/{max_retries})",
                  file=sys.stderr, flush=True)
            time.sleep(delay)
            delay = min(delay * 2, 60)

        except urllib.error.URLError as exc:
            if attempt == max_retries:
                raise RuntimeError(f"Model endpoint unreachable: {exc}")
            print(f"[WARN] Connection error. Retry in {delay}s ({attempt}/{max_retries}) {exc}",
                  file=sys.stderr, flush=True)
            time.sleep(delay)
            delay = min(delay * 2, 60)

    raise RuntimeError("Maximum retries exceeded.")


# ---------------------------------------------------------------------------
# Architecture parsing with directed-graph extraction (from t19_nxp_agent_v16.py,
# the last version with a fully verified complete local run; v19's class-based
# refactor is equivalent, kept as inline functions here for simplicity)
# ---------------------------------------------------------------------------
def extract_graph_topology(html_str: str) -> str:
    """Extracts nodes and edges from SVG graphs into an explicit directed-graph
    text representation - far more reliable than asking the model to infer
    wiring topology purely from prose/table text."""
    topology_text = "\n=== LOCALLY EXTRACTED DIRECTED GRAPHS ===\n"
    svgs = re.findall(r'<svg.*?>.*?</svg>', html_str, flags=re.DOTALL | re.IGNORECASE)

    for i, svg in enumerate(svgs):
        nodes = re.findall(r'<g[^>]*class=["\'][^"\']*node[^"\']*["\'][^>]*>(.*?)</g>', svg, flags=re.DOTALL | re.IGNORECASE)
        edges = re.findall(r'<g[^>]*class=["\'][^"\']*edge[^"\']*["\'][^>]*>(.*?)</g>', svg, flags=re.DOTALL | re.IGNORECASE)

        if not nodes and not edges:
            continue

        topology_text += f"\n--- GRAPH {i+1} TOPOLOGY ---\n"
        topology_text += "NODES:\n"
        for node in nodes:
            node = re.sub(r'<(path|polygon)[^>]*>.*?</\1>', '', node, flags=re.DOTALL | re.IGNORECASE)
            node = re.sub(r'<(path|polygon)[^>]*>', '', node, flags=re.IGNORECASE)
            t_match = re.search(r'<title>(.*?)</title>', node, flags=re.IGNORECASE)
            title = t_match.group(1).strip() if t_match else "Unknown"
            texts = re.findall(r'<text[^>]*>(.*?)</text>', node, flags=re.DOTALL | re.IGNORECASE)
            clean_texts = [re.sub(r'<[^>]+>', '', t).strip() for t in texts if t.strip()]
            topology_text += f"  - [{title}]: {' | '.join(clean_texts)}\n"

        topology_text += "EDGES (Connections):\n"
        for edge in edges:
            edge = re.sub(r'<(path|polygon)[^>]*>.*?</\1>', '', edge, flags=re.DOTALL | re.IGNORECASE)
            edge = re.sub(r'<(path|polygon)[^>]*>', '', edge, flags=re.IGNORECASE)
            t_match = re.search(r'<title>(.*?)</title>', edge, flags=re.IGNORECASE)
            if t_match:
                edge_title = t_match.group(1).replace('&#45;&gt;', '->').replace('-&gt;', '->').strip()
                topology_text += f"  - {edge_title}\n"

    return topology_text


def parse_architecture_html(html_str: str) -> str:
    """Parses the NXP documentation using its documented HTML class structure
    (ph/ps/sec/sh/co/dc/rtw/deliv - see AGENT_GUIDE.md) plus SVG graph extraction."""
    graph_topology = extract_graph_topology(html_str)

    html_str = re.sub(r'<svg.*?>.*?</svg>', '', html_str, flags=re.DOTALL | re.IGNORECASE)
    html_str = re.sub(r'</tr\s*>', '\n', html_str, flags=re.IGNORECASE)
    html_str = re.sub(r'</td\s*>', ' | ', html_str, flags=re.IGNORECASE)
    html_str = re.sub(r'</th\s*>', ' | ', html_str, flags=re.IGNORECASE)

    html_str = re.sub(r'<div[^>]*class=["\']ph["\'][^>]*>', '\n=== PROBLEM HEADER ===\n', html_str, flags=re.IGNORECASE)
    html_str = re.sub(r'<div[^>]*class=["\']ps["\'][^>]*>', '\n=== PROBLEM STATEMENT ===\n', html_str, flags=re.IGNORECASE)
    html_str = re.sub(r'<div[^>]*class=["\']sec["\'][^>]*>', '\n=== SECTION ===\n', html_str, flags=re.IGNORECASE)
    html_str = re.sub(r'<div[^>]*class=["\']sh["\'][^>]*>', '\n--- SECTION HEADER ---\n', html_str, flags=re.IGNORECASE)
    html_str = re.sub(r'<div[^>]*class=["\']co["\'][^>]*>', '\n--- CONTENT ---\n', html_str, flags=re.IGNORECASE)
    html_str = re.sub(r'<[^>]*class=["\']rtw["\'][^>]*>', '\n--- REGISTER MAP ---\n', html_str, flags=re.IGNORECASE)
    html_str = re.sub(r'<div[^>]*class=["\']deliv["\'][^>]*>', '\n=== DELIVERABLES ===\n', html_str, flags=re.IGNORECASE)

    text = re.sub(r'<[^>]+>', ' ', html_str)
    text = re.sub(r' {2,}', ' ', text)
    text = re.sub(r'\n\s*\n+', '\n\n', text)

    return text.strip() + "\n\n" + graph_topology


def extract_yaml_blocks(llm_output: str) -> list:
    """Extracts individual YAML documents from the model's response.

    Despite being asked for one ```yaml``` fence per IP, models sometimes stack
    multiple '---'-separated YAML documents inside a single fence instead -
    yaml.safe_load (used by rtl_gen_main.py) raises ComposerError on a
    multi-document stream, so each fence is further split on document
    separators. This is a no-op for models that already emit one fence per IP.
    """
    if not llm_output:
        return []
    pattern = r"`" * 3 + r"ya?ml\s*(.*?)\s*" + r"`" * 3
    matches = re.findall(pattern, llm_output, flags=re.DOTALL | re.IGNORECASE)

    docs = []
    for m in matches:
        for doc in re.split(r'\n\s*-{3,}\s*\n', m.strip()):
            doc = doc.strip()
            if doc:
                docs.append(doc)
    return docs


def extract_verilog(llm_output: str) -> str:
    """Strips the ```verilog ... ``` fence around the model's response.

    Larger top-level modules (medium/hard have 10-20+ IP instances to wire,
    vs. easy's flatter structure) can exhaust max_output_tokens before the
    model emits a closing fence. When that happens there's no complete
    ```...``` match, so fall back to stripping just a leading fence marker
    (if present) rather than returning the raw text verbatim - which would
    otherwise leave a literal ```verilog line as line 1 of the .v file,
    guaranteed to fail elaboration on top of the truncation itself.
    """
    if not llm_output:
        return ""
    pattern = r"`" * 3 + r"(?:verilog|systemverilog|v)?\s*(.*?)\s*" + r"`" * 3
    match = re.search(pattern, llm_output, flags=re.DOTALL | re.IGNORECASE)
    if match:
        return match.group(1).strip()
    stripped = re.sub(r'^\s*`{3}\w*\s*\n?', '', llm_output)
    return stripped.strip()


def _parse_flat_yaml(text):
    """Minimal flat key:value parser, sufficient for the single-level YAML
    specs Step 2 emits (ip_type, name, node_x, node_y, data_width, addr_width,
    ...). Avoids a hard dependency on PyYAML being installed for this one
    interception point."""
    spec = {}
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line or ":" not in line:
            continue
        key, _, val = line.partition(":")
        spec[key.strip()] = val.strip().strip('"').strip("'")
    return spec


def try_stitch_noc_mesh(yaml_paths, out_dir, rtl_gen_lib_dir):
    """If this problem's YAML specs describe a complete rectangular
    tilelink_router mesh, generate the deterministic noc_mesh module (see
    NOTES.md "NoC mesh end-to-end verified") instead of leaving the LLM to
    hand-wire it at the top level - empirically it does not attempt real
    per-node wiring for this (see NOC_MESH_WIRING_NOTE's comment above).
    Returns (mesh_v_path, internal_filenames_to_hide) or (None, set()) if
    this problem has no router mesh, or the mesh doesn't match the
    "complete rectangular grid with u_router_XY/u_ni_XY/u_sram_XY naming"
    assumption gen_noc_mesh.py requires - in which case Step 4 falls back
    to its old behaviour (better a known, already-documented gap than a
    crash on an unexpected topology).
    """
    specs = [(_parse_flat_yaml(yp.read_text(encoding="utf-8")), yp) for yp in yaml_paths]
    router_specs = [(s, yp) for s, yp in specs if s.get("ip_type") == "tilelink_router"]
    if not router_specs:
        return None, set()

    nodes = {}  # (x,y) -> (router_name, dw, aw)
    for s, yp in router_specs:
        name = s.get("name", "")
        m = re.search(r"(\d)(\d)$", name)
        if not m:
            print(f"[WARN] Router {name!r} doesn't end in two coordinate digits - "
                  f"skipping noc_mesh stitching, falling back to LLM top-level wiring.", file=sys.stderr)
            return None, set()
        x, y = int(m.group(1)), int(m.group(2))
        try:
            dw, aw = int(s["data_width"]), int(s["addr_width"])
        except (KeyError, ValueError):
            print(f"[WARN] Router {name!r} missing data_width/addr_width - skipping noc_mesh stitching.",
                  file=sys.stderr)
            return None, set()
        nodes[(x, y)] = (name, dw, aw)

    mesh_nx = max(x for x, y in nodes) + 1
    mesh_ny = max(y for x, y in nodes) + 1
    if len(nodes) != mesh_nx * mesh_ny:
        print(f"[WARN] Router coordinates don't form a complete {mesh_nx}x{mesh_ny} "
              f"rectangular grid ({len(nodes)} routers found) - skipping noc_mesh stitching.",
              file=sys.stderr)
        return None, set()

    internal_files = set()
    for (x, y), (rname, dw, aw) in nodes.items():
        ni_name = rname.replace("router", "ni")
        sram_name = rname.replace("router", "sram")
        for fname in (f"{rname}.v", f"{ni_name}.v", f"{sram_name}.v"):
            if not (Path(out_dir) / fname).is_file():
                print(f"[WARN] Expected {fname} not found in output dir - skipping noc_mesh stitching.",
                      file=sys.stderr)
                return None, set()
            internal_files.add(fname)

    sram_depth = 1024
    for s, yp in specs:
        if s.get("ip_type") == "axi_lite_sram" and s.get("name", "").replace("sram", "router") in \
                {rname for rname, _, _ in nodes.values()}:
            try:
                sram_depth = int(s["depth"])
            except (KeyError, ValueError):
                pass
            break

    any_dw, any_aw = next(iter(nodes.values()))[1:]
    ext_dir = str(Path(__file__).resolve().parent / "rtl_gen_lib_ext")
    if ext_dir not in sys.path:
        sys.path.insert(0, ext_dir)
    lib_dir = str(Path(rtl_gen_lib_dir).resolve())
    if lib_dir not in sys.path:
        sys.path.insert(0, lib_dir)
    from gen_noc_mesh import gen_noc_mesh

    mesh_spec = {
        "name": "noc_mesh", "mesh_nx": mesh_nx, "mesh_ny": mesh_ny,
        "data_width": any_dw, "addr_width": any_aw, "ext_data_width": 32,
        "sram_depth": sram_depth,
    }
    files = gen_noc_mesh(mesh_spec)
    mesh_path = None
    for fname, content in files.items():
        fpath = Path(out_dir) / fname
        fpath.write_text(content, encoding="utf-8")
        mesh_path = str(fpath)
        print(f"[GEN-MESH] {fpath} ({len(content):,} chars) - stitches {len(nodes)} routers "
              f"({mesh_nx}x{mesh_ny})", file=sys.stderr)
    return mesh_path, internal_files


def fix_crossbar_s0_window(yaml_paths):
    """Widen the axi_lite_crossbar's S0 (NoC) slave_ranges window in place
    if Step 2 inferred one too small to cover valid NoC destination
    addresses - this parameter has been observed to be LLM-inference-
    non-deterministic across otherwise-identical regenerations (one run
    correctly inferred base=0/size=0x80000000, matching IP_CONSTRAINTS'
    own worked example; a later run inferred size=0x10000000 instead,
    which requires addr[31:28]==0000 exactly and so silently rejects any
    write to a node with dest_x/dest_y != 0 - confirmed via a real hang:
    noc_routing's entire testbench timed out and aes_basic's own
    SRAM-via-NoC-routing check timed out too, while every purely-local
    test on the SAME regeneration passed fine). Since S1/S2 are always at
    0xF0xx_xxxx in this architecture (top bit set), size=0x80000000 (top
    bit clear) is always a safe, non-overlapping choice for S0 regardless
    of the doc's exact addresses - so this is corrected deterministically
    here instead of continuing to depend on the LLM inferring it right
    every time.
    """
    for yp in yaml_paths:
        text = yp.read_text(encoding="utf-8")
        spec = _parse_flat_yaml(text)
        if spec.get("ip_type") != "axi_lite_crossbar":
            continue
        if "slave_ranges" not in text:
            continue
        # Format-agnostic: Step 2 has been observed emitting slave_ranges in
        # both flow style (`- {base: 0x.., size: 0x..}`) and block style
        # (`- base: 0x..` / `  size: 0x..` on separate lines) across
        # different regenerations - just take the FIRST "size:" line
        # anywhere in this file (S0, the first list entry) rather than
        # parsing full YAML list structure.
        lines = text.splitlines(keepends=True)
        for idx, line in enumerate(lines):
            sm = re.search(r'size:\s*["\']?(0x[0-9a-fA-F]+)["\']?', line)
            if not sm:
                continue
            size0 = int(sm.group(1), 16)
            if size0 < 0x80000000:
                print(f"[FIX] {yp.name}: S0 slave_range size {sm.group(1)} is too "
                      f"small (requires addr[31:28]==0 exactly, rejecting any "
                      f"non-(0,0) NoC destination) - widening to 0x80000000.",
                      file=sys.stderr)
                lines[idx] = re.sub(r'size:\s*["\']?0x[0-9a-fA-F]+["\']?', 'size: 0x80000000', line, count=1)
                yp.write_text("".join(lines), encoding="utf-8")
            break  # only ever touch the FIRST size: line (S0)


def fix_ahb_bridge_hprot(top_level_verilog):
    """Force the ahb_to_apb_bridge instantiation's hprot tie-off to have
    bit0 set, in the Step-4 LLM-generated top-level Verilog text.

    apb_fabric's own generator (gen_apb_fabric / gen_apb_fabric_v2) gates
    its privileged slot (S3, apb_timer0 per the architecture doc's address
    map) on `m_pprot[0]` - the bridge passes hprot straight through to
    pprot unmodified. But this SoC's CPU-facing AXI4-Lite port has no
    privilege signal at all, so the Step-4 top-level has nothing to base
    hprot on and just ties it to a constant - observed as 3'b000 in a
    real generation (t19_hard_test9), which makes bit0 permanently 0 and
    therefore makes apb_timer0 PERMANENTLY unreachable via the documented
    global CPU address map (confirmed via a real simulation: a LOAD0/CTRL0
    write to timer0 silently misses - m_prdata reads back the fabric's own
    DEAD_BEEF miss sentinel - regardless of address correctness). Since
    this architecture never defines more than one CPU master, "always
    privileged" is the only sane interpretation and is safe SoC-wide (no
    other logic reads hprot/pprot) - so this is corrected deterministically
    here rather than depending on the LLM guessing a privilege value it
    was never given any basis to infer.
    """
    def repl(m):
        return m.group(1) + "3'b001" + m.group(3)
    fixed, n = re.subn(r'(\.hprot\()([^)]*)(\))', repl, top_level_verilog, count=1)
    if n:
        print("[FIX] Top-level: forced ahb_to_apb_bridge's hprot tie-off to "
              "3'b001 (bit0=1) - apb_fabric's privileged slot (timer0) is "
              "otherwise permanently unreachable, since this SoC's CPU port "
              "has no privilege signal for the LLM to have wired hprot from.",
              file=sys.stderr)
    return fixed


def fix_perf_counter_hier_ref(top_level_verilog):
    """Correct a real Step-4 top-level bug: a real generation
    (t19_hard_test11) referenced `u_perf.u_cnt0.count` (and .u_cnt1/2/3)
    - a hierarchical cross-module reference assuming the perf_counter
    instance internally wraps each counter in its own sub-module (u_cntN)
    with a register named `count`. Neither gen_perf_counter nor
    gen_perf_counter_v2 do that - both declare flat registers named
    `cnt0`..`cnt3` directly inside the perf_counter module itself.
    iverilog fails elaboration outright on this ("Unable to bind
    wire/reg/memory `u_perf.u_cnt0.count`"), blocking every category's
    testbench on any run where Step 4 writes it this way - not just
    perf_counter's own tests. Since `cntN` is always the exact, guaranteed
    real register name (it's hardcoded in both generator versions, never
    LLM-inferred), this substitution is always safe and deterministic -
    same "don't depend on the LLM guessing it right every time"
    philosophy as the crossbar S0 window and AHB bridge hprot fixes.
    """
    fixed, n = re.subn(r'u_perf\.u_cnt(\d+)\.count', r'u_perf.cnt\1', top_level_verilog)
    if n:
        print(f"[FIX] Top-level: corrected {n} broken u_perf.u_cntN.count "
              f"hierarchical reference(s) to u_perf.cntN (the real flat "
              f"register name) - the sub-module wrapper the LLM assumed "
              f"doesn't exist in either perf_counter generator.",
              file=sys.stderr)
    return fixed


def fix_mbox_wr_en_pulse(top_level_verilog):
    """Correct a real Step-4 top-level bug: whatever drives `u_mbox`'s
    `wr_en` port (the architecture doc's own REQUIRED internal wire name
    for this signal is `mbox_wr_en` - "write-enable from SoC config reg
    into async mailbox") behaves as a LEVEL that can stay high for more
    than one clock cycle, not a single-cycle pulse. `gen_async_fifo`'s
    write logic has no edge-detection (`if (wr_en && !full) ...
    wr_bin<=wr_bin+1;` - a plain level check, by design, matching every
    other simple write-enable in this codebase) - it faithfully writes
    once per clock cycle for as long as wr_en stays high. Confirmed via a
    real trace: a single logical CPU write held awvalid/wvalid for two
    clock cycles (completely normal, spec-legal AXI4-Lite master
    behavior, the same "hold through bvalid" pattern already required
    elsewhere in this SoC - see tb_hard_common.vh's own axi_write), and
    the resulting level pushed the SAME word into the mailbox TWICE.

    This has been observed generated THREE structurally different ways
    across regenerations - a plain `assign mbox_wr_en = expr;`, an inline
    `wire mbox_wr_en = expr;`, and (t19_hard_test16) a clocked `reg` that
    still re-asserts to 1 every cycle its own trigger condition holds
    (registered, but not edge-limited - the same underlying bug in a
    different shape). Rather than keep chasing new syntactic forms of
    the SOURCE expression, this fixes it at the one place guaranteed to
    exist regardless of source style: `u_mbox`'s own `.wr_en(...)` port
    connection. Whatever currently feeds that port is wrapped in a fresh
    edge-detector and the connection is redirected to the edge-detected
    result - safe and idempotent even if a future run's `mbox_wr_en`
    already happens to be a proper single-cycle pulse (edge-detecting an
    already-single-cycle pulse just re-derives the same pulse).
    """
    m = re.search(r'u_mbox\b[^;]*\([^;]*?\);', top_level_verilog, re.DOTALL)
    if not m:
        return top_level_verilog
    block = m.group(0)
    wr_en_m = re.search(r'\.wr_en\(\s*([^)]+?)\s*\)', block)
    if not wr_en_m:
        return top_level_verilog
    orig_expr = wr_en_m.group(1)
    if orig_expr == "mbox_wr_en_pulse":
        return top_level_verilog  # already patched
    new_block = block[:wr_en_m.start()] + ".wr_en(mbox_wr_en_pulse)" + block[wr_en_m.end():]
    pulse_logic = (
        "reg mbox_wr_en_prev;\n"
        "    always @(posedge clk or negedge sys_rst_n)\n"
        "        if (!sys_rst_n) mbox_wr_en_prev <= 1'b0;\n"
        f"        else mbox_wr_en_prev <= ({orig_expr});\n"
        f"    wire mbox_wr_en_pulse = ({orig_expr}) & ~mbox_wr_en_prev;\n    "
    )
    print("[FIX] Top-level: wrapped u_mbox's wr_en connection in a fresh "
          "single-cycle edge-detector - whatever currently drives it "
          "behaves as a level that can stay high for more than one clock "
          "cycle (a CPU master legally holding awvalid/wvalid through "
          "bvalid), which was silently pushing the same word into the "
          "mailbox multiple times.", file=sys.stderr)
    return top_level_verilog[:m.start()] + pulse_logic + new_block + top_level_verilog[m.end():]


def fix_mbox_rd_rst_n(top_level_verilog):
    """Correct a real, serious Step-4 top-level bug (t19_hard_test15):
    `u_mbox`'s `rd_rst_n` port tied to a constant `1'b1` (with the LLM's
    own comment "// Async reset not explicitly tied"), instead of
    `sys_rst_n`. Since gen_async_fifo's entire read-side register file
    (`rd_bin`, `rd_gray`, `rdg1`, `rdg2`) only ever initializes inside
    `if (!rd_rst_n) ...` - and `rd_rst_n` never once deasserts-then-stays-
    permanently-1 the way a real reset does, it just IS 1 from time 0 -
    every read-side register starts at Verilog's default uninitialized
    'x' and stays there forever, permanently breaking `mbox_empty`/
    `mbox_dout`/`mbox_rd_en` (confirmed via a real trace: every read-side
    signal reads 'x' throughout the whole simulation). This is a direct,
    unambiguous architecture-doc violation - the doc states plainly
    "wr_rst_n and rd_rst_n both = sys_rst_n" - and both `u_mbox` (the
    required instance name) and `rd_rst_n` (the generator's own fixed
    port name) are guaranteed, not LLM-inferred, so this is corrected
    deterministically within the `u_mbox` instantiation specifically
    (never touching any OTHER reset signal elsewhere in the design).
    """
    m = re.search(r'u_mbox\b[^;]*\([^;]*?\);', top_level_verilog, re.DOTALL)
    if not m:
        return top_level_verilog
    block = m.group(0)
    new_block, n = re.subn(r'\.rd_rst_n\(\s*[^)]+\)', '.rd_rst_n(sys_rst_n)', block)
    if n == 0 or new_block == block:
        return top_level_verilog
    print("[FIX] Top-level: forced u_mbox's rd_rst_n port to sys_rst_n - "
          "it was tied to a constant (never actually resetting), leaving "
          "every read-side register permanently 'x' and the mailbox's "
          "entire DSP-side interface non-functional. The doc requires "
          "'wr_rst_n and rd_rst_n both = sys_rst_n'.", file=sys.stderr)
    return top_level_verilog[:m.start()] + new_block + top_level_verilog[m.end():]


def fix_perf_paddr_rebase(top_level_verilog):
    """Correct two real Step-4 top-level bugs around `u_perf`'s SoC
    config-space wiring, confirmed across multiple independent
    regenerations even AFTER adding explicit prompt guidance about them
    (SOC_CFG_WIRING_NOTE point 4).

    Bug A - PERF_CNT0..3 addressing (t19_hard_test19/test20/test22):
    `u_perf`'s `paddr` port gets driven with the SoC config space's raw
    address offset passed straight through (e.g. `{4'h0,
    s2_awaddr[7:0]}`), with no rebasing. But `u_perf`'s own internal
    register convention is FIXED and independent of wherever it's mapped
    into the larger SoC address space - its own paddr=0/4/8/12 read
    cnt0/cnt1/cnt2/cnt3 respectively, always starting from 0. The
    architecture doc maps PERF_CNT0 to SoC config offset 0x08 (not
    0x00), so a raw pass-through reads/writes the WRONG counter
    (confirmed directly: forcing a real event pulse to make cnt0=1, then
    reading the documented PERF_CNT0 SoC offset, returned 0 - because
    the unrebased address landed on u_perf's own cnt2 instead).

    Bug B - PERF_CTRL's clear-all bit (t19_hard_test19/test20, PERF_CTRL
    write bit1 documented as "write 1 to clear all counters"):
    PERF_CTRL (SoC offset 0x18) isn't one of u_perf's own four counter
    registers at a rebased offset - it's a distinct SoC-level concept.
    Naively rebasing 0x18 the same way as the counters (0x18 - 0x08 =
    0x10) lands on a paddr u_perf doesn't recognize as anything - not
    one of its four counters, and specifically NOT its own paddr=0
    clear-all trigger (`if (psel&&penable&&pwrite&&paddr==0) begin
    {clr} end`) - so nothing happens. Confirmed both observed
    regenerations' own psel-generation logic already covers offset 0x18
    in its "is this a perf register" range check (it's naturally
    included alongside the four counters), so psel/penable/pwrite were
    already asserting correctly for a PERF_CTRL write - only paddr
    needed to be redirected to 0 specifically for this one case.

    Both fixed together by completely replacing `u_perf`'s
    `.psel`/`.penable`/`.pwrite`/`.paddr` connections with a fresh,
    self-contained set of wires computed directly from the crossbar's
    own guaranteed, non-inferred S2 port names (never touching pwdata -
    the clear-all trigger doesn't care about its value). Taking full
    ownership of all four signals (not just paddr) avoids depending on
    whatever range-check logic the LLM happened to write for psel/
    pwrite being correct - a DIFFERENT regeneration's own check could in
    principle use an exclusive upper bound that excludes 0x18 entirely,
    silently never asserting psel for a PERF_CTRL write at all.
    """
    # Anchored on the actual instantiation syntax ("u_perf u_perf (" - module
    # name then instance name then the port-list's opening paren), not just
    # a bare "u_perf" followed eventually by a "(" - t19_hard_test25 has a
    # comment ("...the internal paddr of u_perf (0x08 -> 0x00, ...)") that a
    # looser pattern latches onto FIRST (it appears earlier in the file),
    # matching a useless few-word fragment up to that comment line's own
    # semicolon instead of the real instantiation - silently no-oping both
    # perf fixes with no error, confirmed via direct inspection of exactly
    # this failure on that regeneration.
    m = re.search(r'u_perf\s+u_perf\s*\([^;]*?\);', top_level_verilog, re.DOTALL)
    if not m:
        return top_level_verilog
    block = m.group(0)
    paddr_m = re.search(r'\.paddr\(\s*([^)]+?)\s*\)', block)
    if not paddr_m:
        return top_level_verilog
    paddr_expr = paddr_m.group(1)
    # Safety guard: u_perf has been seen reached through a COMPLETELY
    # different scheme too (t19_hard_test14: an inline S1/APB-fabric
    # slot, `psel_perf = psel && paddr[15:12]==7`, paddr fed from a
    # plain `apb_reg_addr` wire tied to S1's OWN paddr - nothing to do
    # with S2 at all). Blindly replacing paddr with an S2-address-
    # derived expression there would BREAK a currently-working,
    # unrelated addressing path by feeding it S2's irrelevant address.
    # Only proceed if the expression feeding paddr genuinely references
    # an s2_ signal, checking both an inline expression directly (e.g.
    # `.paddr({4'h0, s2_awaddr[7:0]})`) and the common case of an
    # intermediate named wire (e.g. `.paddr(perf_paddr)`) by chasing
    # that wire's own declaration elsewhere in the file.
    # t19_hard_test25 turned up a THIRD structural variant this one-level
    # chase doesn't reach: `.paddr(perf_paddr)` where `perf_paddr` is
    # computed from an intermediate `soc_reg_offset` wire (itself
    # `s2_awvalid ? s2_awaddr[7:0] : s2_araddr[7:0]`) - genuinely S2-routed,
    # just two hops of indirection away instead of one. Chase bounded-depth
    # (3 hops - comfortably covers this and the original 1-hop case) through
    # every intermediate wire's own declaration, not just the first one.
    def _chase_s2_routed(expr, depth=3, seen=None):
        if seen is None:
            seen = set()
        if "s2_" in expr:
            return True
        if depth <= 0:
            return False
        for ident in set(re.findall(r'\b[A-Za-z_]\w*\b', expr)):
            if ident in seen:
                continue
            seen.add(ident)
            decl_m = re.search(
                rf'(?:assign\s+{re.escape(ident)}\s*=|wire(?:\s*\[[^\]]+\])?\s+{re.escape(ident)}\s*=)([^;]+);',
                top_level_verilog)
            if decl_m and _chase_s2_routed(decl_m.group(1), depth - 1, seen):
                return True
        return False

    is_s2_routed = _chase_s2_routed(paddr_expr)
    if not is_s2_routed:
        return top_level_verilog
    FIXED_PADDR = "perf_paddr_rebased"
    if paddr_m.group(1) == FIXED_PADDR:
        return top_level_verilog  # already patched
    new_block = block
    for port, repl in (("psel", "perf_psel_fixed"), ("penable", "perf_penable_fixed"),
                       ("pwrite", "perf_pwrite_fixed"), ("paddr", FIXED_PADDR)):
        port_m = re.search(rf'\.{port}\(\s*([^)]+?)\s*\)', new_block)
        if port_m:
            new_block = new_block[:port_m.start()] + f".{port}({repl})" + new_block[port_m.end():]
    decl = (
        "wire perf_ctrl_clear = s2_awvalid && s2_wvalid && "
        "(s2_awaddr[7:0] == 8'h18) && s2_wdata[1];\n"
        "    wire perf_range_hit = (s2_awvalid ? s2_awaddr[7:0] : s2_araddr[7:0]) >= 8'h08 && "
        "(s2_awvalid ? s2_awaddr[7:0] : s2_araddr[7:0]) <= 8'h18;\n"
        "    wire perf_psel_fixed = (s2_awvalid || s2_arvalid) && perf_range_hit;\n"
        "    wire perf_penable_fixed = perf_psel_fixed;\n"
        "    wire perf_pwrite_fixed = s2_awvalid;\n"
        f"    wire [11:0] {FIXED_PADDR} = perf_ctrl_clear ? 12'h000 : "
        "{4'h0, (s2_awvalid ? s2_awaddr[7:0] : s2_araddr[7:0]) - 8'h08};\n    "
    )
    print("[FIX] Top-level: replaced u_perf's psel/penable/pwrite/paddr "
          "connections with a fresh, self-contained set of wires - "
          "PERF_CNT0..3 reads were passed the raw SoC offset unrebased "
          "(landing on the wrong counter), and PERF_CTRL's clear-all "
          "write (bit1) was never redirected to u_perf's own paddr=0 "
          "clear-all trigger.", file=sys.stderr)
    return top_level_verilog[:m.start()] + decl + new_block + top_level_verilog[m.end():]


def fix_perf_event0_wiring(top_level_verilog):
    """Fix a real Step-4 top-level bug, found via `tb_hard_integration.v`'s
    T1205 on a fresh regeneration (`t19_hard_test25`): `u_perf`'s
    `event_0` port (documented as "ch[0] = ni_00 tl_a_valid, NoC
    transactions from CPU") tied to a flat constant instead of any real
    signal, with a generated comment admitting it: "Unused directly
    inside integrated noc_mesh, but we can feed 1'b0 or pull from a safe
    logic level". Root cause: `try_stitch_noc_mesh()` hides the
    individual `u_ni_XY`/`u_router_XY` instances (and their internal
    TileLink signals) from Step 4's prompt entirely - it only ever sees
    the one clean `noc_mesh` header exposing per-node AXI4-Lite ports -
    so there is no internal NI signal for the LLM to reach for ch[0] even
    in principle, and it (reasonably, given what it can see) fell back to
    a constant.

    Fix: the crossbar's own guaranteed S0 port handshake
    (`s0_awvalid && s0_awready`, `s0_arvalid && s0_arready`) fires
    exactly once per real CPU-initiated NoC transaction accepted at node
    (0,0) - the same node ni_00/router_00 sit at - so it is a functionally
    equivalent, always-visible substitute for "ni_00 tl_a_valid" that
    doesn't require exposing any new internal mesh signal. Only replaces
    `event_0` when it (or, following ONE level of indirection through a
    named wire - the common case, e.g. `.event_0(perf_ev0)` with `wire
    perf_ev0 = 1'b0;` elsewhere - confirmed on t19_hard_test25) resolves
    to a flat constant (`1'b0`/`1'd0`/`0`/`1'b1`) - a deliberately narrow,
    unambiguous trigger, so this never overwrites a regeneration that
    already wires something real (even if not this exact expression)
    into event_0.
    """
    # Anchored on the actual instantiation syntax ("u_perf u_perf (" - module
    # name then instance name then the port-list's opening paren), not just
    # a bare "u_perf" followed eventually by a "(" - t19_hard_test25 has a
    # comment ("...the internal paddr of u_perf (0x08 -> 0x00, ...)") that a
    # looser pattern latches onto FIRST (it appears earlier in the file),
    # matching a useless few-word fragment up to that comment line's own
    # semicolon instead of the real instantiation - silently no-oping both
    # perf fixes with no error, confirmed via direct inspection of exactly
    # this failure on that regeneration.
    m = re.search(r'u_perf\s+u_perf\s*\([^;]*?\);', top_level_verilog, re.DOTALL)
    if not m:
        return top_level_verilog
    block = m.group(0)
    ev0_m = re.search(r'\.event_0\(\s*([^)]+?)\s*\)', block)
    if not ev0_m:
        return top_level_verilog
    ev0_expr = ev0_m.group(1)

    def _is_flat_const(expr):
        expr = expr.strip()
        return bool(re.match(r"^1'[bBdD]?[01]$", expr)) or expr in ("0", "1")

    # t19_hard_test25's actual pattern is one hop of indirection:
    # `.event_0(perf_ev0)` with `wire perf_ev0 = 1'b0;` declared
    # elsewhere - chase through a single named-wire indirection (same
    # bounded, conservative approach as fix_perf_paddr_rebase's s2_ chase)
    # so the fix still finds and replaces the constant at its real
    # declaration site, leaving the port connection's own wire name intact.
    decl_target = None  # None = patch the port connection itself
    if _is_flat_const(ev0_expr):
        pass
    elif re.match(r'^\w+$', ev0_expr):
        decl_m = re.search(
            rf'(?:assign\s+{re.escape(ev0_expr)}\s*=|wire(?:\s*\[[^\]]+\])?\s+{re.escape(ev0_expr)}\s*=)([^;]+);',
            top_level_verilog)
        if decl_m and _is_flat_const(decl_m.group(1)):
            decl_target = decl_m
        else:
            return top_level_verilog
    else:
        return top_level_verilog

    if "s0_awvalid" not in top_level_verilog or "s0_arvalid" not in top_level_verilog:
        # No guaranteed S0 handshake names found (unexpected top-level
        # structure) - nothing safe to wire event_0 to instead.
        return top_level_verilog
    FIXED_EXPR = "((s0_awvalid && s0_awready) || (s0_arvalid && s0_arready))"
    print("[FIX] Top-level: u_perf's event_0 was tied to a flat constant "
          "(perf ch[0] would never count) - rewired to the crossbar's own "
          "S0 AXI handshake, a real per-transaction pulse at the CPU's "
          "NoC entry node.", file=sys.stderr)
    if decl_target is not None:
        # Rewrite the intermediate wire's own declaration RHS in place,
        # leaving `.event_0(perf_ev0)` (or whatever it's named) untouched.
        start, end = decl_target.start(1), decl_target.end(1)
        return top_level_verilog[:start] + f" {FIXED_EXPR}" + top_level_verilog[end:]
    new_block = block[:ev0_m.start()] + f".event_0({FIXED_EXPR})" + block[ev0_m.end():]
    return top_level_verilog[:m.start()] + new_block + top_level_verilog[m.end():]


def rtl_gen_from_yaml(yaml_path, rtl_gen_lib_dir, out_dir, problem=None):
    """Call rtl_gen_main.py --spec <yaml> --outdir <dir>. Returns generated filenames."""
    yaml_text = Path(yaml_path).read_text(encoding="utf-8")
    spec = _parse_flat_yaml(yaml_text)
    # irq_aggregator's v2 fix is intentionally EXCLUDED here for the easy
    # tier: gen_irq_aggregator_v2 rewrites the priority encoder to
    # "lowest ID wins" (correct for hard/medium tier - both of THOSE
    # architecture docs say "lowest active source ID") but easy tier's
    # own doc says the OPPOSITE ("Priority encoder selects the highest
    # pending source, src7=highest"). A real regression was found this
    # way: t19_easy_test4 happened to fall through to the organizer's
    # original (correct-for-easy) generator, but t19_easy_test5's
    # identical ip_type spec DID match this interception and silently
    # flipped easy's priority order to the wrong convention - confirmed
    # directly by reading the generated irq_aggregator.v's own priority-
    # encoder logic in each case. The interception has no other
    # problem-specific behavior (hard/medium both want the v2 fix), so
    # this is the one place tier-awareness is actually needed.
    intercept_types = ("tilelink_router", "axi_lite_sram", "tilelink_ni", "aes128", "apb_fabric", "perf_counter")
    if problem != "easy":
        intercept_types = intercept_types + ("irq_aggregator",)
    if spec.get("ip_type") in intercept_types:
        # Use the corrected, verified generators instead of shelling out to
        # the organizer's ones - see module-level comment above. Imported
        # lazily (not at module load time) because these generators import
        # gen_utils.hdr from the organizer's rtl_gen_lib_dir, whose path is
        # only known once info.json has been read in main() - it is not
        # available yet at Python module-import time.
        ext_dir = str(Path(__file__).resolve().parent / "rtl_gen_lib_ext")
        if ext_dir not in sys.path:
            sys.path.insert(0, ext_dir)
        lib_dir = str(Path(rtl_gen_lib_dir).resolve())
        if lib_dir not in sys.path:
            sys.path.insert(0, lib_dir)

        if spec["ip_type"] == "tilelink_router":
            from gen_router_v2 import gen_tilelink_router_v2
            files = gen_tilelink_router_v2(spec)
        elif spec["ip_type"] == "axi_lite_sram":
            from gen_sram_v2 import gen_axi_lite_sram_v2
            files = gen_axi_lite_sram_v2(spec)
        elif spec["ip_type"] == "tilelink_ni":
            from gen_ni_v2 import gen_tilelink_ni_v2
            files = gen_tilelink_ni_v2(spec)
        elif spec["ip_type"] == "apb_fabric":
            from gen_apb_fabric_v2 import gen_apb_fabric_v2
            files = gen_apb_fabric_v2(spec)
        elif spec["ip_type"] == "irq_aggregator":
            from gen_irq_aggregator_v2 import gen_irq_aggregator_v2
            files = gen_irq_aggregator_v2(spec)
        elif spec["ip_type"] == "perf_counter":
            from gen_perf_counter_v2 import gen_perf_counter_v2
            files = gen_perf_counter_v2(spec)
        else:
            from gen_aes_v2 import gen_aes128_v2
            files = gen_aes128_v2(spec)
        out = Path(out_dir)
        out.mkdir(parents=True, exist_ok=True)
        generated = []
        for fname, content in files.items():
            fpath = out / fname
            fpath.write_text(content, encoding="utf-8")
            generated.append(str(fpath))
            print(f"[GEN-V2] {fpath} ({len(content):,} chars)", file=sys.stderr)
        print(f"[STEP3] {yaml_path.name} -> {generated} (via {spec['ip_type']}_v2)", file=sys.stderr)
        return generated

    gen_script = Path(rtl_gen_lib_dir) / "rtl_gen_main.py"
    if not gen_script.is_file():
        print(f"[ERROR] rtl_gen_main.py not found: {gen_script}", file=sys.stderr)
        return []
    try:
        result = subprocess.run(
            [sys.executable, str(gen_script), "--spec", str(yaml_path), "--outdir", str(out_dir)],
            capture_output=True, text=True, timeout=30, check=True,
        )
    except subprocess.CalledProcessError as e:
        print(f"[WARN] RTL gen failed for {yaml_path.name}: {e.stderr.strip()}", file=sys.stderr)
        return []
    except subprocess.TimeoutExpired:
        print(f"[WARN] RTL gen timed out for {yaml_path.name}", file=sys.stderr)
        return []

    # rtl_gen_main.py actually prints "[GEN] <fpath>  (<N> chars)" - no "->"
    # separator, despite AGENT_GUIDE.md's own example code (and the organizer's
    # vertexai_express_agent.py, copied from it) assuming an arrow format that
    # doesn't match. Parse the real format, and never let a parsing surprise
    # crash the run - the actual .v files are already written to out_dir by
    # rtl_gen_main.py regardless of whether this list is built correctly, and
    # Step 4 independently re-reads out_dir/*.v for module headers anyway.
    generated = []
    for line in result.stdout.splitlines():
        if not line.startswith("[GEN]"):
            continue
        try:
            fpath = line[len("[GEN]"):].rsplit("(", 1)[0].strip()
            if fpath:
                generated.append(fpath)
        except Exception:
            continue
    print(f"[STEP3] {yaml_path.name} -> {generated}", file=sys.stderr)
    return generated


# ---------------------------------------------------------------------------
# Main pipeline
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description="T19 NXP ICLAD 2026 agent (final)")
    parser.add_argument("info_json", help="Path to info.json produced by runner/run_benchmark.py")
    parser.add_argument("--model", default=None, help="Overrides info.json's model, if given")
    parser.add_argument("--max-retries", type=int, default=5)
    args = parser.parse_args()

    with open(args.info_json, encoding="utf-8") as f:
        info = json.load(f)

    if args.model:
        info["model"] = args.model
    model_name = info.get("model", "gemini-2.0-flash-exp")

    if not info.get("model_endpoint"):
        raise RuntimeError(
            "model_endpoint missing from info.json. Run via runner/run_benchmark.py "
            "(it starts scripts/model_service.py automatically), or pass "
            "--model-endpoint pointing at a running model service."
        )

    print(f"[INFO] T19 NXP final agent | problem={info['problem']} | model={model_name}", file=sys.stderr)
    print(f"[INFO] Endpoint: {info['model_endpoint']}", file=sys.stderr)

    out_dir = Path(info["output_dir"])
    out_dir.mkdir(parents=True, exist_ok=True)
    temp_dir = Path(info.get("temp_dir", out_dir))
    temp_dir.mkdir(parents=True, exist_ok=True)

    # --- Step 1: read inputs ---
    arch_path = Path(info["architecture_doc"])
    if not arch_path.exists() and arch_path.suffix == ".md":
        arch_path = arch_path.with_suffix(".html")
    raw_arch_doc = arch_path.read_text(encoding="utf-8")
    arch_doc_parsed = parse_architecture_html(raw_arch_doc)

    tb_skel = Path(info["tb_skeleton"]).read_text(encoding="utf-8")

    rtl_gen_lib_dir = Path(info.get("rtl_gen_lib", "rtl_gen_lib"))

    # --- Step 2: infer YAML specs (single combined call - see module docstring
    # for why this beats the per-section-call design tried in v18/v19) ---
    print("[STEP2] Inferring YAML specs for all IP blocks...", file=sys.stderr)

    prompt_yaml = f"""You are an expert System-on-Chip (SoC) architect analyzing parsed architecture
documentation to infer IP configurations for an RTL generation library.

Here is the parsed architecture documentation. It has been stripped of HTML bloat, but table data,
text content, and an explicitly extracted directed-graph topology (nodes and edges) are preserved:

{arch_doc_parsed}

Here are the STRICT, exact constraints required by the RTL generator library - you MUST use these
exact key names, and place them at the ROOT LEVEL of each YAML document (never nested under a
'parameters' or 'config' sub-dictionary):
{IP_CONSTRAINTS}

Task:
1. IDENTIFICATION: Check the '=== DELIVERABLES ===' section to identify exactly which IP blocks
   need to be generated.
2. INFERENCE: Read the '--- CONTENT ---' and '=== LOCALLY EXTRACTED DIRECTED GRAPHS ===' sections.
   The nodes and directed edges (e.g. A->B) dictate the parameter topology (fifo depth, timeout
   cycles, address ranges, cascade chains).
3. TABLE VERIFICATION: Cross-reference your deductions with the '--- REGISTER MAP ---' tables.
4. SCHEMA ALIGNMENT: Map inferred values to the EXACT required keys from the constraints list above.
5. Output ONE ```yaml ... ``` block for EVERY IP block identified in the deliverables (do NOT emit
   a YAML for the top-level SoC wrapper itself). Keep each YAML minimal and precise - only the
   required/optional keys from the constraints list, plus `ip_type` and `name`.
"""
    yaml_response = call_model(
        info["model_endpoint"], prompt_yaml, model_name,
        max_tokens=4096, max_retries=args.max_retries,
        diagnostics_path=temp_dir / "yaml_inference_diagnostics.json",
    )
    (temp_dir / "yaml_response.txt").write_text(yaml_response, encoding="utf-8")

    yaml_blocks = extract_yaml_blocks(yaml_response)
    print(f"[STEP2] Extracted {len(yaml_blocks)} YAML block(s)", file=sys.stderr)

    yaml_paths = []
    for i, block in enumerate(yaml_blocks):
        name_match = re.search(r'^name:\s*([a-zA-Z0-9_]+)', block, flags=re.MULTILINE)
        fname = f"spec_{i:02d}_{name_match.group(1).strip()}.yaml" if name_match else f"spec_{i:02d}.yaml"
        yaml_path = temp_dir / fname
        yaml_path.write_text(block, encoding="utf-8")
        yaml_paths.append(yaml_path)
        print(f"[STEP2] Saved {fname}", file=sys.stderr)

    fix_crossbar_s0_window(yaml_paths)

    # --- Step 3: generate IP RTL from YAML specs ---
    print("[STEP3] Generating IP RTL from YAML specs...", file=sys.stderr)
    generated_files = []
    for yaml_path in yaml_paths:
        generated_files.extend(rtl_gen_from_yaml(yaml_path, rtl_gen_lib_dir, out_dir, problem=info["problem"]))
    print(f"[STEP3] Total generated: {len(generated_files)} file(s)", file=sys.stderr)

    expected_ips = EXPECTED_IPS_BY_PROBLEM.get(info["problem"], [])
    missing = [ip for ip in expected_ips
               if not any(ip in Path(f).stem for f in generated_files)]
    if missing:
        print(f"[WARN] No generated file matched expected IP(s): {missing}", file=sys.stderr)

    mesh_path, mesh_internal_files = try_stitch_noc_mesh(yaml_paths, out_dir, rtl_gen_lib_dir)
    if mesh_path:
        generated_files.append(mesh_path)

    # --- Step 4: generate top-level SoC stitching module ---
    print("[STEP4] Generating top-level SoC Verilog...", file=sys.stderr)

    generated_headers = ""
    for v_file in sorted(out_dir.glob("*.v")):
        if v_file.name in mesh_internal_files:
            # Already fully wired inside noc_mesh.v - hide these individual
            # headers from the top-level prompt so the LLM instantiates only
            # the mesh wrapper, not 12+ routers/NIs/SRAMs by hand (see
            # NOC_MESH_WIRING_NOTE). The files still exist on disk and are
            # still compiled - they're just not shown in this prompt.
            continue
        try:
            content = v_file.read_text(encoding="utf-8")
            match = re.search(r'(module\s+.*?;\s*)', content, flags=re.DOTALL)
            if match:
                generated_headers += f"// From {v_file.name}:\n{match.group(1)}\n\n"
        except Exception:
            pass

    prompt_verilog = f"""You are an expert RTL Integration Engineer completing the top-level Verilog SoC
module for the NXP ICLAD 2026 {info['problem'].upper()} problem.

Here is the parsed architecture documentation, including the explicit directed-graph topology
(nodes and edges) of the SoC interconnect:
{arch_doc_parsed}

Here are the EXACT Verilog module headers for the IP blocks already generated. You MUST use these
exact module names and port definitions when instantiating them:
{generated_headers if generated_headers else "  (none generated - write minimal stub instances or inline logic as needed)"}

Here is the Testbench Skeleton, which dictates the EXACT port contract your top-level module must use:
{tb_skel}
{NOC_MESH_WIRING_NOTE if mesh_path else ""}
{SOC_CFG_WIRING_NOTE if info["problem"] == "hard" else ""}
Task:
1. Review the '=== LOCALLY EXTRACTED DIRECTED GRAPHS ===' section to understand the wiring: node
   descriptions explain what each block is, and edges explicitly dictate which port/IP connects
   to which.
2. Instantiate the IPs defined in the generated headers above.
3. Wire the IPs together exactly as defined by the graph edges (e.g. connect ahb_to_apb_bridge's
   AHB ports to the CPU-facing inputs, its APB ports to the APB fabric, route peripheral interrupts
   to the irq_aggregator, chain reset synchronizer stages).
4. Your top-level module name MUST match the testbench instantiation exactly.
5. Your top-level ports MUST match the testbench skeleton exactly.
6. Use only Verilog 2001 constructs (iverilog -g2005 compatible). No $clog2 in non-synthesis
   context - compute bit widths directly.
7. If any IP has a master or slave port that this design does not actually use (e.g. an
   axi_lite_crossbar master port with no real driver), you MUST tie off BOTH directions of it -
   every valid/request signal driven INTO it (e.g. awvalid/wvalid/arvalid - tie to 0) AND every
   ready/ready-like signal driven OUT of it that a real master would need to supply (e.g.
   bready/rready - tie to 1). Found via a real hang in a custom testbench (not elaboration -
   Icarus does not flag an undriven wire as an error, it silently reads as 'x' and can corrupt
   unrelated shared logic like round-robin arbitration): a prior generation correctly tied off
   the crossbar's OUTPUT side of an unused master port but forgot the INPUT side entirely,
   leaving it floating - this silently corrupted OTHER masters' own transactions once the
   crossbar's internal round-robin state advanced past its initial value.

Output STRICTLY the complete, synthesizable Verilog code inside one ```verilog ... ``` block.
Do not include long explanations outside the code block.
"""
    verilog_response = call_model(
        info["model_endpoint"], prompt_verilog, model_name,
        # medium/hard top-levels wire together 10-35+ IP instances (vs. easy's
        # flatter structure) and were observed truncating mid-file at 16384
        # (no closing ``` fence, cut off mid-instantiation) - hard's ~34-instance
        # SoC (4x3 NoC mesh + dual DMA/AES/IRQ + APB cluster + mailbox/perf) is
        # substantially bigger than medium, so use a large ceiling here too.
        max_tokens=65536, max_retries=args.max_retries,
        diagnostics_path=temp_dir / "soc_top_diagnostics.json",
    )
    (temp_dir / "soc_response.txt").write_text(verilog_response, encoding="utf-8")

    top_level_verilog = extract_verilog(verilog_response)
    if not top_level_verilog:
        print("[ERROR] Model failed to output Verilog for the top-level module.", file=sys.stderr)
        sys.exit(1)
    if ".hprot(" in top_level_verilog:
        top_level_verilog = fix_ahb_bridge_hprot(top_level_verilog)
    if "u_cnt" in top_level_verilog:
        top_level_verilog = fix_perf_counter_hier_ref(top_level_verilog)
    if "mbox_wr_en" in top_level_verilog:
        top_level_verilog = fix_mbox_wr_en_pulse(top_level_verilog)
    if "u_mbox" in top_level_verilog:
        top_level_verilog = fix_mbox_rd_rst_n(top_level_verilog)
    if "u_perf" in top_level_verilog:
        top_level_verilog = fix_perf_paddr_rebase(top_level_verilog)
        top_level_verilog = fix_perf_event0_wiring(top_level_verilog)
    if "endmodule" not in top_level_verilog:
        # No closing fence AND no endmodule = the response was truncated
        # mid-file (hit max_output_tokens before finishing), not just missing
        # a fence marker. The file below WILL fail to compile - flagged loudly
        # here rather than silently shipping a guaranteed-broken top level.
        print("[ERROR] Top-level response has no 'endmodule' - looks truncated "
              "(hit max_output_tokens before finishing). Writing it anyway for "
              "inspection, but this file will not compile.", file=sys.stderr)

    # Name the file after the module the LLM actually wrote (must match the
    # tb_skeleton's DUT instantiation per the prompt above), not a hardcoded
    # easy-tier name - evaluate.py globs **/*.v and only module names matter
    # for compilation, but a correct filename keeps the output directory
    # readable across problem tiers.
    # Require '(' or '#' right after the identifier (real module declarations
    # only) - a bare \bmodule\s+(\w+) also matches prose like "top-level
    # module for the SoC" inside a leading `//` comment, which happened in
    # testing and produced a file named "for.v" instead of the real module.
    top_module_match = re.search(r'\bmodule\s+(\w+)\s*[(#]', top_level_verilog)
    top_module_name = top_module_match.group(1) if top_module_match else info["problem"] + "_soc_top"
    top_file_path = out_dir / f"{top_module_name}.v"
    top_file_path.write_text(top_level_verilog + "\n", encoding="utf-8")
    print(f"[DONE] Wrote top-level RTL to {top_file_path}", file=sys.stderr)
    print(f"[DONE] {len(generated_files) + 1} total Verilog file(s) in {out_dir}", file=sys.stderr)


if __name__ == "__main__":
    main()
