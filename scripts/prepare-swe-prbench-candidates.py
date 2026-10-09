#!/usr/bin/env python3
"""Normalize SWE-PRBench PR metadata without importing review gold.

SWE-PRBench contains human review comments, diffs, and pre-built contexts.  A
candidate index is deliberately metadata-only: source, patch, context, and
comment text stay in the private license-reviewed workspace, while every row
remains pending until its file/line evidence and severity are independently
confirmed.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from collections import Counter
from pathlib import Path
from typing import Any, Iterable
from urllib.parse import urlparse


SHA_RE = re.compile(r"^[0-9a-fA-F]{40}$")
TASK_ID_RE = re.compile(r"^(?P<repo>.+)__(?P<number>[0-9]+)$")
ALLOWED_SPLITS = {"external-smoke", "train", "dev", "holdout"}


def canonical_repository(value: Any) -> str:
    raw = str(value or "").strip()
    if not raw:
        return ""
    if "://" not in raw and raw.count("/") == 1:
        return f"github.com/{raw.removesuffix('.git').lower()}"
    parsed = urlparse(raw if "://" in raw else f"https://{raw}")
    host = parsed.netloc.lower()
    path = parsed.path.strip("/").removesuffix(".git").lower()
    if host == "github.com":
        return f"github.com/{path}" if path else ""
    return f"{host}/{path}" if host and path else host or path


def first(record: dict[str, Any], *keys: str) -> Any:
    for key in keys:
        value = record.get(key)
        if value not in (None, ""):
            return value
    return None


def integer(value: Any, *, minimum: int = 0) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int) and value >= minimum:
        return value
    if isinstance(value, str) and value.strip().isdigit():
        parsed = int(value.strip())
        return parsed if parsed >= minimum else None
    return None


def decimal(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return None
    return parsed if parsed == parsed else None


def records_from_jsonl(path: Path) -> Iterable[dict[str, Any]]:
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise SystemExit(f"cannot read SWE-PRBench input {path}: {exc}") from exc
    stripped = raw.lstrip()
    # The official file is JSONL.  Accept a JSON array or a one-line wrapper
    # for fixtures, but do not mistake the first JSONL object for the whole
    # document (json.loads would report "Extra data" on line two).
    non_empty_lines = [line for line in raw.splitlines() if line.strip()]
    if stripped.startswith("[") or (
        stripped.startswith("{") and len(non_empty_lines) == 1
    ):
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise SystemExit(f"invalid SWE-PRBench JSON {path}: {exc}") from exc
        if isinstance(payload, list):
            for item in payload:
                if isinstance(item, dict):
                    yield item
            return
        if isinstance(payload, dict):
            for key in ("prs", "records", "items", "data"):
                candidate = payload.get(key)
                if isinstance(candidate, list):
                    for item in candidate:
                        if isinstance(item, dict):
                            yield item
                    return
            if "task_id" in payload or "repo" in payload:
                yield payload
                return
        raise SystemExit(f"SWE-PRBench JSON has no supported record list: {path}")
    for line_no, line in enumerate(raw.splitlines(), 1):
        if not line.strip():
            continue
        try:
            item = json.loads(line)
        except json.JSONDecodeError as exc:
            raise SystemExit(f"invalid SWE-PRBench JSONL line {line_no}: {exc}") from exc
        if isinstance(item, dict):
            yield item


def normalize(
    records: Iterable[dict[str, Any]],
    *,
    revision: str,
    split: str,
    languages: set[str] | None,
) -> tuple[list[dict[str, Any]], Counter[str]]:
    rows: list[dict[str, Any]] = []
    skipped: Counter[str] = Counter()
    seen: set[str] = set()

    for record in records:
        task_id = str(first(record, "task_id", "id") or "").strip()
        task_match = TASK_ID_RE.fullmatch(task_id)
        repository = canonical_repository(first(record, "repo", "repository", "nwo"))
        if not repository and task_match:
            repository = canonical_repository(task_match.group("repo"))
        pr_number = integer(first(record, "pr_number", "pull_request"), minimum=1)
        if pr_number is None and task_match:
            pr_number = int(task_match.group("number"))
        base = str(first(record, "base_commit", "base", "base_sha") or "").strip()
        head = str(first(record, "head_commit", "head", "head_sha") or "").strip()
        language = str(first(record, "language", "lang") or "").strip().lower()
        pr_url = str(first(record, "pr_url", "pull_request_url", "url") or "").strip()
        if not repository or pr_number is None:
            skipped["missing-repository-or-pr"] += 1
            continue
        if not SHA_RE.fullmatch(base) or not SHA_RE.fullmatch(head):
            skipped["invalid-base-or-head"] += 1
            continue
        if not language:
            skipped["missing-language"] += 1
            continue
        if languages and language not in languages:
            skipped["language-filter"] += 1
            continue
        if pr_url and urlparse(pr_url).netloc.lower() != "github.com":
            skipped["non-github-pr-url"] += 1
            continue
        identity = f"{repository}#{pr_number}@{base.lower()}..{head.lower()}"
        if identity in seen:
            skipped["duplicate-pr-lineage"] += 1
            continue
        seen.add(identity)
        digest = hashlib.sha256(identity.encode("utf-8")).hexdigest()[:20]
        rows.append(
            {
                "id": f"swe-prbench:{digest}",
                "source": {
                    "name": "SWE-PRBench prs.jsonl",
                    "url": "https://huggingface.co/datasets/foundry-ai/swe-prbench",
                    "revision": revision,
                    "file": "dataset/prs.jsonl",
                },
                "license": "CC BY 4.0 dataset; referenced repositories and review comments require separate audit",
                "split": split,
                "repository": repository,
                "repository_url": pr_url,
                "task_id": task_id,
                "pr_number": pr_number,
                "base_commit": base.lower(),
                "head_commit": head.lower(),
                "commit": head.lower(),
                "language": language,
                "task": "review-candidate",
                "label_status": "pending-human-label",
                "golden_status": "not-loaded",
                "difficulty": str(record.get("difficulty") or "").strip(),
                "rvs_score": decimal(record.get("rvs_score")),
                "num_substantive_comments": integer(record.get("num_substantive_comments")),
                "provenance": {
                    "metadata_only": True,
                    "source_has_golden_text": True,
                    "source_has_diff": True,
                    "requires_private_checkout": True,
                    "requires_source_license_audit": True,
                    "requires_comment_license_audit": True,
                    "semantic_matching": True,
                },
            }
        )
    return rows, skipped


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="SWE-PRBench dataset/prs.jsonl")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--revision", required=True, help="full dataset git revision")
    parser.add_argument("--split", default="external-smoke", choices=sorted(ALLOWED_SPLITS))
    parser.add_argument("--language", action="append", dest="languages")
    args = parser.parse_args()
    revision = args.revision.strip()
    if not SHA_RE.fullmatch(revision):
        parser.error("--revision must be a full 40-character git SHA")
    rows, skipped = normalize(
        records_from_jsonl(args.input),
        revision=revision.lower(),
        split=args.split,
        languages={value.strip().lower() for value in args.languages or [] if value.strip()} or None,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")
    languages_count = Counter(row["language"] for row in rows)
    language_text = ", ".join(f"{key}={value}" for key, value in sorted(languages_count.items())) or "none"
    skipped_text = ", ".join(f"{key}={value}" for key, value in sorted(skipped.items())) or "none"
    print(
        f"wrote {len(rows)} SWE-PRBench candidates to {args.output}; "
        f"languages [{language_text}]; skipped [{skipped_text}]"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
