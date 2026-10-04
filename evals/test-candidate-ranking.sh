#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/scripts/rank-candidates.py"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/local-review-ranking.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/workspace/demo"
git -C "$tmp_dir/workspace/demo" init -q
git -C "$tmp_dir/workspace/demo" config user.email test@example.invalid
git -C "$tmp_dir/workspace/demo" config user.name test
printf 'public class Demo {}\n' >"$tmp_dir/workspace/demo/Demo.java"
git -C "$tmp_dir/workspace/demo" add Demo.java
git -C "$tmp_dir/workspace/demo" commit -q -m baseline
parent="$(git -C "$tmp_dir/workspace/demo" rev-parse HEAD)"
cat >"$tmp_dir/workspace/demo/Demo.java" <<'EOF'
public class Demo {
    // tenant token boundary
    String token = request.getHeader("X-Token");
}
EOF
git -C "$tmp_dir/workspace/demo" add Demo.java
git -C "$tmp_dir/workspace/demo" commit -q -m 'fix auth token boundary'
high="$(git -C "$tmp_dir/workspace/demo" rev-parse HEAD)"
printf 'public class Plain {}\n' >"$tmp_dir/workspace/demo/Plain.java"
git -C "$tmp_dir/workspace/demo" add Plain.java
git -C "$tmp_dir/workspace/demo" commit -q -m 'docs cleanup'
low="$(git -C "$tmp_dir/workspace/demo" rev-parse HEAD)"

cat >"$tmp_dir/candidates.tsv" <<EOF
repo	commit	parent	feature_cluster	candidate_reason	status
demo	$low	$high	plain-docs	documentation cleanup	pending-human-label
demo	$high	$parent	gateway-token	trusted header and tenant boundary	pending-human-label
EOF
python3 "$script" --candidates "$tmp_dir/candidates.tsv" --workspace-root "$tmp_dir/workspace" --out "$tmp_dir/ranked.tsv"
[[ "$(awk -F '\t' 'NR == 2 { print $2 }' "$tmp_dir/ranked.tsv")" == "$high" ]]
[[ "$(awk -F '\t' 'NR == 2 { print $7 }' "$tmp_dir/ranked.tsv")" == "first" ]]
[[ "$(wc -l <"$tmp_dir/ranked.tsv" | tr -d ' ')" == 3 ]]

cat >"$tmp_dir/candidates-with-subject.tsv" <<EOF
repo	commit	parent	feature_cluster	candidate_reason	status	commit_subject
demo	$high	$parent	gateway-token	trusted header and tenant boundary	pending-human-label	fix auth token boundary
EOF
python3 "$script" --candidates "$tmp_dir/candidates-with-subject.tsv" --workspace-root "$tmp_dir/workspace" --out "$tmp_dir/ranked-with-subject.tsv"
[[ -z "$(head -1 "$tmp_dir/ranked-with-subject.tsv" | tr '\t' '\n' | sort | uniq -d)" ]]
echo "candidate ranking test passed"
