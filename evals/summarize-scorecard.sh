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
    for (i = 1; i <= NF; i++) {
      if ($i in column) fail("scorecard 表头包含重复列: " $i)
      column[$i] = i
    }
    required = "commit model temperature seed num_ctx gold_p0_p1 p0_p1_found predicted_candidates output_complete elapsed_seconds"
    required_count = split(required, required_names, /[[:space:]]+/)
    for (i = 1; i <= required_count; i++) {
      if (!(required_names[i] in column)) fail("scorecard 缺少必需列: " required_names[i])
    }
    if ("false_positive_count" in column) {
      false_positive_column = column["false_positive_count"]
    } else if ("false_positives" in column) {
      false_positive_column = column["false_positives"]
    } else {
      fail("scorecard 缺少必需列: false_positive_count（或兼容名称 false_positives）")
    }
    commit_column = column["commit"]
    gold_column = column["gold_p0_p1"]
    found_column = column["p0_p1_found"]
    candidates_column = column["predicted_candidates"]
    complete_column = column["output_complete"]
    elapsed_column = column["elapsed_seconds"]
    required_max = 0
    for (i = 1; i <= required_count; i++)
      if (column[required_names[i]] > required_max) required_max = column[required_names[i]]
    if (false_positive_column > required_max) required_max = false_positive_column
    next
  }
  /^[[:space:]]*$/ { next }
  /^#/ { next }
  {
    if (NF < required_max) fail("scorecard 行缺少表头声明的列，第 " NR " 行实际为 " NF " 列")
    if ($commit_column !~ /^[0-9a-fA-F]{7,64}$/) fail("无效 commit，必须是 7-64 位十六进制提交号: " $commit_column)
    if ($commit_column in seen) fail("重复 commit，拒绝汇总: " $commit_column)
    for (i = 1; i <= 4; i++) {
      metric_column = (i == 1 ? gold_column : i == 2 ? found_column : i == 3 ? candidates_column : false_positive_column)
      if ($metric_column !~ /^[0-9]+$/) fail("指标必须是非负整数，第 " NR " 行第 " metric_column " 列: " $metric_column)
    }
    if ($complete_column != "true" && $complete_column != "false") fail("output_complete 必须是 true 或 false，第 " NR " 行: " $complete_column)
    if ($elapsed_column !~ /^[0-9]+$/) fail("elapsed_seconds 必须是非负整数，第 " NR " 行: " $elapsed_column)
    if (($found_column + 0) > ($gold_column + 0)) fail("p0_p1_found 不能大于 gold_p0_p1，第 " NR " 行")
    if (($false_positive_column + 0) > ($candidates_column + 0)) fail("false_positive_count 不能大于 predicted_candidates，第 " NR " 行")
    seen[$commit_column] = 1
    rows++
    gold += ($gold_column + 0)
    found += ($found_column + 0)
    candidates += ($candidates_column + 0)
    false_positives += ($false_positive_column + 0)
    if ($complete_column != "true") incomplete++
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
