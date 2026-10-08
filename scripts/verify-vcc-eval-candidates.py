#!/usr/bin/env python3
"""Verify VCC-Eval introduction-line metadata against local Git mirrors.

The verifier is intentionally offline and read-only.  A repository path must
be supplied through a private JSON map keyed by the candidate's canonical
repository.  It never fetches remotes, applies patches, or promotes a row to a
gold label; the result is evidence for a later human decision.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
from collections import Counter
from pathlib import Path
from typing import Any


HUNK_RE = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")


def run_git(repo: Path, *args: str) -> tuple[int, str, str]:
    env = os.environ.copy()
    env.update({"GIT_CONFIG_NOSYSTEM": "1", "GIT_OPTIONAL_LOCKS": "0"})
    try:
        completed = subprocess.run(
            ["git", *args],
            cwd=repo,
            env=env,
            check=False,
            capture_output=True,
            text=True,
            timeout=20,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 1, "", str(exc)
    return completed.returncode, completed.stdout, completed.stderr


def added_lines(diff: str) -> set[int]:
    """Return exact new-file lines represented by `+` diff records."""
    lines: set[int] = set()
    current: int | None = None
    for raw in diff.splitlines():
        hunk = HUNK_RE.match(raw)
        if hunk:
            current = int(hunk.group(1))
            continue
        if current is None or raw.startswith("\\ No newline"):
            continue
        if raw.startswith("+++"):
            continue
        if raw.startswith("+"):
            lines.add(current)
            current += 1
        elif raw.startswith("-"):
            continue
        else:
            current += 1
    return lines


def candidate_lines(row: dict[str, Any]) -> dict[str, set[int]]:
    result: dict[str, set[int]] = {}
    for path, ranges in row.get("introducing_lines", {}).items():
        lines: set[int] = set()
        for item in ranges:
            if not isinstance(item, dict):
                continue
            start, end = item.get("start"), item.get("end")
            if isinstance(start, int) and isinstance(end, int) and start >= 1 and end >= start:
                lines.update(range(start, end + 1))
        if lines:
            result[path] = lines
    return result


def verify_row(row: dict[str, Any], repo_map: dict[str, str]) -> tuple[str, dict[str, Any]]:
    evidence = dict(row.get("verification") or {})
    repo_value = row.get("repository")
    repo_path_raw = repo_map.get(repo_value) if isinstance(repo_value, str) else None
    if not repo_path_raw:
        return "missing-local-repo", {"status": "missing-local-repo"}
    repo = Path(repo_path_raw)
    if not repo.is_dir():
        return "missing-local-repo", {"status": "missing-local-repo", "repo": str(repo)}
    line_map = candidate_lines(row)
    if not line_map:
        return "missing-introducing-lines", {"status": "missing-introducing-lines"}
    commit = str(row.get("commit") or "")
    parents_rc, parents_out, parents_err = run_git(repo, "rev-list", "--parents", "-n", "1", commit)
    if parents_rc != 0:
        return "commit-unavailable", {"status": "commit-unavailable", "detail": parents_err.strip()[-300:]}
    parent_parts = parents_out.strip().split()
    if len(parent_parts) != 2:
        return "unsupported-merge-commit", {"status": "unsupported-merge-commit", "parent_count": max(len(parent_parts) - 1, 0)}
    parent = parent_parts[1]
    for path, wanted in line_map.items():
        diff_rc, diff, diff_err = run_git(
            repo,
            "--no-pager",
            "-c",
            "core.quotepath=false",
            "diff",
            "--no-ext-diff",
            "--unified=0",
            parent,
            commit,
            "--",
            path,
        )
        if diff_rc != 0:
            return "diff-unavailable", {"status": "diff-unavailable", "path": path, "detail": diff_err.strip()[-300:]}
        added = added_lines(diff)
        if not wanted.issubset(added):
            return "line-not-added", {
                "status": "line-not-added",
                "path": path,
                "missing_lines": sorted(wanted - added),
                "added_lines": sorted(added),
            }
        show_rc, source, show_err = run_git(repo, "show", f"{commit}:{path}")
        if show_rc != 0:
            return "source-unavailable", {"status": "source-unavailable", "path": path, "detail": show_err.strip()[-300:]}
        line_count = len(source.splitlines())
        if max(wanted) > line_count:
            return "line-out-of-range", {
                "status": "line-out-of-range",
                "path": path,
                "max_requested": max(wanted),
                "line_count": line_count,
            }
    return "verified-intro-lines", {
        "status": "verified-intro-lines",
        "parent": parent,
        "files": sorted(line_map),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="VCC-Eval candidate JSONL")
    parser.add_argument("--repo-map", required=True, type=Path, help="private JSON map canonical repository to local path")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        rows = [json.loads(line) for line in args.input.read_text(encoding="utf-8").splitlines() if line.strip()]
        repo_map = json.loads(args.repo_map.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"cannot read VCC-Eval verification input: {exc}") from exc
    if not isinstance(repo_map, dict):
        raise SystemExit("--repo-map must contain a JSON object")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    counts: Counter[str] = Counter()
    with args.output.open("w", encoding="utf-8") as handle:
        for row in rows:
            if not isinstance(row, dict):
                continue
            status, evidence = verify_row(row, repo_map)
            counts[status] += 1
            enriched = dict(row)
            enriched["verification"] = evidence
            enriched["label_status"] = "pending-human-label"
            enriched["verified_candidate"] = status == "verified-intro-lines"
            handle.write(json.dumps(enriched, ensure_ascii=False) + "\n")
    summary = ", ".join(f"{key}={value}" for key, value in sorted(counts.items())) or "none"
    print(f"verified {sum(counts.values())} VCC-Eval candidates; statuses [{summary}]")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
