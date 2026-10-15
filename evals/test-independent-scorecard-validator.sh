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

expected=$'rows=3\nstrict_records=1\nstrict_unique_commits=1\nstrict_gold_p0_p1=1\nstrict_p0_p1_found=1\nstrict_recall=100.0%\nstrict_output_complete=1/1\nstrict_repeat_stable=1/1\nstrict_location_accurate=1/1\nstatus_manual-confirmed=1\nstatus_manual-confirmed-conditional=1\nstatus_pending-human-label=0\nstatus_tuning-source=1'
actual="$(python3 "$repo_root/scripts/validate-independent-scorecard.py" "$valid")"
[[ "$actual" == "$expected" ]] || {
  echo 'valid independent scorecard summary changed unexpectedly' >&2
  printf '%s\n' "$actual" >&2
  exit 1
}

assert_rejected() {
  local name="$1"
  local expected_diagnostic="$2"
  local content="$3"
  local file="$fixture_root/$name.tsv"
  local status=0
  # Fixtures below use explicit \t escapes. Decode them so metric/identity
  # negatives reach their intended checks instead of failing the column count.
  printf '%b\n' "$content" >"$file"
  python3 "$repo_root/scripts/validate-independent-scorecard.py" "$file" \
    >"$fixture_root/$name.stdout" 2>"$fixture_root/$name.stderr" || status=$?
  if [[ "$status" != 2 ]]; then
    echo "expected invalid scorecard exit 2, got $status: $name" >&2
    exit 1
  fi
  grep -F -- "$expected_diagnostic" "$fixture_root/$name.stderr" >/dev/null || {
    echo "scorecard failed for the wrong reason: $name" >&2
    cat "$fixture_root/$name.stderr" >&2
    exit 1
  }
  [[ ! -s "$fixture_root/$name.stdout" ]] || {
    echo "invalid scorecard emitted authoritative-looking summary: $name" >&2
    exit 1
  }
}

header=$'repo\tcommit\tparent\tfeature_cluster\tgold_p0_p1\tp0_p1_found\tpredicted_candidates\toutput_complete\trepeat_stable\tlocation_accurate\tlabel_status\tevidence'
assert_rejected "bad-column-count" '第 2 行应有 12 列' "$header
platform-auth\tabcdef1\t1234567\tcluster\t1\t0\t0\ttrue\ttrue\t0\tmanual-confirmed"
assert_rejected "found-exceeds-gold" 'p0_p1_found 不能大于 gold_p0_p1' "$header
platform-auth\tabcdef2\t1234567\tcluster\t1\t2\t2\ttrue\ttrue\t1\tmanual-confirmed\tbad"
assert_rejected "bad-status" 'label_status 不受支持' "$header
platform-auth\tabcdef3\t1234567\tcluster\t1\t0\t0\ttrue\ttrue\t0\tmanual\tbad"
assert_rejected "duplicate" '第 2 行与第 3 行重复 commit + feature_cluster' "$header
platform-auth\tabcdef4\t1234567\tcluster\t1\t0\t0\ttrue\ttrue\t0\tmanual-confirmed\tone
platform-auth\tabcdef4\t1234567\tcluster\t1\t0\t0\ttrue\ttrue\t0\tmanual-confirmed\ttwo"
assert_rejected "duplicate-case" '第 2 行与第 3 行重复 commit + feature_cluster' "$header
platform-auth\tABCDEF4\tABC1234\tcluster\t1\t0\t0\ttrue\ttrue\t0\tmanual-confirmed\tone
platform-auth\tabcdef4\tabc1234\tcluster\t1\t0\t0\ttrue\ttrue\t0\tmanual-confirmed\ttwo"
assert_rejected "parent-conflict" '第 2 行与第 3 行同一 commit abcdef4 存在冲突 parent' "$header
platform-auth\tABCDEF4\tABC1234\tfirst-root\t1\t0\t0\ttrue\ttrue\t0\tmanual-confirmed\tone
platform-auth\tabcdef4\tabc1235\tsecond-root\t1\t0\t0\ttrue\ttrue\t0\tmanual-confirmed\ttwo"
assert_rejected "repo-conflict" '第 2 行与第 3 行同一 commit abcdef4 使用不同 repo 标签' "$header
first-repo\tABCDEF4\tABC1234\tfirst-root\t1\t0\t0\ttrue\ttrue\t0\ttuning-source\tone
second-repo\tabcdef4\tabc1234\tsecond-root\t1\t0\t0\ttrue\ttrue\t0\tmanual-confirmed\ttwo"
assert_rejected "found-exceeds-predicted" 'p0_p1_found 不能大于 predicted_candidates' "$header
platform-auth\tabcdef4\t1234567\tcluster\t1\t1\t0\ttrue\ttrue\t1\tmanual-confirmed\tbad"
assert_rejected "location-exceeds-found" 'location_accurate 不能大于 p0_p1_found' "$header
platform-auth\tabcdef4\t1234567\tcluster\t1\t0\t1\ttrue\ttrue\t1\tmanual-confirmed\tbad"

# Multiple independently labelled roots in one commit remain valid. Hex case
# is immaterial for both identity fields; strict records and commits differ.
multi_root="$fixture_root/multi-root.tsv"
cat >"$multi_root" <<'EOF'
repo	commit	parent	feature_cluster	gold_p0_p1	p0_p1_found	predicted_candidates	output_complete	repeat_stable	location_accurate	label_status	evidence
platform-auth	ABCDEF1234567	123ABCDEF4567	login-replay	1	1	1	true	true	1	manual-confirmed	Controller.java:10
platform-auth	abcdef1234567	123abcdef4567	tenant-binding	1	0	0	true	true	0	manual-confirmed	Repository.java:20
platform-auth	abcdef1234567	123ABCDEF4567	deployment-boundary	1	0	0	true	true	0	manual-confirmed-conditional	deployment contract
platform-auth	abcdef7654321	321abcdef4567	safe-header	0	0	0	true	true	0	manual-confirmed	Client.java:30
platform-job	abcdef7654322	123456789abcd	ssrf	1	1	1	true	true	1	tuning-source	preflight regression
EOF
expected=$'rows=5\nstrict_records=3\nstrict_unique_commits=2\nstrict_gold_p0_p1=2\nstrict_p0_p1_found=1\nstrict_recall=50.0%\nstrict_output_complete=3/3\nstrict_repeat_stable=3/3\nstrict_location_accurate=1/1\nstatus_manual-confirmed=3\nstatus_manual-confirmed-conditional=1\nstatus_pending-human-label=0\nstatus_tuning-source=1'
actual="$(python3 "$repo_root/scripts/validate-independent-scorecard.py" "$multi_root")"
[[ "$actual" == "$expected" ]] || {
  echo 'legitimate multi-root commit was rejected or counted as multiple commits' >&2
  printf '%s\n' "$actual" >&2
  exit 1
}

echo 'independent scorecard validator regression passed'
