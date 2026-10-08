#!/usr/bin/env python3
"""Normalize Vul4J CSV metadata into unlabeled Java review candidates.

Vul4J records identify a vulnerable version and a human patch, but the CSV does
not provide independent line-level review findings.  This tool therefore emits
candidate metadata only: it never turns a CVE/CWE into a positive label and
never copies repository source or patch text into the output.
"""

from __future__ import annotations

import argparse
import csv
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


def parse_identity(value: Any) -> tuple[str, str] | None:
    if not isinstance(value, str):
        return None
    match = COMMIT_URL_RE.search(value.strip())
    if not match:
        return None
    return match.group(1), match.group(2)


def split_for(repository: str, commit: str) -> str:
    digest = hashlib.sha256(f"{repository}@{commit}".encode("utf-8")).digest()[0]
    if digest < 204:
        return "train"
    if digest < 230:
        return "dev"
    return "external-smoke"


def non_empty(value: Any) -> str | None:
    text = str(value or "").strip()
    return text or None


def root_cause_hints(row: dict[str, str]) -> list[str]:
    hints: list[str] = []
    cwe = non_empty(row.get("cwe_id"))
    cwe_name = non_empty(row.get("cwe_name"))
    if cwe and cwe.lower() != "not mapping":
        hints.append(cwe)
    if cwe_name and cwe_name.lower() != "not mapping":
        hints.append(cwe_name)
    return hints


def normalize(rows: list[dict[str, str]], limit: int | None) -> tuple[list[dict[str, Any]], int]:
    selected: list[dict[str, Any]] = []
    skipped = 0
    seen: set[tuple[str, str]] = set()
    for row in rows:
        identity = parse_identity(row.get("human_patch"))
        if identity is None:
            skipped += 1
            continue
        repository, commit = identity
        key = (repository, commit)
        if key in seen:
            skipped += 1
            continue
        seen.add(key)

        record: dict[str, Any] = {
            "id": f"vul4j:{repository}@{commit}",
            "source": {
                "name": "Vul4J metadata",
                "url": "https://github.com/tuhh-softsec/Vul4J",
            },
            "license": "CC-BY-4.0 metadata/data; verify referenced repository licenses",
            "split": split_for(repository, commit),
            "repository": repository,
            "commit": commit,
            "language": "java",
            "task": "patch-candidate",
            "label_status": "pending-human-label",
            "message": non_empty(row.get("cve_id")) or "",
            "root_cause_hints": root_cause_hints(row),
            "provenance": {
                "vul_id": non_empty(row.get("vul_id")) or non_empty(row.get("no")),
                "cve_id": non_empty(row.get("cve_id")),
                "cwe_id": non_empty(row.get("cwe_id")),
                "cwe_name": non_empty(row.get("cwe_name")),
                "repo_slug": non_empty(row.get("repo_slug")),
                "human_patch": row.get("human_patch"),
                "source_has_line_findings": False,
            },
        }
        for key_name in ("src", "src_classes", "failing_module", "failing_tests"):
            value = non_empty(row.get(key_name))
            if value:
                record[key_name] = value
        selected.append(record)
        if limit is not None and len(selected) >= limit:
            break
    return selected, skipped


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="Vul4J CSV metadata")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--limit", type=int)
    args = parser.parse_args()
    if args.limit is not None and args.limit < 1:
        parser.error("--limit must be positive")
    try:
        with args.input.open(newline="", encoding="utf-8") as handle:
            rows = list(csv.DictReader(handle))
    except (OSError, csv.Error, UnicodeError) as exc:
        raise SystemExit(f"cannot read Vul4J CSV {args.input}: {exc}") from exc
    candidates, skipped = normalize(rows, args.limit)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as handle:
        for candidate in candidates:
            handle.write(json.dumps(candidate, ensure_ascii=False) + "\n")
    splits = Counter(row["split"] for row in candidates)
    summary = ", ".join(f"{key}={value}" for key, value in sorted(splits.items()))
    print(
        f"wrote {len(candidates)} unlabeled Vul4J candidates; "
        f"skipped={skipped}; splits [{summary}]"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
