#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-scorecard-test.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

valid="$fixture_root/valid.tsv"
cat >"$valid" <<'EOF'
commit	model	temperature	seed	num_ctx	gold_p0_p1	p0_p1_found	predicted_candidates	false_positive_count	output_complete	elapsed_seconds	notes
abcdef1	devstral-small-2-review-tuned	0	42	16384	2	2	3	1	true	12	verified
abcdef2	devstral-small-2-review-tuned	0	42	16384	0	0	0	0	true	8	clean
EOF

expected=$'commits=2\ngold_p0_p1=2\np0_p1_found=2\np0_p1_recall=100.0%\nrecall_measurable=true\npredicted_candidates=3\nfalse_positives=1\nincomplete_runs=0'
actual="$($repo_root/evals/summarize-scorecard.sh "$valid")"
[[ "$actual" == "$expected" ]] || {
  echo 'valid scorecard summary changed unexpectedly' >&2
  printf '%s\n' "$actual" >&2
  exit 1
}

# Existing private scorecards may carry an additional evaluation_scope column
# and the earlier false_positives spelling; preserve those rows while still
# validating the same numeric invariants.
legacy="$fixture_root/legacy.tsv"
cat >"$legacy" <<'EOF'
commit	model	temperature	seed	num_ctx	gold_p0_p1	p0_p1_found	predicted_candidates	false_positives	output_complete	elapsed_seconds	evaluation_scope	notes
abcdef5	devstral-small-2-review-tuned	0	42	16384	1	1	2	1	true	9	single-repo	legacy
EOF
legacy_expected=$'commits=1\ngold_p0_p1=1\np0_p1_found=1\np0_p1_recall=100.0%\nrecall_measurable=true\npredicted_candidates=2\nfalse_positives=1\nincomplete_runs=0'
legacy_actual="$($repo_root/evals/summarize-scorecard.sh "$legacy")"
[[ "$legacy_actual" == "$legacy_expected" ]] || {
  echo 'legacy scorecard compatibility changed unexpectedly' >&2
  printf '%s\n' "$legacy_actual" >&2
  exit 1
}

assert_rejected() {
  local name="$1"
  local content="$2"
  local file="$fixture_root/$name.tsv"
  printf '%s\n' "$content" >"$file"
  if "$repo_root/evals/summarize-scorecard.sh" "$file" >/dev/null 2>&1; then
    echo "malformed scorecard was accepted: $name" >&2
    exit 1
  fi
}

header=$'commit\tmodel\ttemperature\tseed\tnum_ctx\tgold_p0_p1\tp0_p1_found\tpredicted_candidates\tfalse_positive_count\toutput_complete\telapsed_seconds\tnotes'
assert_rejected duplicate "$header
abcdef1	model	0	42	1	1	1	1	0	true	1	ok
abcdef1	model	0	42	1	1	1	1	0	true	1	duplicate"
assert_rejected invalid-number "$header
abcdef3	model	0	42	1	2	3	1	0	true	1	found exceeds gold"
assert_rejected bad-boolean "$header
abcdef4	model	0	42	1	0	0	0	0	maybe	1	bad boolean"
assert_rejected bad-header $'commit\tmodel\tgold_p0_p1\tp0_p1_found'
assert_rejected incomplete "$header
abcdef6	model	0	42	1	1	1	1	0	false	1	incomplete"

echo 'scorecard regression passed'
