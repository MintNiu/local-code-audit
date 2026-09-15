#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/local-review-label-migration.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
labels_dir="$tmp_dir/labels-old"
from_dir="$tmp_dir/results-old"
to_dir="$tmp_dir/results-new"
out_dir="$tmp_dir/labels-new"
mkdir -p "$labels_dir" "$from_dir" "$to_dir"

equal_commit="0123456789abcdef0123456789abcdef01234567"
changed_commit="abcdef0123456789abcdef0123456789abcdef01"
for commit in "$equal_commit" "$changed_commit"; do
  printf 'P1 src/Example.java:10 - finding %s\n影响：示例。\n修复建议：示例。\n验证方式：示例。\n' "$commit" >"$from_dir/$commit.txt"
  cat >"$labels_dir/$commit.labels.tsv" <<EOF
# commit	$commit
# source_result	$from_dir/$commit.txt
# review_status	complete
# verdict	findings
# finding_id	severity	path	line	status	notes
confirmed-1	P1	src/Example.java	10	confirmed	代码证据
EOF
done
cp "$from_dir/$equal_commit.txt" "$to_dir/$equal_commit.txt"
printf 'P1 src/Example.java:11 - changed\n影响：示例。\n修复建议：示例。\n验证方式：示例。\n' >"$to_dir/$changed_commit.txt"

chmod +x "$repo_root/evals/migrate-labels.sh"
"$repo_root/evals/migrate-labels.sh" \
  --labels-dir "$labels_dir" --from-results-dir "$from_dir" \
  --to-results-dir "$to_dir" --out-labels-dir "$out_dir" >/dev/null
[[ -f "$out_dir/$equal_commit.labels.tsv" ]]
[[ ! -f "$out_dir/$changed_commit.labels.tsv" ]]
new_result="$to_dir/$equal_commit.txt"
grep -F $'# source_result\t'"$new_result" "$out_dir/$equal_commit.labels.tsv" >/dev/null
hash="$(shasum -a 256 "$new_result" | awk '{print $1}')"
grep -F $'# source_result_sha256\t'"$hash" "$out_dir/$equal_commit.labels.tsv" >/dev/null

echo 'label migration regression passed'
