#!/usr/bin/env python3
"""Normalize JavaVFC commit metadata into unlabeled Java review candidates.

JavaVFC records contain vulnerability-fix commit diffs, but the downloaded
metadata does not provide independent line-level review findings.  This tool
therefore emits candidate metadata only: it never labels a commit positive,
never copies source snippets, and never treats the output as a gold dataset.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from collections import Counter
from pathlib import Path
from typing import Any


COMMIT_URL_RE = re.compile(
    r"https?://github\.com/([^/]+/[^/]+)/commit/([0-9a-f]{7,64})",
    re.IGNORECASE,
)
DIFF_PATH_RE = re.compile(r"^diff --git a/(.+) b/(.+)$")
HUNK_RE = re.compile(r"^@@ [^+]*\+(\d+)(?:,(\d+))? @@")


def parse_identity(commit_link: Any) -> tuple[str, str] | None:
    if not isinstance(commit_link, str):
        return None
    match = COMMIT_URL_RE.search(commit_link.strip())
    if not match:
        return None
    return match.group(1), match.group(2)


def changed_java_files(diff_raw: Any) -> tuple[list[str], list[int]]:
    if not isinstance(diff_raw, str):
        return [], []
    files: set[str] = set()
    hunk_lines: list[int] = []
    for raw_line in diff_raw.splitlines():
        match = DIFF_PATH_RE.match(raw_line)
        if match:
            for candidate in match.groups():
                candidate = candidate.strip()
                if candidate.endswith(".java"):
                    files.add(candidate)
            continue
        if raw_line.startswith("+++ b/") and raw_line.endswith(".java"):
            files.add(raw_line[6:])
            continue
        match = HUNK_RE.match(raw_line)
        if match:
            hunk_lines.append(int(match.group(1)))
    return sorted(files), sorted(set(hunk_lines))


def message_hints(message: Any) -> list[str]:
    text = str(message or "").lower()
    patterns = {
        "security": ("security", "secure", "cve", "vulnerability", "漏洞"),
        "authorization": ("auth", "permission", "privilege", "权限"),
        "concurrency": ("deadlock", "race", "concurrent", "lock", "并发", "死锁"),
        "resource-lifecycle": ("leak", "close", "timeout", "resource", "资源"),
        "input-validation": ("validation", "sanitize", "escape", "input", "校验"),
    }
    return sorted(name for name, words in patterns.items() if any(word in text for word in words))


def split_for(repository: str, commit: str) -> str:
    digest = hashlib.sha256(f"{repository}@{commit}".encode("utf-8")).digest()[0]
    if digest < 204:
        return "train"
    if digest < 230:
        return "dev"
    return "external-smoke"


def normalize(records: list[dict[str, Any]], limit: int | None) -> list[dict[str, Any]]:
    selected: list[dict[str, Any]] = []
    seen: set[tuple[str, str]] = set()
    for record in records:
        identity = parse_identity(record.get("commit_link"))
        if identity is None:
            continue
        repository, commit = identity
        key = (repository, commit)
        if key in seen:
            continue
        files, hunk_lines = changed_java_files(record.get("diff_raw"))
        if not files:
            continue
        seen.add(key)
        selected.append(
            {
                "id": f"javavfc:{repository}@{commit}",
                "source": {
                    "name": "JavaVFC metadata",
                    "url": "https://zenodo.org/records/13731781",
                },
                "license": "CC-BY-4.0 metadata/data; verify referenced repository licenses",
                "split": split_for(repository, commit),
                "repository": repository,
                "commit": commit,
                "language": "java",
                "task": "patch-candidate",
                "label_status": "pending-human-label",
                "message": str(record.get("message") or "").strip(),
                "diff_files": files,
                "changed_hunk_lines": hunk_lines,
                "root_cause_hints": message_hints(record.get("message")),
                "provenance": {
                    "commit_link": record.get("commit_link"),
                    "date": record.get("date"),
                    "author": record.get("author"),
                    "source_has_line_findings": False,
                },
            }
        )
        if limit is not None and len(selected) >= limit:
            break
    return selected


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="JavaVFC JSONL metadata")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--limit", type=int)
    args = parser.parse_args()
    if args.limit is not None and args.limit < 1:
        parser.error("--limit must be positive")
    try:
        records = [json.loads(line) for line in args.input.read_text(encoding="utf-8").splitlines() if line.strip()]
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"cannot read JavaVFC JSONL {args.input}: {exc}") from exc
    records = [record for record in records if isinstance(record, dict)]
    rows = normalize(records, args.limit)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")
    splits = Counter(row["split"] for row in rows)
    summary = ", ".join(f"{key}={value}" for key, value in sorted(splits.items()))
    print(f"wrote {len(rows)} unlabeled JavaVFC candidates; splits [{summary}]")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
