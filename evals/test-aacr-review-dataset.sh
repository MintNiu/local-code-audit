#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-aacr.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

cat >"$fixture_root/aacr.json" <<'EOF'
[
  {
    "project_main_language": "Java",
    "githubPrUrl": "https://github.com/example/project/pull/7",
    "target_commit": "0123456789abcdef",
    "comments": [
      {"is_ai_comment": false, "path": "src/Main.java", "from_line": 12, "to_line": 12, "category": "Security Vulnerability", "note": "Use the authenticated subject instead of the caller supplied id."},
      {"is_ai_comment": true, "path": "src/Main.java", "from_line": 12, "to_line": 12, "category": "Security Vulnerability", "note": "enhanced duplicate"}
    ]
  },
  {
    "project_main_language": "Java",
    "githubPrUrl": "https://github.com/example/project/pull/8",
    "target_commit": "fedcba9876543210",
    "comments": [
      {"is_ai_comment": false, "path": "src/Other.java", "from_line": 5, "to_line": 6, "category": "Code Defect", "note": "The new branch drops the previous error result."}
    ]
  }
]
EOF

python3 "$repo_root/scripts/prepare-aacr-review-dataset.py" \
  "$fixture_root/aacr.json" --output "$fixture_root/normalized.jsonl" --limit-per-language 2
python3 "$repo_root/scripts/validate-external-dataset.py" "$fixture_root/normalized.jsonl"
[[ "$(wc -l <"$fixture_root/normalized.jsonl" | tr -d ' ')" == 2 ]]
! grep -F 'enhanced duplicate' "$fixture_root/normalized.jsonl" >/dev/null
echo 'AACR review dataset regression passed'
