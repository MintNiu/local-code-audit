#!/usr/bin/env python3
"""Select unseen pending candidates without changing the private scorecard.

The candidate pool is a human-review input, not a gold set.  This command only
removes rows that are already scored, already classified, or exact duplicates.
It deliberately does not infer severity, feature-cluster similarity, or model
quality from commit messages.
"""

from __future__ import annotations

import argparse
import csv
import re
import sys
from pathlib import Path


SHA_RE = re.compile(r"^[0-9A-Fa-f]{7,64}$")
REQUIRED_CANDIDATE_COLUMNS = (
    "repo",
    "commit",
    "parent",
    "feature_cluster",
    "candidate_reason",
    "status",
)
REQUIRED_SCORECARD_COLUMNS = ("repo", "commit", "parent", "feature_cluster")


def fail(message: str) -> "NoReturn":
    print(f"候选筛选失败：{message}", file=sys.stderr)
    raise SystemExit(2)


def read_tsv(path: Path, required: tuple[str, ...]) -> tuple[list[str], list[dict[str, str]]]:
    if not path.is_file():
        fail(f"文件不存在: {path}")
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        fail(f"无法读取 {path}: {exc}")
    if any(ord(char) < 32 and char not in "\t\n\r" for char in text):
        fail(f"包含不可安全写入 TSV 的控制字符: {path}")
    reader = csv.DictReader(text.splitlines(), delimiter="\t")
    if reader.fieldnames is None or len(reader.fieldnames) < len(required) or any(
        reader.fieldnames[index] != column for index, column in enumerate(required)
    ):
        fail(f"表头前 {len(required)} 列必须是 {'、'.join(required)}: {path}")
    if len(set(reader.fieldnames)) != len(reader.fieldnames):
        fail(f"表头包含重复列: {path}")
    rows: list[dict[str, str]] = []
    for line_number, row in enumerate(reader, start=2):
        if None in row:
            fail(f"第 {line_number} 行列数不一致: {path}")
        if not any(value for value in row.values()):
            continue
        rows.append({key: value or "" for key, value in row.items()})
    return reader.fieldnames, rows


def key(row: dict[str, str]) -> tuple[str, str, str]:
    return (
        row["repo"].strip().lower(),
        row["commit"].strip().lower(),
        row["feature_cluster"].strip().lower(),
    )


def validate_identity(rows: list[dict[str, str]], label: str, require_status: bool = False) -> None:
    parents: dict[tuple[str, str, str], str] = {}
    for index, row in enumerate(rows, start=2):
        commit = row["commit"].strip()
        parent = row["parent"].strip()
        if not SHA_RE.fullmatch(commit) or not SHA_RE.fullmatch(parent):
            fail(f"{label}第 {index} 行 commit/parent 不是 7-64 位十六进制")
        if not row["repo"].strip() or not row["feature_cluster"].strip():
            fail(f"{label}第 {index} 行缺少 repo 或 feature_cluster")
        if require_status and not row["status"].strip():
            fail(f"{label}第 {index} 行缺少 status")
        candidate_key = key(row)
        previous_parent = parents.setdefault(candidate_key, parent.lower())
        if previous_parent != parent.lower():
            fail(f"{label}同一 repo/commit/feature_cluster 对应多个 parent: {candidate_key}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="筛选尚未进入评分卡且仍待人工复核的历史候选。输出仍是候选 TSV，不会修改输入文件。"
    )
    parser.add_argument("--candidates", required=True, type=Path, help="候选池 TSV")
    parser.add_argument("--scorecard", required=True, type=Path, help="已有评分卡 TSV")
    parser.add_argument("--out", type=Path, help="筛选结果 TSV；省略则输出到 stdout")
    args = parser.parse_args()

    candidate_columns, candidates = read_tsv(args.candidates, REQUIRED_CANDIDATE_COLUMNS)
    scorecard_columns, scored = read_tsv(args.scorecard, REQUIRED_SCORECARD_COLUMNS)
    if "label_status" not in scorecard_columns:
        fail(f"评分卡缺少 label_status 列: {args.scorecard}")
    validate_identity(candidates, "候选池", require_status=True)
    validate_identity(scored, "评分卡")

    scored_keys = {key(row) for row in scored}
    selected: list[dict[str, str]] = []
    seen_pending: set[tuple[str, str, str]] = set()
    skipped_status = 0
    skipped_scored = 0
    skipped_duplicate = 0

    for row in candidates:
        candidate_key = key(row)
        if row["status"].strip() != "pending-human-label":
            skipped_status += 1
            continue
        if candidate_key in scored_keys:
            skipped_scored += 1
            continue
        if candidate_key in seen_pending:
            skipped_duplicate += 1
            continue
        seen_pending.add(candidate_key)
        selected.append(row)

    destination = args.out
    try:
        if destination:
            if destination.exists():
                fail(f"拒绝覆盖已有筛选结果: {destination}")
            destination.parent.mkdir(parents=True, exist_ok=True)
            with destination.open("w", encoding="utf-8", newline="") as stream:
                writer = csv.DictWriter(stream, fieldnames=candidate_columns, delimiter="\t", lineterminator="\n")
                writer.writeheader()
                writer.writerows(selected)
        else:
            writer = csv.DictWriter(sys.stdout, fieldnames=candidate_columns, delimiter="\t", lineterminator="\n")
            writer.writeheader()
            writer.writerows(selected)
    except OSError as exc:
        fail(f"无法写入筛选结果: {exc}")

    print(
        "candidate triage: "
        f"selected={len(selected)} "
        f"skipped-status={skipped_status} "
        f"skipped-scorecard={skipped_scored} "
        f"skipped-duplicate={skipped_duplicate}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    main()
