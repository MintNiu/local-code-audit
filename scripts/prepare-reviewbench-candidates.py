#!/usr/bin/env python3
"""Normalize ReviewBench PR metadata without copying review gold or source.

ReviewBench is useful for external review-context, location, and multilingual
smoke runs.  Its golden findings are intentionally not imported here: this
tool emits only manifest metadata and marks every row as pending.  Source
repositories, diffs, review text, and golden labels must remain in a private,
license-reviewed evaluation workspace.
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


SHA_RE = re.compile(r"^[0-9a-fA-F]{40}$")
ALLOWED_SPLITS = {"external-smoke", "train", "dev", "holdout"}


def canonical_repository(value: Any) -> str:
    """Return a stable lower-case repository key for split/leakage checks."""
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
    if host:
        return f"{host}/{path}" if path else host
    return path


def manifest_records(payload: Any, input_path: Path) -> list[dict[str, Any]]:
    """Accept the current list manifest and common wrapper keys, fail closed."""
    if isinstance(payload, list):
        records = payload
    elif isinstance(payload, dict):
        records = None
        for key in ("prs", "records", "items", "data", "manifest"):
            candidate = payload.get(key)
            if isinstance(candidate, list):
                records = candidate
                break
        if records is None:
            raise SystemExit(
                f"ReviewBench manifest has no supported record list: {input_path}"
            )
    else:
        raise SystemExit(f"ReviewBench manifest must be a JSON array/object: {input_path}")
    return [item for item in records if isinstance(item, dict)]


def integer(value: Any, *, minimum: int = 0) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int) and value >= minimum:
        return value
    if isinstance(value, str) and value.strip().isdigit():
        parsed = int(value.strip())
        return parsed if parsed >= minimum else None
    return None


def first(record: dict[str, Any], *keys: str) -> Any:
    for key in keys:
        value = record.get(key)
        if value not in (None, ""):
            return value
    return None


def normalize(
    records: list[dict[str, Any]],
    *,
    source_revision: str,
    split: str,
    languages: set[str] | None,
) -> tuple[list[dict[str, Any]], Counter[str]]:
    rows: list[dict[str, Any]] = []
    skipped: Counter[str] = Counter()
    seen: set[str] = set()

    for record in records:
        repository_raw = first(record, "repo", "nwo", "repository")
        repository = canonical_repository(repository_raw)
        pr_number = integer(first(record, "pr_number", "pull_request"), minimum=1)
        base = str(first(record, "base", "base_sha", "base_commit") or "").strip()
        head = str(first(record, "head", "head_sha", "head_commit") or "").strip()
        language = str(first(record, "language", "lang") or "").strip().lower()
        pr_url = str(first(record, "pr_url", "url", "pull_request_url") or "").strip()
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
        if pr_url and (urlparse(pr_url).netloc.lower() != "github.com"):
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
                "id": f"reviewbench:{digest}",
                "source": {
                    "name": "ReviewBench corpus manifest",
                    "url": "https://github.com/review-bench/ReviewBench",
                    "revision": source_revision,
                    "manifest": "corpus/manifest.json",
                },
                "license": "MIT dataset repository; referenced project and review licenses require separate audit",
                "split": split,
                "repository": repository,
                "repository_url": pr_url,
                "pr_number": pr_number,
                "base_commit": base.lower(),
                "head_commit": head.lower(),
                "commit": head.lower(),
                "language": language,
                "task": "review-candidate",
                "label_status": "pending-human-label",
                "golden_status": "not-loaded",
                "review_snapshot": "head",
                "title": str(record.get("title") or "").strip(),
                "body_present": bool(str(record.get("body") or "").strip()),
                "repo_size_kb": integer(record.get("repo_size_kb")),
                "lines_added": integer(record.get("lines_added")),
                "lines_removed": integer(record.get("lines_removed")),
                "files_changed": integer(record.get("files_changed")),
                "provenance": {
                    "metadata_only": True,
                    "source_has_golden_text": False,
                    "source_has_diff": False,
                    "requires_private_checkout": True,
                    "requires_source_license_audit": True,
                    "semantic_matching": True,
                },
            }
        )
    return rows, skipped


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="ReviewBench corpus/manifest.json")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--revision", required=True, help="ReviewBench git revision")
    parser.add_argument("--split", default="external-smoke", choices=sorted(ALLOWED_SPLITS))
    parser.add_argument(
        "--language",
        action="append",
        dest="languages",
        help="keep only this language; repeat for multiple languages",
    )
    args = parser.parse_args()
    revision = args.revision.strip()
    if not SHA_RE.fullmatch(revision):
        parser.error("--revision must be a full 40-character git SHA")
    try:
        payload = json.loads(args.input.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"cannot read ReviewBench manifest {args.input}: {exc}") from exc
    rows, skipped = normalize(
        manifest_records(payload, args.input),
        source_revision=revision.lower(),
        split=args.split,
        languages={value.strip().lower() for value in args.languages or [] if value.strip()}
        or None,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")
    language_counts = Counter(row["language"] for row in rows)
    languages_text = ", ".join(f"{key}={value}" for key, value in sorted(language_counts.items())) or "none"
    skipped_text = ", ".join(f"{key}={value}" for key, value in sorted(skipped.items())) or "none"
    print(
        f"wrote {len(rows)} ReviewBench candidates to {args.output}; "
        f"languages [{languages_text}]; skipped [{skipped_text}]"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
