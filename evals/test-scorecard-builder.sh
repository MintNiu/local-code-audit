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
confirmed-1	P1	src/Example.java	10	confirmed	代码证明的根因
false-positive-1	P2	src/Example.java	20	false-positive	没有代码证据
uncertain-1	P1	src/Other.java	3	uncertain	等待契约
EOF
cat >"$results_dir/$commit.txt" <<'EOF'
P1 src/Example.java:10 - 真实问题
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
printf 'missed-overlap\tP1\tsrc/Example.java\t10\tmissed\t与结果候选重叠，必须拒绝\n' >>"$missed_overlap_labels/$commit.labels.tsv"
missed_overlap_output="$tmp_dir/missed-overlap.tsv"
if "$repo_root/evals/build-scorecard.sh" --labels-dir "$missed_overlap_labels" --results-dir "$results_dir" --out "$missed_overlap_output" >/dev/null 2>&1; then
  echo 'scorecard builder accepted a missed label overlapping a visible candidate' >&2
  exit 1
fi
[[ ! -e "$missed_overlap_output" ]] || {
  echo 'scorecard builder left partial output after missed overlap failure' >&2
  exit 1
}

missed_malformed_labels="$tmp_dir/missed-malformed-labels"
mkdir -p "$missed_malformed_labels"
cp "$labels_dir/$commit.labels.tsv" "$missed_malformed_labels/$commit.labels.tsv"
printf 'missed-malformed\tP2\tsrc/Missed.java\t0\tmissed\t没有有效行号\n' >>"$missed_malformed_labels/$commit.labels.tsv"
missed_malformed_output="$tmp_dir/missed-malformed.tsv"
if "$repo_root/evals/build-scorecard.sh" --labels-dir "$missed_malformed_labels" --results-dir "$results_dir" --out "$missed_malformed_output" >/dev/null 2>&1; then
  echo 'scorecard builder accepted malformed missed metadata' >&2
  exit 1
fi
[[ ! -e "$missed_malformed_output" ]] || {
  echo 'scorecard builder left partial output after malformed missed failure' >&2
  exit 1
}

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
