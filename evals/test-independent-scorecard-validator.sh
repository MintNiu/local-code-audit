#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-independent-scorecard.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

valid="$fixture_root/valid.tsv"
cat >"$valid" <<'EOF'
repo	commit	parent	feature_cluster	gold_p0_p1	p0_p1_found	predicted_candidates	output_complete	repeat_stable	location_accurate	label_status	evidence
platform-auth	abcdef1234567	123456789abcd	login-replay	1	1	1	true	true	1	manual-confirmed	Controller.java:10
platform-hr-service	abcdef7654321	123456789abcd	hr-boundary	1	0	0	true	true	0	manual-confirmed-conditional	deployment boundary
platform-job	abcdef7654322	123456789abcd	ssrf	1	1	1	true	true	1	tuning-source	preflight regression
EOF

expected=$'rows=3\nstrict_gold_p0_p1=1\nstrict_p0_p1_found=1\nstrict_recall=100.0%\nstrict_output_complete=1/1\nstrict_repeat_stable=1/1\nstrict_location_accurate=1/1\nstatus_manual-confirmed=1\nstatus_manual-confirmed-conditional=1\nstatus_pending-human-label=0\nstatus_tuning-source=1'
actual="$(python3 "$repo_root/scripts/validate-independent-scorecard.py" "$valid")"
[[ "$actual" == "$expected" ]] || {
  echo 'valid independent scorecard summary changed unexpectedly' >&2
  printf '%s\n' "$actual" >&2
  exit 1
}

assert_rejected() {
  local name="$1"
  local content="$2"
  local file="$fixture_root/$name.tsv"
  printf '%s\n' "$content" >"$file"
  if python3 "$repo_root/scripts/validate-independent-scorecard.py" "$file" >/dev/null 2>&1; then
    echo "malformed independent scorecard was accepted: $name" >&2
    exit 1
  fi
}

header=$'repo\tcommit\tparent\tfeature_cluster\tgold_p0_p1\tp0_p1_found\tpredicted_candidates\toutput_complete\trepeat_stable\tlocation_accurate\tlabel_status\tevidence'
assert_rejected "bad-column-count" "$header
platform-auth\tabcdef1\t1234567\tcluster\t1\t0\t0\ttrue\ttrue\t0\tmanual-confirmed"
assert_rejected "found-exceeds-gold" "$header
platform-auth\tabcdef2\t1234567\tcluster\t1\t2\t2\ttrue\ttrue\t1\tmanual-confirmed\tbad"
assert_rejected "bad-status" "$header
platform-auth\tabcdef3\t1234567\tcluster\t1\t0\t0\ttrue\ttrue\t0\tmanual\tbad"
assert_rejected "duplicate" "$header
platform-auth\tabcdef4\t1234567\tcluster\t1\t0\t0\ttrue\ttrue\t0\tmanual-confirmed\tone
platform-auth\tabcdef4\t1234567\tcluster\t1\t0\t0\ttrue\ttrue\t0\tmanual-confirmed\ttwo"

echo 'independent scorecard validator regression passed'
