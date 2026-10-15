#!/usr/bin/env python3
"""Blind development canary: native Ollama responses, never semantic pass/fail.

No model downloads, core-review filters, or automatic semantic scoring. Results
must be written to a new directory outside this checkout and reviewed manually.
"""

import argparse
import difflib
import hashlib
import ipaddress
import json
from pathlib import Path
import random
import re
import shutil
import subprocess
import sys
import time
from urllib.parse import urlsplit


ROOT = Path(__file__).resolve().parents[1]
DATASET = ROOT / "evals/native-canary.json"
SYSTEM = ROOT / "evals/native-review-system.txt"
OPTIONS = {
    "num_ctx": 16384, "num_predict": 4096, "temperature": 0,
    "seed": 42, "top_k": 40, "top_p": 0.9,
}


class CanaryError(Exception):
    """Configuration or read-only metadata validation failed."""


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def write_json(path, value):
    path.write_bytes(json_bytes(value))


def loopback_url(value):
    try:
        parsed = urlsplit(value)
        host = ipaddress.ip_address(parsed.hostname or "")
        port = 11434 if parsed.port is None else parsed.port
    except ValueError as exc:
        raise CanaryError("--url must use a literal loopback IP and valid port") from exc
    if (parsed.scheme != "http" or not host.is_loopback or
            parsed.username is not None or parsed.password is not None or
            parsed.path not in ("", "/") or parsed.query or parsed.fragment or
            not 1 <= port <= 65535):
        raise CanaryError("--url must be an HTTP loopback origin without credentials or paths")
    hostname = f"[{host}]" if host.version == 6 else str(host)
    return f"http://{hostname}:{port}"


def output_directory(value):
    requested = Path(value).expanduser()
    if requested.exists() or requested.is_symlink():
        raise CanaryError("--out-dir must not already exist; nothing will be overwritten")
    output = requested.resolve()
    if output == ROOT or ROOT in output.parents:
        raise CanaryError("--out-dir must be outside the public repository")
    if not output.parent.is_dir():
        raise CanaryError("--out-dir parent must already exist")
    return output


def load_fixtures():
    dataset_bytes = DATASET.read_bytes()
    dataset = json.loads(dataset_bytes)
    fixtures = dataset["fixtures"]
    if len(fixtures) != 16 or len({item["id"] for item in fixtures}) != 16:
        raise CanaryError("canary must contain exactly 16 uniquely identified cases")
    groups = {}
    for item in fixtures:
        path = Path(item["source_path"])
        if (path.as_posix() not in ("src/Main.java", "src/main.py", "src/main.js") or
                not item["source_code"].endswith("\n")):
            raise CanaryError("canary source path or complete-file newline is invalid")
        groups.setdefault(item["group"], []).append(item)
    if len(groups) != 8:
        raise CanaryError("canary must contain exactly 8 paired groups")
    for pair in groups.values():
        if (len(pair) != 2 or {item["variant"] for item in pair} != {"safe", "bug"} or
                len({item["contract"] for item in pair}) != 1 or
                len({item["source_path"] for item in pair}) != 1):
            raise CanaryError("paired cases must share the exact contract and display path")
    random.Random(42).shuffle(fixtures)
    return fixtures, sha256(dataset_bytes)


def build_prompt(fixture):
    # Deliberately project only these three fields; labels/IDs never reach Ollama.
    path = fixture["source_path"]
    diff = f"diff --git a/{path} b/{path}\nnew file mode 100644\n"
    diff += "".join(difflib.unified_diff(
        [], fixture["source_code"].splitlines(keepends=True),
        fromfile="/dev/null", tofile="b/" + path,
    ))
    return "Explicit project contract:\n" + fixture["contract"] + "\n\nActual changed source:\n" + diff


def api_request(origin, endpoint, body=None, timeout=10):
    # curl provides a wall-clock deadline, unlike a per-read socket timeout.
    # No proxy, redirects, shell expansion, pull, or implicit model resolution.
    command = ["curl", "--disable", "--silent", "--show-error", "--noproxy", "*",
               "--connect-timeout", str(min(5, timeout)), "--max-time", str(timeout),
               "--write-out", "\n%{http_code}", origin + endpoint]
    if body is not None:
        command += ["--header", "Content-Type: application/json", "--data-binary", "@-"]
    started = time.monotonic()
    try:
        result = subprocess.run(command, input=body, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=timeout + 2, check=False)
        raw, separator, status = result.stdout.rpartition(b"\n")
        http_status = int(status) if separator and re.fullmatch(rb"\d{3}", status) else None
        if http_status is None:
            raw = result.stdout
        return {"raw": raw, "stderr": result.stderr, "exit_code": result.returncode,
                "http_status": http_status, "wall_seconds": round(time.monotonic() - started, 3)}
    except subprocess.TimeoutExpired as exc:
        return {"raw": exc.stdout or b"", "stderr": exc.stderr or b"",
                "exit_code": 124, "http_status": None,
                "wall_seconds": round(time.monotonic() - started, 3)}


def metadata(origin, endpoint, body=None, timeout=10):
    result = api_request(origin, endpoint, None if body is None else json_bytes(body), timeout)
    if result["exit_code"] != 0 or result["http_status"] != 200:
        raise CanaryError(f"read-only {endpoint} failed: HTTP {result['http_status']}, "
                          f"transport exit {result['exit_code']}; no inference started")
    try:
        value = json.loads(result["raw"])
    except (ValueError, UnicodeError) as exc:
        raise CanaryError(f"read-only {endpoint} returned invalid JSON") from exc
    if not isinstance(value, dict) or "error" in value:
        raise CanaryError(f"read-only {endpoint} returned an invalid metadata object")
    return value


def thinking_value(requested, show):
    if requested is None:
        return None
    value = {"true": True, "false": False}.get(requested, requested)
    thinking = show.get("thinking")
    advertised = thinking.get("values", []) if isinstance(thinking, dict) else []
    if not isinstance(advertised, list):
        advertised = []
    if not any(type(value) is type(item) and value == item for item in advertised):
        raise CanaryError("--thinking is not advertised by /api/show thinking.values: "
                          f"requested {value!r}, supported {advertised!r}; omit it to use the model default")
    return value


def assess_completion(result, expected_model):
    """Transport/API completion only. No finding extraction or semantic grading."""
    row = {key: result[key] for key in ("exit_code", "http_status", "wall_seconds")}
    row.update(api_complete=False, format_assessment="not_evaluated", semantic_assessment="unscored")
    try:
        response = json.loads(result["raw"])
    except (ValueError, UnicodeError):
        row["incomplete_reason"] = "invalid_json"
        return row, None
    if not isinstance(response, dict):
        row["incomplete_reason"] = "invalid_response_object"
        return row, None
    reported_model = response.get("model")
    reported_digest = reported_model.removeprefix("sha256:").removeprefix("sha256-") if isinstance(reported_model, str) else None
    row.update(requested_model=expected_model, response_model=reported_model,
               model_identity_match=reported_digest == expected_model)
    native = response.get("response")
    if not isinstance(native, str):
        native = None
    for key in ("model", "done", "done_reason", "prompt_eval_count", "prompt_eval_cached_count",
                "eval_count", "total_duration", "load_duration"):
        if key in response:
            row[key] = response[key]
    if result["exit_code"] != 0 or result["http_status"] != 200:
        row["incomplete_reason"] = "transport_or_http_error"
    elif "error" in response:
        row["incomplete_reason"] = "api_error"
    elif not row["model_identity_match"]:
        row["incomplete_reason"] = "response_model_mismatch"
    elif response.get("done") is not True:
        row["incomplete_reason"] = "done_not_true"
    elif response.get("done_reason") != "stop":
        row["incomplete_reason"] = "non_stop_termination"
    elif native is None or not native.strip():
        row["incomplete_reason"] = "empty_final_response"
    else:
        row["api_complete"] = True
    return row, native


def run(args):
    origin = loopback_url(args.url)
    output = output_directory(args.out_dir)
    if not 0 < args.timeout <= 3600:
        raise CanaryError("--timeout must be greater than zero and at most 3600 seconds")
    if shutil.which("curl") is None:
        raise CanaryError("curl is required; no inference started")
    fixtures, dataset_hash = load_fixtures()
    system = SYSTEM.read_text(encoding="utf-8")
    timeout = min(10, args.timeout)
    tags = metadata(origin, "/api/tags", timeout=timeout).get("models", [])
    installed = [item for item in tags if args.model == item.get("name")]
    if len(installed) != 1:
        raise CanaryError("--model must exactly match an installed /api/tags name; no download or inference started")
    selected = installed[0]
    digest = selected.get("digest", "").removeprefix("sha256:")
    if not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise CanaryError("installed model metadata has no valid manifest digest")
    # Pin the installed artifact, avoiding tag drift/background conversion.
    show = metadata(origin, "/api/show", {"model": digest}, timeout)
    think = thinking_value(args.thinking, show)
    version = metadata(origin, "/api/version", timeout=timeout)
    output.mkdir(mode=0o700)  # Atomic refusal if another run created it meanwhile.
    write_json(output / "model.show.json", show)
    write_json(output / "model.selected.json", selected)
    rows = [{"case": i, "fixture_id": item["id"], "group": item["group"],
             "variant": item["variant"], "gold": item["gold"],
             "display_path": item["source_path"], "status": "not_run",
             "api_complete": False, "format_assessment": "not_evaluated",
             "semantic_assessment": "unscored"} for i, item in enumerate(fixtures, 1)]
    summary = {
        "schema_version": 1, "kind": "native-development-canary; not a holdout",
        "assessment": "API completion is not format validity or semantic correctness",
        "url": origin, "model_tag": args.model, "model_digest": digest,
        "server_version": version, "requested_options": OPTIONS,
        "thinking_sent": args.thinking is not None, "thinking": think,
        "timeout_seconds": args.timeout, "order_seed": 42,
        "dataset_sha256": dataset_hash, "system_sha256": sha256(system.encode()),
        "show_sha256": sha256(json_bytes(show)), "runs": rows,
    }
    (output / "system.txt").write_text(system, encoding="utf-8")
    summary_path = output / "summary.json"
    write_json(summary_path, summary)
    print(output, flush=True)
    consecutive_incomplete = 0
    for row, fixture in zip(rows, fixtures):
        case_dir = output / f"case-{row['case']:02d}"
        case_dir.mkdir()
        body = {"model": digest, "system": system, "prompt": build_prompt(fixture),
                "stream": False, "options": dict(OPTIONS), "keep_alive": "5m"}
        if args.thinking is not None:
            body["think"] = think
        request_bytes = json_bytes(body)
        (case_dir / "request.json").write_bytes(request_bytes)
        row.update(status="running", request_sha256=sha256(request_bytes))
        write_json(summary_path, summary)
        result = api_request(origin, "/api/generate", request_bytes, args.timeout)
        (case_dir / "response.raw.json").write_bytes(result["raw"])
        (case_dir / "transport.stderr.txt").write_bytes(result["stderr"])
        completion, native = assess_completion(result, digest)
        row.update(completion, status="completed" if completion["api_complete"] else "incomplete")
        row["response_raw_sha256"] = sha256(result["raw"])
        row["response_native_sha256"] = None
        if native is not None:
            native_bytes = native.encode("utf-8")
            (case_dir / "response.native.txt").write_bytes(native_bytes)
            row["response_native_sha256"] = sha256(native_bytes)
        # Observation, not a claim that the manifest runner is the actual engine.
        try:
            ps = metadata(origin, "/api/ps", timeout=timeout)
            write_json(case_dir / "runtime.ps.json", ps)
            row["observed_runtime"] = [item for item in ps.get("models", [])
                                       if item.get("digest", "").removeprefix("sha256:") == digest]
        except CanaryError as exc:
            row["runtime_observation_error"] = str(exc).replace("; no inference started", "")
        consecutive_incomplete = 0 if row["api_complete"] else consecutive_incomplete + 1
        print(f"case-{row['case']:02d}: api_complete={row['api_complete']}; "
              "format not evaluated; semantics unscored", flush=True)
        if consecutive_incomplete >= 2:
            summary["stopped_reason"] = "two consecutive incomplete responses; remaining cases not run/unscored"
            write_json(summary_path, summary)
            break
        write_json(summary_path, summary)
    summary["api_completed"] = sum(row["api_complete"] for row in rows)
    summary["not_run"] = sum(row["status"] == "not_run" for row in rows)
    write_json(summary_path, summary)
    print(f"API completed: {summary['api_completed']}/16. Semantic results remain unscored.", flush=True)
    return 0 if summary["api_completed"] == 16 else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True, help="exact locally installed tag from /api/tags")
    parser.add_argument("--out-dir", required=True, help="new directory outside this public checkout")
    parser.add_argument("--url", default="http://127.0.0.1:11434", help="literal loopback HTTP origin")
    parser.add_argument("--timeout", type=float, default=180, help="wall-clock seconds per inference request")
    parser.add_argument("--thinking", help="optional value advertised by /api/show; omitted by default")
    try:
        return run(parser.parse_args())
    except (CanaryError, OSError, ValueError, KeyError, TypeError) as exc:
        print(f"native canary failed: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
