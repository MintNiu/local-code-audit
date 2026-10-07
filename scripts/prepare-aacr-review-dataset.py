#!/usr/bin/env python3
"""Normalize AACR-Bench human review comments for private external smoke runs.

The source repository contains both human and LLM-enhanced comments.  This
converter keeps only ``is_ai_comment == false`` by default, because enhanced
comments are not independent human gold.  It emits review-comment records for
the repository's license-aware external-dataset validator; it never downloads
the source data or copies repository source code.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any


PR_RE = re.compile(r"github\.com/([^/]+)/([^/]+)/pull/\d+", re.IGNORECASE)


def repository_from_url(url: Any) -> str | None:
    if not isinstance(url, str):
        return None
    match = PR_RE.search(url)
    return f"{match.group(1)}/{match.group(2)}" if match else None


def slug(value: Any) -> str:
    text = str(value or "unknown").strip().lower()
    text = re.sub(r"[^a-z0-9]+", "-", text).strip("-")
    return text or "unknown"


def load_records(path: Path) -> list[dict[str, Any]]:
    try:
        records = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"cannot read AACR JSON {path}: {exc}") from exc
    if not isinstance(records, list):
        raise SystemExit(f"AACR input must be a JSON array: {path}")
    return [record for record in records if isinstance(record, dict)]


def normalize(
    records: list[dict[str, Any]],
    source_name: str,
    source_url: str,
    license_name: str,
    split: str,
    limit_per_language: int | None,
) -> list[dict[str, Any]]:
    selected: list[dict[str, Any]] = []
    seen: set[str] = set()
    counts: Counter[str] = Counter()

    for record in records:
        repository = repository_from_url(record.get("githubPrUrl"))
        target_commit = str(record.get("target_commit") or "").strip()
        if not repository or not target_commit:
            continue
        language = str(record.get("project_main_language") or "unknown").strip().lower()
        for index, comment in enumerate(record.get("comments") or []):
            if not isinstance(comment, dict) or comment.get("is_ai_comment") is not False:
                continue
            note = str(comment.get("note") or "").strip()
            path = str(comment.get("path") or "").strip()
            start_line = comment.get("from_line")
            end_line = comment.get("to_line")
            if not note or not path or not isinstance(start_line, int) or start_line < 1:
                continue
            if end_line is None:
                end_line = start_line
            if not isinstance(end_line, int) or end_line < start_line:
                continue
            identity = "|".join(
                [repository, target_commit, path, str(start_line), str(end_line), note]
            )
            comment_id = hashlib.sha256(identity.encode("utf-8")).hexdigest()[:20]
            if comment_id in seen:
                continue
            if limit_per_language is not None and counts[language] >= limit_per_language:
                continue
            seen.add(comment_id)
            counts[language] += 1
            category = str(comment.get("category") or "review-comment").strip()
            selected.append(
                {
                    "id": f"aacr-bench:{comment_id}",
                    "source": {"name": source_name, "url": source_url},
                    "license": license_name,
                    "split": split,
                    "repository": repository,
                    "commit": target_commit,
                    "language": language,
                    "framework": "repository-level-review",
                    "task": "review-comment",
                    "label": "positive",
                    "root_causes": [slug(category)],
                    "reviewer_comment": note,
                    "review_location": {
                        "path": path,
                        "start_line": start_line,
                        "end_line": end_line,
                        "side": comment.get("side"),
                    },
                    "provenance": {
                        "source_record": index,
                        "is_ai_comment": False,
                        "category": category,
                        "context": comment.get("context"),
                    },
                }
            )
    return selected


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inputs", nargs="+", type=Path, help="AACR positive/negative JSON files")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--split", default="external-smoke")
    parser.add_argument("--limit-per-language", type=int)
    args = parser.parse_args()
    if args.limit_per_language is not None and args.limit_per_language < 1:
        parser.error("--limit-per-language must be positive")

    records: list[dict[str, Any]] = []
    for input_path in args.inputs:
        records.extend(load_records(input_path))
    rows = normalize(
        records,
        source_name="AACR-Bench v1.0 human comments",
        source_url="https://github.com/alibaba/aacr-bench",
        license_name="Apache-2.0 dataset repository; referenced project licenses retained",
        split=args.split,
        limit_per_language=args.limit_per_language,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")
    by_language = defaultdict(int)
    for row in rows:
        by_language[row["language"]] += 1
    summary = ", ".join(f"{key}={value}" for key, value in sorted(by_language.items()))
    print(f"wrote {len(rows)} AACR human review records to {args.output}; languages [{summary}]")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
