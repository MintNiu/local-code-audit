#!/usr/bin/env python3
"""Validate a private, license-aware multilingual review dataset.

The validator intentionally accepts only normalized JSONL metadata and review
labels. It never downloads data and never prints source snippets or secrets.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter, defaultdict
from pathlib import Path


ALLOWED_SPLITS = {"external-smoke", "train", "dev", "holdout"}
ALLOWED_LABELS = {"positive", "clean"}
ALLOWED_TASKS = {"review-comment", "audit-finding"}
REQUIRED = {
    "id",
    "source",
    "license",
    "split",
    "repository",
    "language",
    "label",
    "root_causes",
    "task",
}


def fail(errors: list[str], line_no: int, message: str) -> None:
    errors.append(f"line {line_no}: {message}")


def validate(path: Path) -> tuple[list[str], Counter[str], Counter[str]]:
    errors: list[str] = []
    languages: Counter[str] = Counter()
    splits: Counter[str] = Counter()
    identity_splits: dict[tuple[str, str], set[str]] = defaultdict(set)
    seen_ids: set[str] = set()

    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        return [f"cannot read {path}: {exc}"], languages, splits

    for line_no, raw in enumerate(lines, 1):
        if not raw.strip():
            continue
        try:
            row = json.loads(raw)
        except json.JSONDecodeError as exc:
            fail(errors, line_no, f"invalid JSON: {exc.msg}")
            continue
        if not isinstance(row, dict):
            fail(errors, line_no, "record must be a JSON object")
            continue

        missing = sorted(REQUIRED - row.keys())
        if missing:
            fail(errors, line_no, f"missing fields: {', '.join(missing)}")
            continue

        record_id = row["id"]
        if not isinstance(record_id, str) or not record_id.strip():
            fail(errors, line_no, "id must be a non-empty string")
        elif record_id in seen_ids:
            fail(errors, line_no, f"duplicate id: {record_id}")
        else:
            seen_ids.add(record_id)

        source = row["source"]
        if not isinstance(source, dict) or not source.get("name") or not source.get("url"):
            fail(errors, line_no, "source must include non-empty name and url")
        license_name = row["license"]
        if not isinstance(license_name, str) or not license_name.strip():
            fail(errors, line_no, "license must be a non-empty string")

        split = row["split"]
        if split not in ALLOWED_SPLITS:
            fail(errors, line_no, f"split must be one of {sorted(ALLOWED_SPLITS)}")
        else:
            splits[split] += 1

        language = row["language"]
        if not isinstance(language, str) or not language.strip():
            fail(errors, line_no, "language must be a non-empty string")
        else:
            languages[language.lower()] += 1

        label = row["label"]
        if label not in ALLOWED_LABELS:
            fail(errors, line_no, f"label must be one of {sorted(ALLOWED_LABELS)}")

        task = row["task"]
        if task not in ALLOWED_TASKS:
            fail(errors, line_no, f"task must be one of {sorted(ALLOWED_TASKS)}")

        root_causes = row["root_causes"]
        if not isinstance(root_causes, list) or any(
            not isinstance(item, str) or not item.strip() for item in root_causes
        ):
            fail(errors, line_no, "root_causes must be a list of non-empty strings")
        elif label == "positive" and not root_causes:
            fail(errors, line_no, "positive record must have at least one root cause")

        findings = row.get("findings", [])
        if not isinstance(findings, list):
            fail(errors, line_no, "findings must be a list when present")
        elif task == "audit-finding" and label == "positive" and not findings:
            fail(errors, line_no, "positive record must include findings")
        for finding in findings:
            if not isinstance(finding, dict):
                fail(errors, line_no, "each finding must be an object")
                continue
            for key in ("severity", "path", "line", "evidence"):
                if key not in finding:
                    fail(errors, line_no, f"finding missing {key}")
            if "line" in finding and (
                not isinstance(finding["line"], int) or finding["line"] < 1
            ):
                fail(errors, line_no, "finding line must be a positive integer")
        if task == "review-comment":
            comment = row.get("reviewer_comment")
            if not isinstance(comment, str) or not comment.strip():
                fail(errors, line_no, "review-comment record must include reviewer_comment")

        repository = row["repository"]
        commit = row.get("commit", "")
        if isinstance(repository, str) and isinstance(commit, str) and commit:
            identity_splits[(repository, commit)].add(str(split))

    for identity, seen in identity_splits.items():
        if len(seen) > 1:
            errors.append(
                "split leakage for repository/commit "
                f"{identity[0]}@{identity[1]}: {', '.join(sorted(seen))}"
            )
    return errors, languages, splits


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="normalized JSONL dataset")
    args = parser.parse_args()
    errors, languages, splits = validate(args.input)
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        print(f"invalid external dataset: {len(errors)} error(s)", file=sys.stderr)
        return 1
    language_summary = ", ".join(f"{key}={value}" for key, value in sorted(languages.items()))
    split_summary = ", ".join(f"{key}={value}" for key, value in sorted(splits.items()))
    print(f"valid external dataset: languages [{language_summary}]; splits [{split_summary}]")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
