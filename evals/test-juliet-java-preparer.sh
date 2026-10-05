#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-juliet-preparer.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

python3 - "$fixture_root/input.zip" <<'PY'
import sys
import zipfile
from pathlib import Path

archive = Path(sys.argv[1])
manifest = '''<container>
  <testcase><file path="CWE259_Hard_Coded_Password__passwordAuth_01.java">
    <flaw line="3" name="CWE-259: hard-coded password">
  </file></testcase>
  <testcase><file path="CWE259_Hard_Coded_Password__passwordAuth_01_goodG2B.java"/></testcase>
</container>
'''
bad = 'class Bad { void run() { String password = "secret"; } }\n'
good = 'class Good { void run() { String password = readSecret(); } }\n'
with zipfile.ZipFile(archive, 'w') as handle:
    handle.writestr('Java/manifest.xml', manifest)
    handle.writestr('Java/src/testcases/CWE259_Hard_Coded_Password/CWE259_Hard_Coded_Password__passwordAuth_01.java', bad)
    handle.writestr('Java/src/testcases/CWE259_Hard_Coded_Password/CWE259_Hard_Coded_Password__passwordAuth_01_goodG2B.java', good)
PY

python3 "$repo_root/scripts/prepare-juliet-java.py" \
  "$fixture_root/input.zip" "$fixture_root/output.jsonl" --cwe CWE259 --limit-per-cwe 1 >/dev/null
python3 "$repo_root/scripts/validate-external-dataset.py" "$fixture_root/output.jsonl" | grep -F 'valid external dataset:' >/dev/null
grep -F 'CWE-259: hard-coded password' "$fixture_root/output.jsonl" >/dev/null
grep -F '"label": "clean"' "$fixture_root/output.jsonl" >/dev/null

echo 'Juliet Java preparer regression passed'
