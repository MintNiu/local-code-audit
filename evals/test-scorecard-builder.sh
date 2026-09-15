#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/local-review-scorecard-builder.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
labels_dir="$tmp_dir/labels"
results_dir="$tmp_dir/results"
mkdir -p "$labels_dir" "$results_dir"

commit="0123456789abcdef0123456789abcdef01234567"
cat >"$labels_dir/$commit.labels.tsv" <<EOF
# commit	$commit
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

output="$tmp_dir/scorecard.tsv"
"$repo_root/evals/build-scorecard.sh" --labels-dir "$labels_dir" --results-dir "$results_dir" --out "$output" >/dev/null
expected_header=$'commit\tmodel\ttemperature\tseed\tnum_ctx\tgold_p0_p1\tp0_p1_found\tpredicted_candidates\tfalse_positive_count\toutput_complete\telapsed_seconds'
grep -Fx "$expected_header" "$output" >/dev/null
grep -F "$commit" "$output" | grep -F $'\t1\t1\t2\t1\ttrue\t12' >/dev/null
"$repo_root/evals/summarize-scorecard.sh" "$output" | grep -F 'p0_p1_recall=100.0%' >/dev/null

echo 'scorecard builder regression passed'
