#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-external-dataset.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

cat >"$fixture_root/valid.jsonl" <<'EOF'
{"id":"java-001","source":{"name":"example","url":"https://example.invalid/data"},"license":"Apache-2.0","split":"external-smoke","repository":"example/repo","commit":"abc123","language":"java","framework":"spring","label":"positive","root_causes":["tenant-isolation"],"findings":[{"severity":"P1","path":"src/main/java/Example.java","line":12,"evidence":"tenant predicate is missing"}]}
{"id":"ts-001","source":{"name":"example","url":"https://example.invalid/data"},"license":"MIT","split":"dev","repository":"example/repo-ts","commit":"def456","language":"typescript","framework":"vue","label":"clean","root_causes":[],"findings":[]}
EOF
python3 "$repo_root/scripts/validate-external-dataset.py" "$fixture_root/valid.jsonl" | grep -F 'valid external dataset:' >/dev/null

cat >"$fixture_root/leak.jsonl" <<'EOF'
{"id":"a","source":{"name":"example","url":"https://example.invalid/data"},"license":"Apache-2.0","split":"train","repository":"example/repo","commit":"same","language":"java","label":"clean","root_causes":[],"findings":[]}
{"id":"b","source":{"name":"example","url":"https://example.invalid/data"},"license":"Apache-2.0","split":"holdout","repository":"example/repo","commit":"same","language":"java","label":"clean","root_causes":[],"findings":[]}
EOF
if python3 "$repo_root/scripts/validate-external-dataset.py" "$fixture_root/leak.jsonl" >/dev/null 2>&1; then
  echo 'expected split leakage to fail' >&2
  exit 1
fi

echo 'external dataset validator regression passed'
