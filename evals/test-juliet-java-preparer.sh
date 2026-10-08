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
  <testcase><file path="src/testcases/CWE259_Hard_Coded_Password/CWE259_Hard_Coded_Password__passwordAuth_01.java">
    <flaw line="3" name="CWE-259: hard-coded password">
  </file></testcase>
  <testcase><file path="src/testcases/CWE259_Hard_Coded_Password/CWE259_Hard_Coded_Password__passwordAuth_01_goodG2B.java"/></testcase>
  <testcase><file path="src\\testcases\\CWE321_Hard_Coded_Cryptographic_Key\\CWE321_Hard_Coded_Password__passwordAuth_01.java">
    <flaw line="7" name="CWE-321: hard-coded cryptographic key">
  </file></testcase>
</container>
'''
bad = 'class Bad { void run() { String password = "secret"; } }\n'
good = 'class Good { void run() { String password = readSecret(); } }\n'
other_bad = 'class OtherBad { void run() { String key = "secret"; } }\n'
with zipfile.ZipFile(archive, 'w') as handle:
    handle.writestr('Java/manifest.xml', manifest)
    handle.writestr('Java/src/testcases/CWE259_Hard_Coded_Password/CWE259_Hard_Coded_Password__passwordAuth_01.java', bad)
    handle.writestr('Java/src/testcases/CWE259_Hard_Coded_Password/CWE259_Hard_Coded_Password__passwordAuth_01_goodG2B.java', good)
    handle.writestr('Java/src/testcases/CWE321_Hard_Coded_Cryptographic_Key/CWE321_Hard_Coded_Password__passwordAuth_01.java', other_bad)
PY

python3 "$repo_root/scripts/prepare-juliet-java.py" \
  "$fixture_root/input.zip" "$fixture_root/output.jsonl" --cwe CWE259 CWE321 --limit-per-cwe 1 >/dev/null
python3 "$repo_root/scripts/validate-external-dataset.py" "$fixture_root/output.jsonl" | grep -F 'valid external dataset:' >/dev/null
grep -F 'CWE-259: hard-coded password' "$fixture_root/output.jsonl" >/dev/null
grep -F '"label": "clean"' "$fixture_root/output.jsonl" >/dev/null
grep -F 'CWE-321: hard-coded cryptographic key' "$fixture_root/output.jsonl" >/dev/null
python3 - "$fixture_root/output.jsonl" <<'PY'
import json
import sys

rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
positives = {row["root_causes"][0]: row for row in rows if row["label"] == "positive"}
assert positives["cwe259"]["findings"][0]["line"] == 3
assert positives["cwe321"]["findings"][0]["line"] == 7
PY

echo 'Juliet Java preparer regression passed'
