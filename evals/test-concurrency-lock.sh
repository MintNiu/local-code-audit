#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-lock.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

lock_dir="$fixture_root/ollama.lock"
mkdir "$lock_dir"
printf '%s\n' "$$" >"$lock_dir/pid"

set +e
output="$(OLLAMA_REVIEW_LOCK_DIR="$lock_dir" "$repo_root/bin/local-review.sh" --repo "$repo_root" 2>&1)"
status=$?
set -e

[[ "$status" == 75 ]] || {
  echo "concurrency lock regression: expected exit 75, got $status" >&2
  printf '%s\n' "$output" >&2
  exit 1
}
grep -F '已有 Ollama 审查进程正在运行' <<<"$output" >/dev/null || {
  echo 'concurrency lock regression: missing fail-closed diagnostic' >&2
  printf '%s\n' "$output" >&2
  exit 1
}

echo 'concurrency lock regression passed'
