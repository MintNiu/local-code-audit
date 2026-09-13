#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ! -f "$1" ]]; then
  echo "用法: $0 /path/to/consolidated-scorecard.tsv" >&2
  exit 2
fi

awk -F '\t' '
  function fail(message) {
    print message > "/dev/stderr"
    failed = 1
    exit 2
  }
  NR == 1 {
    if (NF != 12 || $1 != "commit" || $2 != "model" || $3 != "temperature" ||
        $4 != "seed" || $5 != "num_ctx" || $6 != "gold_p0_p1" ||
        $7 != "p0_p1_found" || $8 != "predicted_candidates" ||
        $9 != "false_positive_count" || $10 != "output_complete" ||
        $11 != "elapsed_seconds" || $12 != "notes") {
      fail("scorecard 表头必须是 12 列 TSV：commit、model、temperature、seed、num_ctx、gold_p0_p1、p0_p1_found、predicted_candidates、false_positive_count、output_complete、elapsed_seconds、notes")
    }
    next
  }
  /^[[:space:]]*$/ { next }
  /^#/ { next }
  {
    if (NF != 12) fail("scorecard 行必须有 12 列 TSV，第 " NR " 行实际为 " NF " 列")
    if ($1 !~ /^[0-9a-fA-F]{7,64}$/) fail("无效 commit，必须是 7-64 位十六进制提交号: " $1)
    if ($1 in seen) fail("重复 commit，拒绝汇总: " $1)
    for (i = 6; i <= 9; i++) {
      if ($i !~ /^[0-9]+$/) fail("指标必须是非负整数，第 " NR " 行第 " i " 列: " $i)
    }
    if ($10 != "true" && $10 != "false") fail("output_complete 必须是 true 或 false，第 " NR " 行: " $10)
    if ($11 !~ /^[0-9]+$/) fail("elapsed_seconds 必须是非负整数，第 " NR " 行: " $11)
    if (($7 + 0) > ($6 + 0)) fail("p0_p1_found 不能大于 gold_p0_p1，第 " NR " 行")
    if (($9 + 0) > ($8 + 0)) fail("false_positive_count 不能大于 predicted_candidates，第 " NR " 行")
    seen[$1] = 1
    rows++
    gold += ($6 + 0)
    found += ($7 + 0)
    candidates += ($8 + 0)
    false_positives += ($9 + 0)
    if ($10 != "true") incomplete++
  }
  END {
    if (failed) exit 2
    if (rows == 0) fail("scorecard 没有可汇总的数据行")
    if (gold == 0) {
      recall = "n/a"
      measurable = "false"
    } else {
      recall = sprintf("%.1f%%", found * 100 / gold)
      measurable = "true"
    }
    printf "commits=%d\ngold_p0_p1=%d\np0_p1_found=%d\np0_p1_recall=%s\nrecall_measurable=%s\npredicted_candidates=%d\nfalse_positives=%d\nincomplete_runs=%d\n", rows, gold, found, recall, measurable, candidates, false_positives, incomplete
  }
' "$1"
