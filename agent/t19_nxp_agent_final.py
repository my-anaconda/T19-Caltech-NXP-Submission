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
- axi_lite_crossbar: Requires [name]

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

# The 8 IP blocks the EASY problem's architecture.html always requires
# (per AGENT_GUIDE.md / README.md's "IP Blocks" list). Used only to sanity-log
# what's missing after YAML inference - does not force generation.
EASY_EXPECTED_IPS = [
    "reset_sync", "ahb_to_apb_bridge", "apb_fabric", "apb_uart",
    "apb_gpio", "apb_timer", "apb_watchdog", "irq_aggregator",
]


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
    if not llm_output:
        return ""
    pattern = r"`" * 3 + r"(?:verilog|systemverilog|v)?\s*(.*?)\s*" + r"`" * 3
    match = re.search(pattern, llm_output, flags=re.DOTALL | re.IGNORECASE)
    return match.group(1).strip() if match else llm_output.strip()


def rtl_gen_from_yaml(yaml_path, rtl_gen_lib_dir, out_dir):
    """Call rtl_gen_main.py --spec <yaml> --outdir <dir>. Returns generated filenames."""
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

    # --- Step 3: generate IP RTL from YAML specs ---
    print("[STEP3] Generating IP RTL from YAML specs...", file=sys.stderr)
    generated_files = []
    for yaml_path in yaml_paths:
        generated_files.extend(rtl_gen_from_yaml(yaml_path, rtl_gen_lib_dir, out_dir))
    print(f"[STEP3] Total generated: {len(generated_files)} file(s)", file=sys.stderr)

    missing = [ip for ip in EASY_EXPECTED_IPS
               if not any(ip in Path(f).stem for f in generated_files)]
    if missing:
        print(f"[WARN] No generated file matched expected IP(s): {missing}", file=sys.stderr)

    # --- Step 4: generate top-level SoC stitching module ---
    print("[STEP4] Generating top-level SoC Verilog...", file=sys.stderr)

    generated_headers = ""
    for v_file in sorted(out_dir.glob("*.v")):
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

Output STRICTLY the complete, synthesizable Verilog code inside one ```verilog ... ``` block.
Do not include long explanations outside the code block.
"""
    verilog_response = call_model(
        info["model_endpoint"], prompt_verilog, model_name,
        max_tokens=16384, max_retries=args.max_retries,
        diagnostics_path=temp_dir / "soc_top_diagnostics.json",
    )
    (temp_dir / "soc_response.txt").write_text(verilog_response, encoding="utf-8")

    top_level_verilog = extract_verilog(verilog_response)
    if not top_level_verilog:
        print("[ERROR] Model failed to output Verilog for the top-level module.", file=sys.stderr)
        sys.exit(1)

    top_file_path = out_dir / "secure_periph_soc.v"
    top_file_path.write_text(top_level_verilog + "\n", encoding="utf-8")
    print(f"[DONE] Wrote top-level RTL to {top_file_path}", file=sys.stderr)
    print(f"[DONE] {len(generated_files) + 1} total Verilog file(s) in {out_dir}", file=sys.stderr)


if __name__ == "__main__":
    main()
