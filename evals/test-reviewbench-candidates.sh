#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-reviewbench.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

cat >"$fixture_root/manifest.json" <<'EOF'
[
  {
    "repo": "review-bench/example",
    "pr_number": 12,
    "pr_url": "https://github.com/review-bench/example/pull/12",
    "base": "1111111111111111111111111111111111111111",
    "head": "2222222222222222222222222222222222222222",
    "title": "Validate input",
    "body": "Review context",
    "language": "Java",
    "repo_size_kb": 100,
    "lines_added": 4,
    "lines_removed": 1,
    "files_changed": 2
  },
  {
    "repo": "https://github.com/review-bench/example.git",
    "pr_number": 12,
    "pr_url": "https://github.com/review-bench/example/pull/12",
    "base": "1111111111111111111111111111111111111111",
    "head": "2222222222222222222222222222222222222222",
    "language": "java"
  },
  {
    "repo": "review-bench/example",
    "pr_number": 13,
    "pr_url": "https://github.com/review-bench/example/pull/13",
    "base": "bad",
    "head": "3333333333333333333333333333333333333333",
    "language": "python"
  },
  {
    "repo": "review-bench/example",
    "pr_number": 14,
    "pr_url": "https://github.com/review-bench/example/pull/14",
    "base": "4444444444444444444444444444444444444444",
    "head": "5555555555555555555555555555555555555555",
    "language": "python"
  }
]
EOF

python3 "$repo_root/scripts/prepare-reviewbench-candidates.py" \
  "$fixture_root/manifest.json" \
  --revision 6666666666666666666666666666666666666666 \
  --language java \
  --output "$fixture_root/output.jsonl" >/dev/null

python3 - "$fixture_root/output.jsonl" <<'PY'
import json
import sys
from pathlib import Path

rows = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
assert len(rows) == 1, rows
row = rows[0]
assert row["repository"] == "github.com/review-bench/example", row
assert row["base_commit"].startswith("1111"), row
assert row["head_commit"].startswith("2222"), row
assert row["language"] == "java", row
assert row["label_status"] == "pending-human-label", row
assert row["golden_status"] == "not-loaded", row
assert row["provenance"]["metadata_only"] is True, row
assert row["provenance"]["source_has_golden_text"] is False, row
assert row["provenance"]["source_has_diff"] is False, row
assert "findings" not in row and "diff" not in row and "source_code" not in row, row
PY

echo 'ReviewBench candidate normalization regression passed'
