#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 -B - "$repo_root" <<'PY'
import copy
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(sys.argv[1])
SCRIPT = ROOT / "scripts/run-native-canary.py"
spec = importlib.util.spec_from_file_location("native_canary", SCRIPT)
canary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(canary)
MODEL = "fake-native:latest"
DIGEST = "a" * 64


class FakeOllama(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def respond(self, value, status=200):
        raw = value if isinstance(value, bytes) else json.dumps(value, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        try:
            self.wfile.write(raw)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        self.server.calls.append((self.path, None))
        if self.path == "/api/tags":
            self.respond({"models": [{"name": MODEL, "digest": DIGEST}]})
        elif self.path == "/api/version":
            self.respond({"version": "fake-no-inference"})
        elif self.path == "/api/ps":
            self.respond({"models": [{"digest": DIGEST, "runner": "observed-engine",
                                       "context_length": 16384}]})
        else:
            self.respond({"error": "unexpected endpoint"}, 404)

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        body = json.loads(raw)
        self.server.calls.append((self.path, body))
        if self.path == "/api/show":
            show = {"details": {"runner": "manifest-variant"}, "capabilities": ["completion"],
                    "thinking": None}
            if self.server.thinking_values is not None:
                show["thinking"] = {"values": self.server.thinking_values, "default": False}
            self.respond(show)
        elif self.path == "/api/generate":
            self.server.request_bytes.append(raw)
            number = len(self.server.request_bytes)
            mode = self.server.mode
            if mode == "timeout":
                time.sleep(0.6)
            if mode == "http-error":
                self.respond({"error": "controlled error"}, 500)
            elif mode == "invalid-json":
                self.respond(b'{"done":true,')
            elif mode == "redirect":
                self.send_response(302)
                self.send_header("Location", f"http://127.0.0.1:{self.server.server_port}/forbidden")
                self.send_header("Content-Length", "0")
                self.end_headers()
            else:
                # Invalid review prose is intentionally API-complete: the tool
                # must preserve it and must not pretend to score it as correct.
                native = "原样保留的任意回答\n" if mode == "complete" else "未发现阻塞问题"
                response = {"model": DIGEST, "response": native, "done": True,
                            "done_reason": "stop", "prompt_eval_count": 100, "eval_count": 10}
                if mode == "length" or (mode == "recover" and number in (1, 3)):
                    response["done_reason"] = "length"
                if mode == "done-false":
                    response["done"] = False
                if mode == "empty":
                    response["response"] = "  "
                if mode == "api-error":
                    response["error"] = "controlled error despite done=true"
                if mode == "wrong-model":
                    response["model"] = "b" * 64
                if mode == "missing-model":
                    del response["model"]
                self.respond(response)
        else:
            self.respond({"error": "unexpected endpoint"}, 404)


class NativeCanaryTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="native-canary-test-")
        self.base = Path(self.temp.name)
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), FakeOllama)
        self.server.calls = []
        self.server.request_bytes = []
        self.server.thinking_values = None
        self.server.mode = "complete"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temp.cleanup()

    def invoke(self, name="result", extra=(), expected=0, env=None):
        output = self.base / name
        command = [sys.executable, str(SCRIPT), "--model", MODEL,
                   "--out-dir", str(output), "--url", self.url, "--timeout", "3", *extra]
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, timeout=20, check=False, env=env)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return output, result

    def summary(self, output):
        return json.loads((output / "summary.json").read_text())

    def test_dataset_pairs_blinding_and_full_added_diff(self):
        fixtures, _ = canary.load_fixtures()
        self.assertEqual(len(fixtures), 16)
        self.assertEqual(len({item["group"] for item in fixtures}), 8)
        self.assertEqual(sum(item["gold"]["has_defect"] for item in fixtures), 8)
        self.assertEqual([item["id"] for item in fixtures],
                         [item["id"] for item in canary.load_fixtures()[0]])
        source_dataset = json.loads(canary.DATASET.read_text())
        self.assertNotEqual([item["id"] for item in fixtures],
                            [item["id"] for item in source_dataset["fixtures"]])
        self.assertNotIn("/Users/", canary.DATASET.read_text())
        for item in fixtures:
            peer = next(other for other in fixtures if other["group"] == item["group"] and other is not item)
            self.assertEqual(item["contract"], peer["contract"])
            self.assertEqual(item["source_path"], peer["source_path"])
            poisoned = copy.deepcopy(item)
            poisoned.update(id="PRIVATE_ID", variant="PRIVATE_VARIANT", group="PRIVATE_GROUP",
                            gold={"root_cause": "PRIVATE_GOLD", "primary_line": 999})
            prompt = canary.build_prompt(poisoned)
            self.assertNotIn("PRIVATE_", prompt)
            self.assertIn(item["contract"], prompt)
            reconstructed = "".join(line[1:] for line in prompt.splitlines(keepends=True)
                                    if line.startswith("+") and not line.startswith("+++"))
            self.assertEqual(reconstructed, item["source_code"])
            if item["gold"]["has_defect"]:
                self.assertGreater(item["gold"]["primary_line"], 0)
                self.assertLessEqual(item["gold"]["primary_line"], len(item["source_code"].splitlines()))

    def test_complete_means_api_only_and_preserves_native_text(self):
        output, result = self.invoke()
        summary = self.summary(output)
        self.assertEqual(summary["api_completed"], 16)
        self.assertEqual(summary["not_run"], 0)
        self.assertFalse(summary["thinking_sent"])
        self.assertEqual(len(self.server.request_bytes), 16)
        fixtures, _ = canary.load_fixtures()
        for row, fixture, raw in zip(summary["runs"], fixtures, self.server.request_bytes):
            case = output / f"case-{row['case']:02d}"
            request = json.loads(raw)
            self.assertEqual(raw, (case / "request.json").read_bytes())
            self.assertEqual(hashlib.sha256(raw).hexdigest(), row["request_sha256"])
            self.assertEqual(hashlib.sha256((case / "response.raw.json").read_bytes()).hexdigest(),
                             row["response_raw_sha256"])
            self.assertEqual(hashlib.sha256((case / "response.native.txt").read_bytes()).hexdigest(),
                             row["response_native_sha256"])
            self.assertTrue(row["model_identity_match"])
            self.assertEqual(request["model"], DIGEST)
            self.assertEqual(request["options"], canary.OPTIONS)
            self.assertEqual(request["prompt"], canary.build_prompt(fixture))
            self.assertNotIn("think", request)
            self.assertEqual((case / "response.native.txt").read_text(), "原样保留的任意回答\n")
            self.assertEqual(row["format_assessment"], "not_evaluated")
            self.assertEqual(row["semantic_assessment"], "unscored")
            self.assertEqual(row["observed_runtime"][0]["runner"], "observed-engine")
        self.assertIn("Semantic results remain unscored", result.stdout)
        self.assertEqual({path for path, _ in self.server.calls},
                         {"/api/tags", "/api/show", "/api/version", "/api/generate", "/api/ps"})

    def test_incomplete_stops_after_two_and_keeps_remaining_unscored(self):
        for mode in ("length", "done-false", "empty", "api-error", "http-error", "invalid-json", "redirect",
                     "wrong-model", "missing-model"):
            with self.subTest(mode=mode):
                self.server.mode = mode
                before = len(self.server.request_bytes)
                output, _ = self.invoke(name=mode, expected=1)
                summary = self.summary(output)
                self.assertEqual(len(self.server.request_bytes) - before, 2)
                self.assertEqual(summary["api_completed"], 0)
                self.assertEqual(summary["not_run"], 14)
                self.assertTrue(all(row["semantic_assessment"] == "unscored" for row in summary["runs"]))
                self.assertTrue((output / "case-01/response.raw.json").exists())
                self.assertFalse((output / "case-03").exists())
                if mode == "length":
                    self.assertEqual((output / "case-01/response.native.txt").read_text(), "未发现阻塞问题")
                if mode in ("wrong-model", "missing-model"):
                    self.assertFalse(summary["runs"][0]["model_identity_match"])
                    self.assertEqual(summary["runs"][0]["incomplete_reason"], "response_model_mismatch")
        self.assertNotIn("/forbidden", [path for path, _ in self.server.calls])

    def test_nonconsecutive_incomplete_does_not_stop(self):
        self.server.mode = "recover"
        output, _ = self.invoke(expected=1)
        summary = self.summary(output)
        self.assertEqual(summary["api_completed"], 14)
        self.assertEqual(summary["not_run"], 0)
        self.assertNotIn("stopped_reason", summary)

    def test_wall_clock_timeout(self):
        self.server.mode = "timeout"
        output, _ = self.invoke(extra=("--timeout", "0.15"), expected=1)
        summary = self.summary(output)
        self.assertEqual(summary["not_run"], 14)
        self.assertTrue(all(row["wall_seconds"] < 1 for row in summary["runs"][:2]))
        self.assertTrue(all(row["exit_code"] != 0 for row in summary["runs"][:2]))

    def test_local_install_required_without_download(self):
        output, result = self.invoke(extra=("--model", "not-installed:latest"), expected=2)
        self.assertFalse(output.exists())
        self.assertIn("exactly match an installed", result.stderr)
        self.assertEqual(self.server.calls, [("/api/tags", None)])

    def test_user_curl_config_cannot_add_requests_or_redirects(self):
        curl_config = self.base / "curl-config"
        curl_config.mkdir()
        (curl_config / ".curlrc").write_text(f'url="{self.url}/forbidden"\nlocation\n')
        self.invoke(env={**os.environ, "CURL_HOME": str(curl_config)})
        self.assertNotIn("/forbidden", [path for path, _ in self.server.calls])

    def test_thinking_uses_advertised_values_only(self):
        output, result = self.invoke(name="unsupported", extra=("--thinking", "false"), expected=2)
        self.assertFalse(output.exists())
        self.assertIn("thinking.values", result.stderr)
        self.server.thinking_values = [False, "low"]
        self.invoke(name="low", extra=("--thinking", "low"))
        self.assertTrue(all(json.loads(raw)["think"] == "low" for raw in self.server.request_bytes))
        self.server.request_bytes.clear()
        self.invoke(name="false", extra=("--thinking", "false"))
        self.assertTrue(all(json.loads(raw)["think"] is False for raw in self.server.request_bytes))
        before = len(self.server.request_bytes)
        self.invoke(name="bad-high", extra=("--thinking", "high"), expected=2)
        self.assertEqual(len(self.server.request_bytes), before)

    def test_output_directory_and_loopback_protection_before_network(self):
        existing = self.base / "existing"
        existing.mkdir()
        marker = existing / "keep"
        marker.write_text("unchanged")
        self.invoke(name="existing", expected=2)
        self.assertEqual(marker.read_text(), "unchanged")
        inside = ROOT / "native-canary-output-must-not-exist"
        self.assertFalse(inside.exists())
        self.invoke(extra=("--out-dir", str(inside)), expected=2)
        self.assertFalse(inside.exists())
        alias = self.base / "repo-link"
        alias.symlink_to(ROOT, target_is_directory=True)
        self.invoke(extra=("--out-dir", str(alias / inside.name)), expected=2)
        for value in ("https://127.0.0.1:11434", "http://localhost:11434", "http://example.com",
                      "http://192.0.2.1:11434", "http://127.0.0.1:0", "http://user@127.0.0.1:11434",
                      "http://127.0.0.1:11434/path", "http://127.0.0.1:11434?redirect=1"):
            self.invoke(extra=("--url", value), expected=2)
        self.assertEqual(self.server.calls, [])


unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
