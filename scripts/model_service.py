#!/usr/bin/env python3
"""
T19 NXP ICLAD 2026 — Local Vertex AI Express Mode model service
==================================================================
Implements the exact model_endpoint HTTP contract described in the official
AGENT_GUIDE.md (POST /generate, GET /health) so the agent in
agent/t19_nxp_agent_final.py can be tested end-to-end before relying on
whatever model_endpoint the organizers provide at judging time.

This is intentionally run standalone (not auto-discovered by
runner/run_benchmark.py, which only looks for a script literally named
scripts/model_service.py *inside* the ICLAD26-NXP-Problems checkout) so that
nothing needs to be placed inside the official hackathon repo. Start this
first, then pass its URL to run_benchmark.py via --model-endpoint.

Usage:
    export EXPRESS_MODE_KEY="your_actual_api_key_here"
    python3 scripts/model_service.py --port 8080

    # In another terminal:
    python3 <NXP-Problems repo>/runner/run_benchmark.py --problem easy \\
        --agent agent/t19_nxp_agent_final.py \\
        --model gemini-2.0-flash-exp \\
        --model-endpoint http://127.0.0.1:8080 \\
        --run-id t19_final_v1
"""

import argparse
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

try:
    from google import genai
    from google.genai import types
except ImportError:
    genai = None
    types = None

# Lightweight .env loader (no extra dependency) so EXPRESS_MODE_KEY can be
# provided once via a file instead of exporting it in every shell that runs this.
_env_file = Path(__file__).resolve().parent.parent / ".env"
if _env_file.exists():
    for _line in _env_file.read_text(encoding="utf-8").splitlines():
        _line = _line.strip()
        if not _line or _line.startswith("#") or "=" not in _line:
            continue
        _key, _, _value = _line.partition("=")
        os.environ.setdefault(_key.strip(), _value.strip().strip('"').strip("'"))


class GeminiVertexWrapper:
    """Vertex AI Express Mode wrapper - same pattern as
    T19-Caltech-NVIDIA-Submission/src/agent.py's GeminiVertexWrapper."""

    def __init__(self):
        self.api_key = os.environ.get("EXPRESS_MODE_KEY")
        if not self.api_key:
            print("[WARN] EXPRESS_MODE_KEY environment variable not set.", file=sys.stderr)
        if genai is None:
            raise RuntimeError("google-genai is not installed. Run: pip install google-genai")
        self.client = genai.Client(
            vertexai=True,
            api_key=self.api_key,
            http_options={"headers": {"X-Goog-User-Project": ""}},
        )

    def generate(self, model, prompt, max_output_tokens=8192):
        # Gemini 2.5's internal "thinking" step draws from the SAME token
        # budget as visible output text - with a modest max_output_tokens,
        # thinking alone can exhaust it and finish_reason=MAX_TOKENS fires
        # with barely any real text produced. Disable thinking for this
        # structured-generation task (also cheaper/faster, which helps the
        # token-cost efficiency score) via thinking_budget=0.
        config = types.GenerateContentConfig(
            max_output_tokens=max_output_tokens,
            thinking_config=types.ThinkingConfig(thinking_budget=0),
            safety_settings=[
                types.SafetySetting(category="HARM_CATEGORY_HATE_SPEECH", threshold="BLOCK_NONE"),
                types.SafetySetting(category="HARM_CATEGORY_HARASSMENT", threshold="BLOCK_NONE"),
                types.SafetySetting(category="HARM_CATEGORY_SEXUALLY_EXPLICIT", threshold="BLOCK_NONE"),
                types.SafetySetting(category="HARM_CATEGORY_DANGEROUS_CONTENT", threshold="BLOCK_NONE"),
            ],
        )
        response = self.client.models.generate_content(model=model, contents=prompt, config=config)

        usage = {}
        if getattr(response, "usage_metadata", None):
            usage = {
                "prompt_tokens": response.usage_metadata.prompt_token_count,
                "completion_tokens": response.usage_metadata.candidates_token_count,
                "total_tokens": (response.usage_metadata.prompt_token_count or 0)
                                + (response.usage_metadata.candidates_token_count or 0),
            }
        if getattr(response, "candidates", None):
            reason = getattr(response.candidates[0], "finish_reason", None)
            usage["finish_reason"] = str(reason) if reason is not None else None
            if reason is not None and str(reason) not in ("STOP", "FinishReason.STOP"):
                print(f"[model_service] [WARN] Non-STOP finish_reason: {reason}", file=sys.stderr, flush=True)
        return response.text or "", usage


_lock = threading.Lock()
_state = {"client": None, "usage_path": None, "total_tokens": 0, "model_calls": 0}


def _accumulate_usage(usage):
    if not _state["usage_path"]:
        return
    with _lock:
        _state["total_tokens"] += usage.get("total_tokens", 0)
        _state["model_calls"] += 1
        payload = {
            "total_tokens": _state["total_tokens"],
            "model_calls": _state["model_calls"],
        }
        usage_path = Path(_state["usage_path"])
        usage_path.parent.mkdir(parents=True, exist_ok=True)
        usage_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *a):
        print(f"[model_service] {fmt % a}", file=sys.stderr)

    def _send_json(self, status, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self._send_json(200, {"status": "ok"})
        else:
            self._send_json(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/generate":
            self._send_json(404, {"error": "not found"})
            return

        length = int(self.headers.get("Content-Length", 0))
        try:
            req = json.loads(self.rfile.read(length).decode("utf-8"))
            model = req["model"]
            prompt = req["prompt"]
            max_tokens = req.get("max_output_tokens", 8192)
        except Exception as e:
            self._send_json(400, {"error": f"bad request: {e}", "retryable": False})
            return

        try:
            text, usage = _state["client"].generate(model, prompt, max_tokens)
            _accumulate_usage(usage)
            self._send_json(200, {"text": text, "diagnostics": usage})
        except Exception as e:
            status = getattr(e, "code", 500)
            retryable = status in (429, 500, 502, 503, 504)
            self._send_json(
                status if isinstance(status, int) and 400 <= status < 600 else 500,
                {"error": str(e), "retryable": retryable, "provider": "vertexai"},
            )


def main():
    parser = argparse.ArgumentParser(description="Local model_endpoint service for NXP agent testing")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--model", default="gemini-2.0-flash-exp", help="Unused (client passes model per-call); kept for CLI parity with run_benchmark.py's auto-spawn args")
    parser.add_argument("--run-id", default=None, help="Unused unless --usage-path is also omitted and NXP_REPO_ROOT is set")
    parser.add_argument("--problem", default=None, help="Unused unless --usage-path is also omitted and NXP_REPO_ROOT is set")
    parser.add_argument("--usage-path", default=None,
                         help="Where to write accumulated token usage JSON (matches info.json's usage_path)")
    args = parser.parse_args()

    _state["client"] = GeminiVertexWrapper()
    _state["usage_path"] = args.usage_path

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"[model_service] Listening on http://127.0.0.1:{args.port}", file=sys.stderr)
    print(f"[model_service] GET  /health", file=sys.stderr)
    print(f"[model_service] POST /generate", file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
