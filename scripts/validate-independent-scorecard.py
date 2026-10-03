#!/usr/bin/env python3
"""Validate and summarize the private independent-probe scorecard TSV.

The frozen scorecard is intentionally kept outside this repository.  This
small validator makes the final label_status field authoritative and prevents
misaligned TSV rows or tuning samples from silently entering holdout metrics.
"""

from __future__ import annotations

import argparse
import csv
import re
import sys
from collections import Counter
from pathlib import Path


REQUIRED = (
    "repo", "commit", "parent", "feature_cluster", "gold_p0_p1",
    "p0_p1_found", "predicted_candidates", "output_complete",
    "repeat_stable", "location_accurate", "label_status", "evidence",
)
STATUSES = {
    "manual-confirmed",
    "manual-confirmed-conditional",
    "tuning-source",
    "pending-human-label",
}
HEX_RE = re.compile(r"^[0-9a-fA-F]{7,64}$")
NONNEGATIVE_RE = re.compile(r"^[0-9]+$")


def fail(message: str) -> "NoReturn":
    print(f"scorecard 无效：{message}", file=sys.stderr)
    raise SystemExit(2)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="校验并汇总私有独立评测 TSV。")
    parser.add_argument("input", type=Path, help="independent-probe-results.tsv")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.input.is_file():
        fail(f"文件不存在：{args.input}")

    try:
        handle = args.input.open(newline="", encoding="utf-8")
    except OSError as exc:
        fail(f"无法读取文件：{exc}")

    with handle:
        reader = csv.reader(handle, delimiter="\t")
        try:
            header = next(reader)
        except StopIteration:
            fail("缺少表头")
        if header != list(REQUIRED):
            expected_header = "\t".join(REQUIRED)
            fail(f"表头必须严格为：{expected_header}")

        seen: set[tuple[str, str]] = set()
        status_counts: Counter[str] = Counter()
        gold = found = complete = stable = located = 0
        rows = 0
        for line_number, row in enumerate(reader, start=2):
            if not row or all(not cell for cell in row):
                continue
            if len(row) != len(REQUIRED):
                fail(f"第 {line_number} 行应有 {len(REQUIRED)} 列，实际为 {len(row)} 列")
            repo, commit, parent, cluster = row[:4]
            if not repo or any(ch.isspace() for ch in repo):
                fail(f"第 {line_number} 行 repo 无效")
            if not HEX_RE.fullmatch(commit) or not HEX_RE.fullmatch(parent):
                fail(f"第 {line_number} 行 commit/parent 必须是 7-64 位十六进制")
            key = (commit, cluster)
            if key in seen:
                fail(f"第 {line_number} 行重复 commit + feature_cluster：{commit}/{cluster}")
            seen.add(key)
            if not cluster or any(ch.isspace() for ch in cluster):
                fail(f"第 {line_number} 行 feature_cluster 无效")

            metrics = row[4:7] + [row[9]]
            if any(not NONNEGATIVE_RE.fullmatch(value) for value in metrics):
                fail(f"第 {line_number} 行指标必须是非负整数")
            row_gold, row_found, _predicted, row_location = map(int, metrics)
            if row_found > row_gold:
                fail(f"第 {line_number} 行 p0_p1_found 不能大于 gold_p0_p1")
            if row_location not in (0, 1):
                fail(f"第 {line_number} 行 location_accurate 必须为 0 或 1")
            if row[7] not in ("true", "false") or row[8] not in ("true", "false"):
                fail(f"第 {line_number} 行 output_complete/repeat_stable 必须为 true 或 false")
            if row[10] not in STATUSES:
                fail(f"第 {line_number} 行 label_status 不受支持：{row[10]}")
            if not row[11].strip():
                fail(f"第 {line_number} 行 evidence 不能为空")

            rows += 1
            status_counts[row[10]] += 1
            if row[10] == "manual-confirmed":
                gold += row_gold
                found += row_found
                complete += row[7] == "true"
                stable += row[8] == "true"
                located += row_location

    recall = "n/a" if gold == 0 else f"{found * 100 / gold:.1f}%"
    print(f"rows={rows}")
    print(f"strict_gold_p0_p1={gold}")
    print(f"strict_p0_p1_found={found}")
    print(f"strict_recall={recall}")
    print(f"strict_output_complete={complete}/{status_counts['manual-confirmed']}")
    print(f"strict_repeat_stable={stable}/{status_counts['manual-confirmed']}")
    print(f"strict_location_accurate={located}/{found}")
    for status in sorted(STATUSES):
        print(f"status_{status}={status_counts[status]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
