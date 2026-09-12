#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ! -f "$1" ]]; then
  echo "用法: $0 /path/to/consolidated-scorecard.tsv" >&2
  exit 2
fi

awk -F '\t' '
  NR == 1 {
    if ($1 != "commit" || $6 != "gold_p0_p1" || $7 != "p0_p1_found") {
      print "scorecard 缺少严格指标列：commit、gold_p0_p1、p0_p1_found" > "/dev/stderr"
      exit 2
    }
    next
  }
  NF == 0 { next }
  {
    if ($1 in seen) {
      print "重复 commit，拒绝汇总: " $1 > "/dev/stderr"
      exit 2
    }
    seen[$1] = 1
    rows++
    gold += ($6 + 0)
    found += ($7 + 0)
    candidates += ($8 + 0)
    false_positives += ($9 + 0)
    if ($10 != "true") incomplete++
  }
  END {
    if (gold == 0) {
      recall = "n/a"
    } else {
      recall = sprintf("%.1f%%", found * 100 / gold)
    }
    printf "commits=%d\ngold_p0_p1=%d\np0_p1_found=%d\np0_p1_recall=%s\npredicted_candidates=%d\nfalse_positives=%d\nincomplete_runs=%d\n", rows, gold, found, recall, candidates, false_positives, incomplete
  }
' "$1"
