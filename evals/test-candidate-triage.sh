#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-candidate-triage.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

cat >"$test_root/candidates.tsv" <<'EOF'
repo	commit	parent	feature_cluster	candidate_reason	status
platform-a	abcdef1234567	123456789abcd	new-root	new	pending-human-label
platform-a	abcdef1234567	123456789abcd	new-root	duplicate	pending-human-label
platform-a	abcdef1234568	123456789abc1	scored-root	already scored	pending-human-label
platform-a	abcdef1234568	123456789abc1	unclassified-abcdef1234568	discovered already scored	pending-human-label
platform-a	abcdef1234569	123456789abc2	unclassified-abcdef1234569	discovered already reviewed	pending-human-label
platform-a	abcdef1234569	123456789abc2	clean-root	already classified	exclude-clean
EOF
cat >"$test_root/scorecard.tsv" <<'EOF'
repo	commit	parent	feature_cluster	gold_p0_p1	label_status
platform-a	abcdef1234568	123456789abc1	scored-root	1	manual-confirmed
EOF
cat >"$test_root/review.tsv" <<'EOF'
repo	commit	feature_cluster	decision	evidence_confidence	reason
platform-a	abcdef1234567	new-root	exclude-clean	high	already reviewed
platform-a	abcdef1234569	clean-root	exclude-clean	high	already reviewed
EOF

python3 "$repo_root/scripts/triage-candidates.py" \
  --candidates "$test_root/candidates.tsv" \
  --scorecard "$test_root/scorecard.tsv" \
  --review "$test_root/review.tsv" \
  --out "$test_root/selected.tsv" \
  2>"$test_root/stderr"

grep -F $'candidate triage: selected=0 skipped-status=1 skipped-scorecard=2 skipped-review=2 skipped-duplicate=1' "$test_root/stderr" >/dev/null
[[ "$(wc -l <"$test_root/selected.tsv" | tr -d ' ')" == 1 ]]

printf 'bad-header\n' >"$test_root/bad-candidates.tsv"
if python3 "$repo_root/scripts/triage-candidates.py" \
  --candidates "$test_root/bad-candidates.tsv" \
  --scorecard "$test_root/scorecard.tsv" \
  --out "$test_root/bad-selected.tsv" \
  >/dev/null 2>"$test_root/bad-stderr"; then
  echo "坏表头必须 fail-closed" >&2
  exit 1
fi
grep -F '表头前 6 列必须是' "$test_root/bad-stderr" >/dev/null

if python3 "$repo_root/scripts/triage-candidates.py" \
  --candidates "$test_root/candidates.tsv" \
  --scorecard "$test_root/scorecard.tsv" \
  --out "$test_root/selected-2.tsv" \
  >/dev/null 2>"$test_root/second-stderr"; then
  :
else
  echo "重复执行筛选器不应失败" >&2
  exit 1
fi

echo "candidate triage fixture: PASS"
