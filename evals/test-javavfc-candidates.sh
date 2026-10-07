#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-javavfc.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

cat >"$fixture_root/input.jsonl" <<'EOF'
{"commit_link":"https://github.com/example/java-repo/commit/abcdef1234567890","message":"Fix security lock race","author":"a","date":1,"diff_raw":"diff --git a/src/main/java/example/A.java b/src/main/java/example/A.java\n@@ -1,2 +1,4 @@\n+public class A {}"}
{"commit_link":"https://github.com/example/java-repo/commit/abcdef1234567890","message":"duplicate metadata","author":"b","date":2,"diff_raw":"diff --git a/src/main/java/example/A.java b/src/main/java/example/A.java\n@@ -1,2 +1,4 @@\n+public class A {}"}
{"commit_link":"https://github.com/example/script/commit/1111111111111111","message":"docs only","author":"c","date":3,"diff_raw":"diff --git a/README.md b/README.md\n@@ -1 +1 @@\n+docs"}
{"commit_link":"https://github.com/example/mixed/commit/2222222222222222","message":"close resource","author":"d","date":4,"diff_raw":"diff --git a/src/main/java/example/B.java b/src/main/java/example/B.java\n@@ -10,1 +10,2 @@\n+close();\ndiff --git a/README.md b/README.md\n@@ -1 +1 @@\n+docs"}
EOF

python3 "$repo_root/scripts/prepare-javavfc-candidates.py" "$fixture_root/input.jsonl" \
  --output "$fixture_root/output.jsonl"
python3 - "$fixture_root/output.jsonl" <<'PY'
import json
import sys
from pathlib import Path

rows = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
assert len(rows) == 2, rows
assert all(row["language"] == "java" for row in rows)
assert all(row["label_status"] == "pending-human-label" for row in rows)
assert all(row["task"] == "patch-candidate" for row in rows)
assert all("diff_raw" not in row and "source_code" not in row for row in rows)
assert rows[0]["root_cause_hints"] == ["concurrency", "security"]
assert rows[1]["diff_files"] == ["src/main/java/example/B.java"]
PY

echo 'JavaVFC candidate normalization regression passed'
