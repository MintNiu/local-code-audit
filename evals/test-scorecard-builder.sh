#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/local-review-scorecard-builder.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
labels_dir="$tmp_dir/labels"
results_dir="$tmp_dir/results"
mkdir -p "$labels_dir" "$results_dir"

commit="0123456789abcdef0123456789abcdef01234567"
result_file="$results_dir/$commit.txt"
cat >"$labels_dir/$commit.labels.tsv" <<EOF
# commit	$commit
# source_result	$result_file
# source_result_sha256	PLACEHOLDER
# review_status	complete
# verdict	findings
# finding_id	severity	path	line	status	notes
confirmed-1	P1	src/Example.java	10	confirmed	查询直接拼接用户输入，模型命中 SQL 注入
false-positive-1	P2	src/Example.java	20	false-positive	没有代码证据
uncertain-1	P1	src/Other.java	3	uncertain	等待契约
EOF
cat >"$results_dir/$commit.txt" <<'EOF'
P1 src/Example.java:10 - 查询直接拼接用户输入造成 SQL 注入
影响：示例。
修复建议：示例。
验证方式：示例。

P2 src/Example.java:20 - 模型候选
影响：示例。
修复建议：示例。
验证方式：示例。
EOF
cat >"$results_dir/$commit.meta.tsv" <<EOF
resolved_model	devstral-small-2-review-tuned
temperature	0
seed	42
num_ctx	16384
status	completed
exit_code	0
elapsed_seconds	12
EOF
result_sha256="$(shasum -a 256 "$result_file" | awk '{print $1}')"
perl -0pi -e "s/PLACEHOLDER/$result_sha256/" "$labels_dir/$commit.labels.tsv"

output="$tmp_dir/scorecard.tsv"
"$repo_root/evals/build-scorecard.sh" --labels-dir "$labels_dir" --results-dir "$results_dir" --out "$output" >/dev/null
expected_header=$'commit\tmodel\ttemperature\tseed\tnum_ctx\tgold_p0_p1\tp0_p1_found\tpredicted_candidates\tfalse_positive_count\toutput_complete\telapsed_seconds'
grep -Fx "$expected_header" "$output" >/dev/null
grep -F "$commit" "$output" | grep -F $'\t1\t1\t2\t1\ttrue\t12' >/dev/null
"$repo_root/evals/summarize-scorecard.sh" "$output" | grep -F 'p0_p1_recall=100.0%' >/dev/null

comma_labels="$tmp_dir/comma-labels"
comma_results="$tmp_dir/comma-results"
mkdir -p "$comma_labels" "$comma_results"
comma_commit="abcdef0123456789abcdef0123456789abcdef01"
comma_result="$comma_results/$comma_commit.txt"
cat >"$comma_result" <<'EOF'
P1 src/Multiple.java:3,4 - 同一编译阻断涉及两个缺失类型
影响：当前提交无法编译。
修复建议：恢复缺失类型。
验证方式：执行编译验证两个类型均可解析。
EOF
{
  printf '# commit\t%s\n' "$comma_commit"
  printf '# source_result\t%s\n' "$comma_result"
  printf '# source_result_sha256\tPLACEHOLDER\n'
  printf '# review_status\tcomplete\n# verdict\tfindings\n'
  printf '# finding_id\tseverity\tpath\tline\tstatus\tnotes\n'
  printf '%s-root\tP1\tsrc/Multiple.java\t3-4\tconfirmed\t两个 import 属于同一个编译阻断根因\n' "$comma_commit"
} >"$comma_labels/$comma_commit.labels.tsv"
comma_hash="$(shasum -a 256 "$comma_result" | awk '{print $1}')"
perl -0pi -e "s/PLACEHOLDER/$comma_hash/" "$comma_labels/$comma_commit.labels.tsv"
cat >"$comma_results/$comma_commit.meta.tsv" <<'EOF'
resolved_model	devstral-small-2-review-tuned
temperature	0
seed	42
num_ctx	16384
status	completed
exit_code	0
elapsed_seconds	0
EOF
comma_output="$tmp_dir/comma-scorecard.tsv"
"$repo_root/evals/build-scorecard.sh" --labels-dir "$comma_labels" --results-dir "$comma_results" --out "$comma_output" >/dev/null
grep -F "$comma_commit" "$comma_output" | grep -F $'\t1\t1\t1\t0\ttrue\t0' >/dev/null

missed_labels="$tmp_dir/missed-labels"
mkdir -p "$missed_labels"
cp "$labels_dir/$commit.labels.tsv" "$missed_labels/$commit.labels.tsv"
printf 'missed-1\tP1\tsrc/Missed.java\t42\tmissed\t人工复核确认，模型结果未输出\n' >>"$missed_labels/$commit.labels.tsv"
missed_output="$tmp_dir/missed.tsv"
"$repo_root/evals/build-scorecard.sh" --labels-dir "$missed_labels" --results-dir "$results_dir" --out "$missed_output" >/dev/null
grep -F "$commit" "$missed_output" | grep -F $'\t2\t1\t2\t1\ttrue\t12' >/dev/null
"$repo_root/evals/summarize-scorecard.sh" "$missed_output" | grep -F 'p0_p1_recall=50.0%' >/dev/null

missed_overlap_labels="$tmp_dir/missed-overlap-labels"
mkdir -p "$missed_overlap_labels"
cp "$labels_dir/$commit.labels.tsv" "$missed_overlap_labels/$commit.labels.tsv"
printf 'missed-overlap\tP1\tsrc/Example.java\t10\tmissed\t同一查询还缺少租户条件，模型仅报告 SQL 注入而未报告越权根因\n' >>"$missed_overlap_labels/$commit.labels.tsv"
missed_overlap_output="$tmp_dir/missed-overlap.tsv"
"$repo_root/evals/build-scorecard.sh" --labels-dir "$missed_overlap_labels" --results-dir "$results_dir" --out "$missed_overlap_output" >/dev/null
grep -F "$commit" "$missed_overlap_output" | grep -F $'\t2\t1\t2\t1\ttrue\t12' >/dev/null
"$repo_root/evals/summarize-scorecard.sh" "$missed_overlap_output" | grep -F 'p0_p1_recall=50.0%' >/dev/null

wide_labels="$tmp_dir/wide-labels"
wide_results="$tmp_dir/wide-results"
mkdir -p "$wide_labels" "$wide_results"
cp "$labels_dir/$commit.labels.tsv" "$wide_labels/$commit.labels.tsv"
cp "$results_dir/$commit.meta.tsv" "$wide_results/$commit.meta.tsv"
sed 's/src\/Example.java:10 -/src\/Example.java:1-100 -/' "$result_file" >"$wide_results/$commit.txt"
wide_sha256="$(shasum -a 256 "$wide_results/$commit.txt" | awk '{print $1}')"
perl -0pi -e "s/$result_sha256/$wide_sha256/" "$wide_labels/$commit.labels.tsv"
printf 'missed-wide\tP0\tsrc/Example.java\t42-42\tmissed\t第 42 行另有任意命令执行，整文件范围的 SQL 注入候选未描述该根因\n' >>"$wide_labels/$commit.labels.tsv"
wide_output="$tmp_dir/wide.tsv"
"$repo_root/evals/build-scorecard.sh" --labels-dir "$wide_labels" --results-dir "$wide_results" --out "$wide_output" >/dev/null
grep -F "$commit" "$wide_output" | grep -F $'\t2\t1\t2\t1\ttrue\t12' >/dev/null
"$repo_root/evals/summarize-scorecard.sh" "$wide_output" | grep -F 'p0_p1_recall=50.0%' >/dev/null

expect_rejected_label() {
  local case_name="$1" row="$2" expected_error="$3"
  local case_labels="$tmp_dir/$case_name-labels" case_output="$tmp_dir/$case_name.tsv" case_error="$tmp_dir/$case_name.err"
  mkdir -p "$case_labels"
  cp "$labels_dir/$commit.labels.tsv" "$case_labels/$commit.labels.tsv"
  printf '%s\n' "$row" >>"$case_labels/$commit.labels.tsv"
  if "$repo_root/evals/build-scorecard.sh" --labels-dir "$case_labels" --results-dir "$results_dir" --out "$case_output" >/dev/null 2>"$case_error"; then
    echo "scorecard builder accepted invalid label: $case_name" >&2
    exit 1
  fi
  grep -F "$expected_error" "$case_error" >/dev/null
  [[ ! -e "$case_output" ]] || {
    echo "scorecard builder left partial output after invalid label: $case_name" >&2
    exit 1
  }
}

# Isolate each invalid field: a severity error must not mask a line/notes error.
expect_rejected_label missed-severity $'bad\tP2\tsrc/Missed.java\t42\tmissed\t代码证据' 'missed 标签只能记录 P0/P1'
expect_rejected_label missed-zero $'bad\tP1\tsrc/Missed.java\t0\tmissed\t代码证据' 'missed 标签缺少有效'
expect_rejected_label missed-negative $'bad\tP1\tsrc/Missed.java\t-1\tmissed\t代码证据' 'missed 标签缺少有效'
expect_rejected_label missed-nonnumeric $'bad\tP1\tsrc/Missed.java\tline42\tmissed\t代码证据' 'missed 标签缺少有效'
expect_rejected_label missed-reversed $'bad\tP1\tsrc/Missed.java\t20-10\tmissed\t代码证据' 'missed 标签行号范围必须正序'
expect_rejected_label missed-shorter-end $'bad\tP1\tsrc/Missed.java\t20-9\tmissed\t代码证据' 'missed 标签行号范围必须正序'
expect_rejected_label missed-empty-notes $'bad\tP1\tsrc/Missed.java\t42\tmissed\t' 'missed 标签缺少有效'
expect_rejected_label missed-blank-notes $'bad\tP1\tsrc/Missed.java\t42\tmissed\t   ' 'missed 标签缺少有效'
expect_rejected_label missed-absolute-path $'bad\tP1\t/src/Missed.java\t42\tmissed\t代码证据' 'missed 标签缺少有效'
expect_rejected_label missed-parent-path $'bad\tP1\tsrc/../../Missed.java\t42\tmissed\t代码证据' 'missed 标签缺少有效'
expect_rejected_label unknown-status $'bad\tP1\tsrc/Missed.java\t42\tunknown\t代码证据' '标签包含未知 finding status'

overcount_labels="$tmp_dir/overcount-labels"
mkdir -p "$overcount_labels"
cp "$labels_dir/$commit.labels.tsv" "$overcount_labels/$commit.labels.tsv"
printf 'false-positive-2\tP2\tsrc/Other.java\t20\tfalse-positive\t重复候选\nfalse-positive-3\tP2\tsrc/Other.java\t21\tfalse-positive\t重复候选\n' >>"$overcount_labels/$commit.labels.tsv"
overcount_output="$tmp_dir/overcount.tsv"
if "$repo_root/evals/build-scorecard.sh" --labels-dir "$overcount_labels" --results-dir "$results_dir" --out "$overcount_output" >/dev/null 2>&1; then
  echo 'scorecard builder accepted more false positives than result candidates' >&2
  exit 1
fi
[[ ! -e "$overcount_output" ]] || {
  echo 'scorecard builder left partial output after candidate-count failure' >&2
  exit 1
}

mismatch_labels="$tmp_dir/mismatch-labels"
mkdir -p "$mismatch_labels"
cp "$labels_dir/$commit.labels.tsv" "$mismatch_labels/$commit.labels.tsv"
perl -0pi -e 's{false-positive-1\tP2\tsrc/Example\.java\t20}{false-positive-1\tP2\tsrc/Missing.java\t20}' "$mismatch_labels/$commit.labels.tsv"
mismatch_output="$tmp_dir/mismatch.tsv"
if "$repo_root/evals/build-scorecard.sh" --labels-dir "$mismatch_labels" --results-dir "$results_dir" --out "$mismatch_output" >/dev/null 2>&1; then
  echo 'scorecard builder accepted a label location absent from the result' >&2
  exit 1
fi
[[ ! -e "$mismatch_output" ]] || {
  echo 'scorecard builder left partial output after location mismatch' >&2
  exit 1
}

stale_output="$tmp_dir/stale.tsv"
perl -0pi -e 's{# source_result_sha256\t[^\n]+}{# source_result_sha256\t0000000000000000000000000000000000000000000000000000000000000000}' "$labels_dir/$commit.labels.tsv"
if "$repo_root/evals/build-scorecard.sh" --labels-dir "$labels_dir" --results-dir "$results_dir" --out "$stale_output" >/dev/null 2>&1; then
  echo 'scorecard builder accepted a stale label/result pairing' >&2
  exit 1
fi
[[ ! -e "$stale_output" ]] || {
  echo 'scorecard builder left a partial output after stale pairing failure' >&2
  exit 1
}

echo 'scorecard builder regression passed'
