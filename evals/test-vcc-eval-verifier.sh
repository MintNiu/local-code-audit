#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-vcc-verifier.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

mkdir -p "$fixture_root/repo/src/main/java/example"
python3 - "$fixture_root/repo/src/main/java/example/Sample.java" <<'PY'
import sys
from pathlib import Path
Path(sys.argv[1]).write_text(
    "package example;\nclass Sample {\n    int safe = 1;\n}\n",
    encoding="utf-8",
)
PY
git -C "$fixture_root/repo" init -q
git -C "$fixture_root/repo" config user.email test@example.invalid
git -C "$fixture_root/repo" config user.name 'VCC Test'
git -C "$fixture_root/repo" add .
git -C "$fixture_root/repo" commit -q -m base
base_sha="$(git -C "$fixture_root/repo" rev-parse HEAD)"
python3 - "$fixture_root/repo/src/main/java/example/Sample.java" <<'PY'
import sys
from pathlib import Path
Path(sys.argv[1]).write_text(
    "package example;\nclass Sample {\n    int safe = 1;\n    String value = request.getParameter(\"value\");\n}\n",
    encoding="utf-8",
)
PY
git -C "$fixture_root/repo" add .
git -C "$fixture_root/repo" commit -q -m introduce
intro_sha="$(git -C "$fixture_root/repo" rev-parse HEAD)"

python3 - "$fixture_root/input.jsonl" "$fixture_root/repo-map.json" "$fixture_root/repo" "$intro_sha" <<'PY'
import json
import sys
from pathlib import Path

output, repo_map, repo, intro = sys.argv[1:]
rows = [
    {
        "id": "valid",
        "repository": "github.com/example/repo",
        "commit": intro,
        "introducing_lines": {"src/main/java/example/Sample.java": [{"start": 4, "end": 4}]},
    },
    {
        "id": "not-added",
        "repository": "github.com/example/repo",
        "commit": intro,
        "introducing_lines": {"src/main/java/example/Sample.java": [{"start": 3, "end": 3}]},
    },
    {
        "id": "missing-repo",
        "repository": "github.com/example/missing",
        "commit": intro,
        "introducing_lines": {"src/main/java/example/Sample.java": [{"start": 4, "end": 4}]},
    },
]
Path(output).write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")
Path(repo_map).write_text(json.dumps({"github.com/example/repo": repo}), encoding="utf-8")
PY

python3 "$repo_root/scripts/verify-vcc-eval-candidates.py" \
  "$fixture_root/input.jsonl" \
  --repo-map "$fixture_root/repo-map.json" \
  --output "$fixture_root/output.jsonl" >/dev/null

python3 - "$fixture_root/output.jsonl" <<'PY'
import json
import sys
from pathlib import Path

rows = {row["id"]: row for row in map(json.loads, Path(sys.argv[1]).read_text().splitlines())}
assert rows["valid"]["verification"]["status"] == "verified-intro-lines"
assert rows["valid"]["verified_candidate"] is True
assert rows["not-added"]["verification"]["status"] == "line-not-added"
assert rows["missing-repo"]["verification"]["status"] == "missing-local-repo"
assert all(row["label_status"] == "pending-human-label" for row in rows.values())
PY

echo 'VCC-Eval local verifier regression passed'
