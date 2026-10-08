#!/usr/bin/env python3
"""Normalize VCC-Eval Java vulnerability-introduction metadata.

VCC-Eval contains an introducing commit and manually curated source-line
locations, but its repository does not declare a reusable data license.  This
tool therefore emits metadata-only candidates.  It never downloads a source
repository, copies a patch, or turns an introduction line into a positive
review label.  A human must still verify the intro parent, diff hunk, trigger
evidence, and referenced repository license before a row can enter training or
an external holdout.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from collections import Counter
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


LINE_RANGE_RE = re.compile(r"^(\d+)(?:-(\d+))?$")


def canonical_repository(value: Any) -> str:
    """Collapse common GitHub/Apache mirrors for repository-level splitting."""
    raw = str(value or "").strip()
    parsed = urlparse(raw if "://" in raw else f"https://{raw}")
    host = parsed.netloc.lower()
    repo_path = parsed.path.strip("/").removesuffix(".git").lower()
    if host in {"gitbox.apache.org", "git-wip-us.apache.org"} and repo_path.startswith("repos/asf/"):
        return f"apache/{repo_path.removeprefix('repos/asf/')}"
    if host == "github.com" and repo_path.startswith("apache/"):
        return f"apache/{repo_path.removeprefix('apache/')}"
    if host == "github.com":
        return f"github.com/{repo_path}"
    return f"{host}/{repo_path}" if host else repo_path


def parse_line_ranges(value: Any) -> tuple[list[dict[str, int]], str]:
    """Parse VCC-Eval's `172`/`172-177;181` notation without guessing."""
    if not isinstance(value, str) or not value.strip():
        return [], "missing"
    ranges: list[dict[str, int]] = []
    for raw_part in value.split(";"):
        part = raw_part.strip()
        match = LINE_RANGE_RE.fullmatch(part)
        if not match:
            return [], "invalid"
        start = int(match.group(1))
        end = int(match.group(2) or match.group(1))
        if start < 1 or end < start:
            return [], "invalid"
        ranges.append({"start": start, "end": end})
    return ranges, "present"


def normalize_line_map(value: Any) -> tuple[dict[str, list[dict[str, int]]], str]:
    if not isinstance(value, dict):
        return {}, "missing"
    result: dict[str, list[dict[str, int]]] = {}
    statuses: set[str] = set()
    for raw_path, raw_lines in value.items():
        path = str(raw_path).strip().replace("\\", "/")
        if not path or path.startswith("/") or ".." in Path(path).parts:
            statuses.add("invalid")
            continue
        ranges, status = parse_line_ranges(raw_lines)
        statuses.add(status)
        if ranges and path.endswith(".java"):
            result[path] = ranges
    if "invalid" in statuses:
        return result, "invalid"
    if not result:
        return {}, "missing" if not statuses or statuses == {"missing"} else "non-java"
    return result, "present"


def split_for(repository: str, cve: str) -> str:
    digest = hashlib.sha256(f"{repository}@{cve}".encode("utf-8")).digest()[0]
    if digest < 204:
        return "train"
    if digest < 230:
        return "dev"
    return "external-smoke"


def normalize(records: list[dict[str, Any]], limit: int | None) -> tuple[list[dict[str, Any]], Counter[str]]:
    selected: list[dict[str, Any]] = []
    skipped: Counter[str] = Counter()
    seen: set[tuple[str, str, str]] = set()
    for record in records:
        cve = str(record.get("cve") or "").strip()
        cwe = str(record.get("cwe") or "").strip()
        repository_url = str(record.get("repository") or "").strip()
        introducing = str(record.get("introducing") or "").strip()
        if not cve or not repository_url or not introducing:
            skipped["missing-identity"] += 1
            continue
        repository = canonical_repository(repository_url)
        key = (repository, cve, introducing.lower())
        if key in seen:
            skipped["duplicate-lineage"] += 1
            continue
        seen.add(key)
        intro_lines, intro_status = normalize_line_map(record.get("introducing_lines"))
        fixing_lines, fixing_status = normalize_line_map(record.get("fixing_lines"))
        raw_fixing = record.get("fixing")
        fixing = (
            [str(item).strip() for item in raw_fixing if str(item).strip()]
            if isinstance(raw_fixing, list)
            else []
        )
        selected.append(
            {
                "id": f"vcc-eval:{repository}@{cve}@{introducing.lower()}",
                "source": {
                    "name": "VCC-Eval metadata",
                    "url": "https://zenodo.org/records/7574340",
                    "dataset_url": "https://github.com/tuhh-softsec/VCC-Eval-A-Manually-Curated-Dataset-of-Vulnerability-Introducing-Commits-in-Java",
                },
                "license": "UNKNOWN; dataset repository does not declare a reusable license; verify each referenced repository",
                "split": split_for(repository, cve),
                "repository": repository,
                "repository_url": repository_url,
                "commit": introducing,
                "language": "java",
                "task": "audit-candidate",
                "label_status": "pending-human-label",
                "cve": cve,
                "cwe": cwe,
                "fixing_commits": fixing,
                "introducing_lines": intro_lines,
                "fixing_lines": fixing_lines,
                "line_label_status": {
                    "introducing": intro_status,
                    "fixing": fixing_status,
                },
                "candidate_eligible": intro_status == "present",
                "provenance": {
                    "days_between": record.get("days_between"),
                    "intro_stats": record.get("intro_stats"),
                    "fixing_stats": record.get("fixing_stats"),
                    "source_has_intro_diff": False,
                    "requires_parent_diff_check": True,
                    "requires_human_trigger_check": True,
                },
            }
        )
        if limit is not None and len(selected) >= limit:
            break
    return selected, skipped


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="VCC-Eval JSON array")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--limit", type=int)
    args = parser.parse_args()
    if args.limit is not None and args.limit < 1:
        parser.error("--limit must be positive")
    try:
        payload = json.loads(args.input.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"cannot read VCC-Eval JSON {args.input}: {exc}") from exc
    if not isinstance(payload, list):
        raise SystemExit("VCC-Eval input must be a JSON array")
    rows, skipped = normalize([item for item in payload if isinstance(item, dict)], args.limit)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")
    splits = Counter(row["split"] for row in rows)
    summary = ", ".join(f"{key}={value}" for key, value in sorted(splits.items()))
    skipped_summary = ", ".join(f"{key}={value}" for key, value in sorted(skipped.items())) or "none"
    print(f"wrote {len(rows)} VCC-Eval candidates; skipped [{skipped_summary}]; splits [{summary}]")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
