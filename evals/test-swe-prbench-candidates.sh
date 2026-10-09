#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-swe-prbench.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

cat >"$fixture_root/prs.jsonl" <<'EOF'
{"task_id":"owner/repo__42","repo":"owner/repo","language":"Java","difficulty":"Type2_Contextual","rvs_score":0.52,"base_commit":"1111111111111111111111111111111111111111","head_commit":"2222222222222222222222222222222222222222","pr_url":"https://github.com/owner/repo/pull/42","num_substantive_comments":3}
{"task_id":"owner/repo__42","repo":"https://github.com/owner/repo.git","language":"java","base_commit":"1111111111111111111111111111111111111111","head_commit":"2222222222222222222222222222222222222222"}
{"task_id":"owner/repo__43","language":"Python","base_commit":"3333333333333333333333333333333333333333","head_commit":"4444444444444444444444444444444444444444"}
{"task_id":"owner/repo__44","repo":"owner/repo","language":"Go","base_commit":"bad","head_commit":"5555555555555555555555555555555555555555"}
EOF

python3 "$repo_root/scripts/prepare-swe-prbench-candidates.py" \
  "$fixture_root/prs.jsonl" \
  --revision b87f5797aef3ed2c3153bb1304ea4d801d36ba6e \
  --language java --output "$fixture_root/output.jsonl" >/dev/null

python3 - "$fixture_root/output.jsonl" <<'PY'
import json
import sys
from pathlib import Path

rows = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
assert len(rows) == 1, rows
row = rows[0]
assert row["repository"] == "github.com/owner/repo", row
assert row["pr_number"] == 42, row
assert row["language"] == "java", row
assert row["difficulty"] == "Type2_Contextual", row
assert row["rvs_score"] == 0.52, row
assert row["label_status"] == "pending-human-label", row
assert row["golden_status"] == "not-loaded", row
assert row["provenance"]["metadata_only"] is True, row
assert row["provenance"]["source_has_golden_text"] is True, row
assert "comments" not in row and "diff_patch" not in row and "context" not in row, row
PY

echo 'SWE-PRBench candidate normalization regression passed'
