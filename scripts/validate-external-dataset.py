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


def declared_paths(row: dict) -> set[str]:
    """Collect optional changed/source paths without accepting arbitrary values."""
    paths: set[str] = set()
    single = row.get("file_path")
    if isinstance(single, str) and single.strip():
        paths.add(single.replace("\\", "/").strip())
    for key in ("files", "changed_files"):
        value = row.get(key)
        if isinstance(value, list):
            paths.update(
                item.replace("\\", "/").strip()
                for item in value
                if isinstance(item, str) and item.strip()
            )
    return paths


def line_in_declared_ranges(row: dict, line: int) -> bool | None:
    """Return whether a line is in optional changed_lines metadata.

    ``None`` means the record does not declare line ranges, so callers can
    preserve compatibility with review-comment sources that only provide a
    location path.
    """
    if "changed_lines" not in row:
        return None
    ranges = row["changed_lines"]
    if not isinstance(ranges, list):
        return False
    for item in ranges:
        if isinstance(item, int) and item == line:
            return True
        if isinstance(item, str):
            text = item.strip()
            if text.isdigit() and int(text) == line:
                return True
            if "-" in text:
                start, end = text.split("-", 1)
                if start.strip().isdigit() and end.strip().isdigit():
                    if int(start) <= line <= int(end):
                        return True
    return False


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
        elif task == "audit-finding" and label == "positive" and not declared_paths(row):
            fail(errors, line_no, "positive audit-finding must declare file_path, files, or changed_files")
        for finding in findings:
            if not isinstance(finding, dict):
                fail(errors, line_no, "each finding must be an object")
                continue
            for key in ("severity", "path", "line", "evidence"):
                if key not in finding:
                    fail(errors, line_no, f"finding missing {key}")
            path = finding.get("path")
            if not isinstance(path, str) or not path.strip():
                fail(errors, line_no, "finding path must be a non-empty string")
            else:
                normalized_path = path.replace("\\", "/").strip()
                paths = declared_paths(row)
                if paths and normalized_path not in paths:
                    fail(errors, line_no, "finding path is not declared by file_path/files/changed_files")
                declared_file = row.get("file_path")
                if isinstance(declared_file, str) and declared_file.strip():
                    if normalized_path != declared_file.replace("\\", "/").strip():
                        fail(errors, line_no, "finding path does not match file_path")
            if "line" in finding and (
                not isinstance(finding["line"], int) or finding["line"] < 1
            ):
                fail(errors, line_no, "finding line must be a positive integer")
            elif "line" in finding:
                range_result = line_in_declared_ranges(row, finding["line"])
                if range_result is False:
                    fail(errors, line_no, "finding line is outside changed_lines")
                source_code = row.get("source_code")
                if row.get("source_code_complete") is True and isinstance(source_code, str):
                    source_line_count = source_code.count("\n") + 1
                    if finding["line"] > source_line_count:
                        fail(errors, line_no, "finding line is outside source_code")
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
