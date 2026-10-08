#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-vcc-eval.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

cat >"$fixture_root/input.json" <<'EOF'
[
  {
    "cve": "CVE-2024-0001",
    "cwe": "CWE-79",
    "repository": "https://github.com/apache/example.git",
    "fixing": ["fix111"],
    "introducing": "intro111",
    "introducing_lines": {"src/main/java/example/Controller.java": "12-14;16"},
    "fixing_lines": {"src/main/java/example/Controller.java": "20"},
    "days_between": 100
  },
  {
    "cve": "CVE-2024-0001",
    "cwe": "CWE-79",
    "repository": "https://gitbox.apache.org/repos/asf/example.git",
    "fixing": ["fix111"],
    "introducing": "intro111",
    "introducing_lines": {"src/main/java/example/Controller.java": "12-14;16"},
    "fixing_lines": {"src/main/java/example/Controller.java": "20"}
  },
  {
    "cve": "CVE-2024-0002",
    "cwe": "CWE-611",
    "repository": "https://github.com/example/xml",
    "fixing": [],
    "introducing": "intro222",
    "introducing_lines": {},
    "fixing_lines": {"src/main/java/example/Xml.java": "30"}
  },
  {
    "cve": "CVE-2024-0003",
    "cwe": "CWE-20",
    "repository": "https://github.com/example/input",
    "fixing": ["fix333"],
    "introducing": "intro333",
    "introducing_lines": {"src/main/java/example/Input.java": "0"},
    "fixing_lines": {"src/main/java/example/Input.java": "40"}
  }
]
EOF

python3 "$repo_root/scripts/prepare-vcc-eval-candidates.py" \
  "$fixture_root/input.json" --output "$fixture_root/output.jsonl" >/dev/null

python3 - "$fixture_root/output.jsonl" <<'PY'
import json
import sys
from pathlib import Path

rows = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
assert len(rows) == 3, rows
assert rows[0]["repository"] == "apache/example", rows[0]
assert rows[0]["candidate_eligible"] is True, rows[0]
assert rows[0]["introducing_lines"]["src/main/java/example/Controller.java"] == [
    {"start": 12, "end": 14}, {"start": 16, "end": 16}
]
missing = next(row for row in rows if row["cve"] == "CVE-2024-0002")
assert missing["candidate_eligible"] is False
invalid = next(row for row in rows if row["cve"] == "CVE-2024-0003")
assert invalid["line_label_status"]["introducing"] == "invalid"
assert all(row["label_status"] == "pending-human-label" for row in rows)
assert all("source_code" not in row and "diff" not in row for row in rows)
PY

echo 'VCC-Eval candidate normalization regression passed'
