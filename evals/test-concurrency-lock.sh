#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-lock.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

# Supply the startup dependencies explicitly instead of inheriting a developer
# installation of Ollama. This PATH cannot resolve the real Ollama or curl.
fake_bin="$fixture_root/bin"
command_log="$fixture_root/unexpected-model-command"
mkdir "$fake_bin"
for dependency in bash python3 git jq awk tr sort rg perl stat mktemp mkdir cat rm rmdir; do
  dependency_path="$(command -v "$dependency")" || {
    echo "concurrency lock regression: missing test prerequisite $dependency" >&2
    exit 1
  }
  ln -s "$dependency_path" "$fake_bin/$dependency"
done
cat >"$fake_bin/ollama" <<'EOF'
#!/bin/bash
printf '%s\n' "${0##*/} was invoked before acquiring the review lock" >>"$LOCAL_REVIEW_LOCK_TEST_COMMAND_LOG"
exit 97
EOF
chmod +x "$fake_bin/ollama"
ln -s "$fake_bin/ollama" "$fake_bin/curl"
[[ "$(PATH="$fake_bin" command -v ollama)" == "$fake_bin/ollama" ]]

lock_dir="$fixture_root/ollama.lock"
mkdir "$lock_dir"
printf '%s\n' "$$" >"$lock_dir/pid"

set +e
output="$(PATH="$fake_bin" TMPDIR="$fixture_root" \
  LOCAL_REVIEW_LOCK_TEST_COMMAND_LOG="$command_log" OLLAMA_REVIEW_LOCK_DIR="$lock_dir" \
  "$repo_root/bin/local-review.sh" --repo "$repo_root" 2>&1)"
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

[[ ! -e "$command_log" ]] || {
  echo 'concurrency lock regression: model/transport command ran despite the held lock' >&2
  cat "$command_log" >&2
  exit 1
}
[[ "$(cat "$lock_dir/pid")" == "$$" ]] || {
  echo 'concurrency lock regression: the existing lock owner was changed' >&2
  exit 1
}

echo 'concurrency lock regression passed'
