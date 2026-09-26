#!/usr/bin/env bash
set -euo pipefail

scorecard=""
min_commits=20
min_holdout_gold=20
min_recall=90
max_false_positive_rate=10
min_location_accuracy=90

usage() {
  cat <<'EOF'
用法:
  ./evals/stage1-gate.sh --scorecard <stage1.tsv>

阶段 1 默认门槛：至少 20 个真实提交、至少 20 个 holdout P0/P1 根因、
holdout 召回率 >= 90%、定位准确率 >= 90%、误报率 <= 10%，所有运行完整且重复稳定。

scorecard 除基础指标外必须包含：
  split=train|dev|holdout
  feature_cluster=<非空功能簇>
  location_accurate=<非负整数>
  repeat_stable=true
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scorecard)
      [[ $# -ge 2 ]] || { echo "--scorecard 需要文件" >&2; exit 2; }
      scorecard="$2"
      shift 2
      ;;
    --min-commits)
      [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || { echo "--min-commits 必须是正整数" >&2; exit 2; }
      min_commits="$2"
      shift 2
      ;;
    --min-holdout-gold)
      [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || { echo "--min-holdout-gold 必须是正整数" >&2; exit 2; }
      min_holdout_gold="$2"
      shift 2
      ;;
    --min-recall|--max-false-positive-rate|--min-location-accuracy)
      [[ $# -ge 2 && "$2" =~ ^(100|[0-9]{1,2})$ ]] || { echo "$1 必须是 0-100 的整数" >&2; exit 2; }
      case "$1" in
        --min-recall) min_recall="$2" ;;
        --max-false-positive-rate) max_false_positive_rate="$2" ;;
        --min-location-accuracy) min_location_accuracy="$2" ;;
      esac
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$scorecard" && -f "$scorecard" ]] || { usage >&2; exit 2; }

metrics_file="$(mktemp "${TMPDIR:-/tmp}/local-review-stage1-gate.XXXXXX")"
trap 'rm -f "$metrics_file"' EXIT

if ! awk -F '\t' \
  -v min_commits="$min_commits" \
  -v min_holdout_gold="$min_holdout_gold" \
  -v min_recall="$min_recall" \
  -v max_false_positive_rate="$max_false_positive_rate" \
  -v min_location_accuracy="$min_location_accuracy" '
  function fail(message) {
    print "stage1 gate: " message > "/dev/stderr"
    bad = 1
  }
  NR == 1 {
    for (i = 1; i <= NF; i++) {
      if ($i in column) fail("scorecard 表头包含重复列: " $i)
      column[$i] = i
    }
    required = "commit split feature_cluster gold_p0_p1 p0_p1_found predicted_candidates false_positive_count output_complete location_accurate repeat_stable"
    required_count = split(required, required_names, /[[:space:]]+/)
    for (i = 1; i <= required_count; i++) {
      if (!(required_names[i] in column)) fail("scorecard 缺少阶段 1 必需列: " required_names[i])
    }
    next
  }
  /^[[:space:]]*$/ { next }
  /^#/ { next }
  {
    if (bad) next
    if (NF < required_count) { fail("第 " NR " 行列数不足"); next }
    commit = $(column["commit"])
    split_name = $(column["split"])
    cluster = $(column["feature_cluster"])
    gold = $(column["gold_p0_p1"])
    found = $(column["p0_p1_found"])
    candidates = $(column["predicted_candidates"])
    false_positive = $(column["false_positive_count"])
    complete = $(column["output_complete"])
    location = $(column["location_accurate"])
    stable = $(column["repeat_stable"])
    if (commit !~ /^[0-9a-fA-F]{7,64}$/) fail("无效 commit: " commit)
    if (commit in seen_commit) fail("重复 commit: " commit)
    seen_commit[commit] = 1
    if (split_name !~ /^(train|dev|holdout)$/) fail("split 必须是 train、dev 或 holdout: " split_name)
    if (cluster == "") fail("feature_cluster 不能为空: " commit)
    if (cluster in cluster_split && cluster_split[cluster] != split_name) fail("同一 feature_cluster 泄漏到多个 split: " cluster)
    cluster_split[cluster] = split_name
    if (gold !~ /^[0-9]+$/ || found !~ /^[0-9]+$/ || candidates !~ /^[0-9]+$/ || false_positive !~ /^[0-9]+$/ || location !~ /^[0-9]+$/)
      fail("指标必须是非负整数: " commit)
    if (found + 0 > gold + 0) fail("p0_p1_found 不能大于 gold_p0_p1: " commit)
    if (location + 0 > found + 0) fail("location_accurate 不能大于 p0_p1_found: " commit)
    if (false_positive + 0 > candidates + 0) fail("false_positive_count 不能大于 predicted_candidates: " commit)
    if (complete != "true") fail("存在不完整运行: " commit)
    if (stable != "true") fail("存在重复运行不稳定: " commit)
    rows++
    split_rows[split_name]++
    if (split_name == "holdout") {
      holdout_gold += gold + 0
      holdout_found += found + 0
      holdout_location += location + 0
      holdout_candidates += candidates + 0
      holdout_false_positive += false_positive + 0
    }
  }
  END {
    if (bad) exit 2
    if (rows < min_commits) fail("真实提交数不足: " rows " < " min_commits)
    if (split_rows["train"] == 0 || split_rows["dev"] == 0 || split_rows["holdout"] == 0) fail("train/dev/holdout 均必须有数据")
    if (holdout_gold < min_holdout_gold) fail("holdout P0/P1 分母不足: " holdout_gold " < " min_holdout_gold)
    if (holdout_found * 100 < holdout_gold * min_recall) fail("holdout 召回率低于门槛")
    if (holdout_location * 100 < holdout_found * min_location_accuracy) fail("holdout 定位准确率低于门槛")
    if (holdout_candidates > 0 && holdout_false_positive * 100 > holdout_candidates * max_false_positive_rate) fail("holdout 误报率高于门槛")
    if (bad) exit 2
    recall = (holdout_gold == 0 ? "n/a" : sprintf("%.1f%%", holdout_found * 100 / holdout_gold))
    location_rate = (holdout_found == 0 ? "n/a" : sprintf("%.1f%%", holdout_location * 100 / holdout_found))
    fp_rate = (holdout_candidates == 0 ? "n/a" : sprintf("%.1f%%", holdout_false_positive * 100 / holdout_candidates))
    print "stage1_gate=pass"
    print "commits=" rows
    print "holdout_gold_p0_p1=" holdout_gold
    print "holdout_recall=" recall
    print "holdout_location_accuracy=" location_rate
    print "holdout_false_positive_rate=" fp_rate
  }
' "$scorecard" >"$metrics_file"; then
  exit 1
fi

cat "$metrics_file"
