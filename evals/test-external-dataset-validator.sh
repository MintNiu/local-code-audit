#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-external-dataset.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

cat >"$fixture_root/valid.jsonl" <<'EOF'
{"id":"java-001","source":{"name":"example","url":"https://example.invalid/data"},"license":"Apache-2.0","split":"external-smoke","repository":"example/repo","commit":"abc123","language":"java","framework":"spring","task":"audit-finding","label":"positive","root_causes":["tenant-isolation"],"file_path":"src/main/java/Example.java","changed_lines":["10-14"],"findings":[{"severity":"P1","path":"src/main/java/Example.java","line":12,"evidence":"tenant predicate is missing"}]}
{"id":"ts-001","source":{"name":"example","url":"https://example.invalid/data"},"license":"MIT","split":"dev","repository":"example/repo-ts","commit":"def456","language":"typescript","framework":"vue","task":"review-comment","label":"positive","root_causes":["correctness"],"reviewer_comment":"The changed branch drops the error state and leaves the UI stale after a failed request.","findings":[]}
EOF
python3 "$repo_root/scripts/validate-external-dataset.py" "$fixture_root/valid.jsonl" | grep -F 'valid external dataset:' >/dev/null

cat >"$fixture_root/leak.jsonl" <<'EOF'
{"id":"a","source":{"name":"example","url":"https://example.invalid/data"},"license":"Apache-2.0","split":"train","repository":"example/repo","commit":"same","language":"java","task":"review-comment","label":"clean","root_causes":[],"reviewer_comment":"No actionable issue found.","findings":[]}
{"id":"b","source":{"name":"example","url":"https://example.invalid/data"},"license":"Apache-2.0","split":"holdout","repository":"example/repo","commit":"same","language":"java","task":"review-comment","label":"clean","root_causes":[],"reviewer_comment":"No actionable issue found.","findings":[]}
EOF
if python3 "$repo_root/scripts/validate-external-dataset.py" "$fixture_root/leak.jsonl" >/dev/null 2>&1; then
  echo 'expected split leakage to fail' >&2
  exit 1
fi

cat >"$fixture_root/bad-location.jsonl" <<'EOF'
{"id":"bad-location","source":{"name":"example","url":"https://example.invalid/data"},"license":"Apache-2.0","split":"external-smoke","repository":"example/repo","commit":"location","language":"java","task":"audit-finding","label":"positive","root_causes":["security"],"file_path":"src/main/java/Example.java","changed_lines":[10,11],"findings":[{"severity":"P1","path":"src/main/java/Other.java","line":99,"evidence":"not in the changed source"}]}
EOF
if python3 "$repo_root/scripts/validate-external-dataset.py" "$fixture_root/bad-location.jsonl" >/dev/null 2>&1; then
  echo 'expected finding location mismatch to fail' >&2
  exit 1
fi

cat >"$fixture_root/missing-path-metadata.jsonl" <<'EOF'
{"id":"missing-path-metadata","source":{"name":"example","url":"https://example.invalid/data"},"license":"Apache-2.0","split":"external-smoke","repository":"example/repo","commit":"metadata","language":"java","task":"audit-finding","label":"positive","root_causes":["security"],"findings":[{"severity":"P1","path":"src/main/java/Example.java","line":12,"evidence":"location is not anchored"}]}
EOF
if python3 "$repo_root/scripts/validate-external-dataset.py" "$fixture_root/missing-path-metadata.jsonl" >/dev/null 2>&1; then
  echo 'expected missing path metadata to fail' >&2
  exit 1
fi

cat >"$fixture_root/bad-finding-shape.jsonl" <<'EOF'
{"id":"bad-finding-shape","source":{"name":"example","url":"https://example.invalid/data"},"license":"Apache-2.0","split":"external-smoke","repository":"example/repo","commit":"shape","language":"java","task":"audit-finding","label":"positive","root_causes":["security"],"file_path":"src/main/java/Example.java","changed_lines":["20-10"],"findings":[{"severity":"high","path":"src/main/java/Example.java","line":20,"evidence":"   "}]}
EOF
if python3 "$repo_root/scripts/validate-external-dataset.py" "$fixture_root/bad-finding-shape.jsonl" >/dev/null 2>&1; then
  echo 'expected malformed severity/range/evidence to fail' >&2
  exit 1
fi

echo 'external dataset validator regression passed'
