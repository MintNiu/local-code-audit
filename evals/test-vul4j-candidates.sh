#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-vul4j.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

cat >"$fixture_root/input.csv" <<'EOF'
no,vul_id,cve_id,cwe_id,cwe_name,repo_slug,human_patch,src,src_classes,failing_module,failing_tests
1,VUL4J-1,CVE-1,CWE-611,XXE,example/batik,https://github.com/example/batik/commit/abcdef1234567890,src/main/java,Parser.java,core,ParserTest
2,VUL4J-1,CVE-1,CWE-611,XXE,example/batik,https://github.com/example/batik/commit/abcdef1234567890,src/main/java,Parser.java,core,ParserTest
3,VUL4J-2,CVE-2,CWE-22,Path Traversal,example/wiki,https://github.com/example/Vul4J/compare/a..b,src/main/java,Wiki.java,core,WikiTest
EOF

python3 "$repo_root/scripts/prepare-vul4j-candidates.py" "$fixture_root/input.csv" \
  --output "$fixture_root/output.jsonl"
python3 - "$fixture_root/output.jsonl" <<'PY'
import json
import sys
from pathlib import Path

rows = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
assert len(rows) == 1, rows
row = rows[0]
assert row["language"] == "java"
assert row["label_status"] == "pending-human-label"
assert row["task"] == "patch-candidate"
assert row["root_cause_hints"] == ["CWE-611", "XXE"]
assert row["src_classes"] == "Parser.java"
assert row["provenance"]["source_has_line_findings"] is False
assert "patch" not in row or "diff" not in row
PY

echo 'Vul4J candidate normalization regression passed'
