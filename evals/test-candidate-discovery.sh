#!/usr/bin/env bash
set -euo pipefail

script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temp_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-discovery.XXXXXX")"
trap 'rm -rf "$temp_root"' EXIT

workspace="$temp_root/workspace"
mkdir -p "$workspace/repo-a" "$workspace/repo-b"
for repo in repo-a repo-b; do
  git -C "$workspace/$repo" init -q
  git -C "$workspace/$repo" config user.name tester
  git -C "$workspace/$repo" config user.email tester@example.invalid
  printf 'base\n' >"$workspace/$repo/file.txt"
  git -C "$workspace/$repo" add file.txt
  git -C "$workspace/$repo" commit -q -m '基础提交'
  printf 'change\n' >>"$workspace/$repo/file.txt"
  git -C "$workspace/$repo" add file.txt
  git -C "$workspace/$repo" commit -q -m '新增待审提交'
done

excluded="$temp_root/excluded.tsv"
cat >"$excluded" <<'EOF'
repo	commit
repo-a	0000000000000000000000000000000000000000
EOF

output="$temp_root/discovered.tsv"
python3 "$script_root/scripts/discover-candidates.py" \
  --workspace-root "$workspace" \
  --since 2000-01-01 \
  --repo repo-a \
  --out "$output" >/dev/null

python3 - "$output" <<'PY'
import csv
import sys
from pathlib import Path

rows = list(csv.DictReader(Path(sys.argv[1]).read_text(encoding="utf-8").splitlines(), delimiter="\t"))
assert len(rows) == 1, rows
row = rows[0]
assert row["repo"] == "repo-a"
assert len(row["commit"]) == 40 and len(row["parent"]) == 40
assert row["feature_cluster"].startswith("unclassified-")
assert row["status"] == "pending-human-label"
PY

if python3 "$script_root/scripts/discover-candidates.py" \
  --workspace-root "$workspace" \
  --since 2000-01-01 \
  --out "$output" >/dev/null 2>&1; then
  echo "candidate discovery overwrite guard failed" >&2
  exit 1
fi

echo "candidate discovery regression passed"
