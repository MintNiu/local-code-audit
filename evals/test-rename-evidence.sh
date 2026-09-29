#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-rename-test.XXXXXX")"
fake_bin="$fixture_root/bin"
repo="$fixture_root/repo"
capture="$fixture_root/request.json"
tmp_dir="$fixture_root/tmp"
trap 'rm -rf "$fixture_root"' EXIT

mkdir -p "$fake_bin" "$repo/config" "$tmp_dir"

cat >"$fake_bin/ollama" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
previous=""
for argument in "$@"; do
  if [[ "$previous" == "--data-binary" && "$argument" == @* ]]; then
    cp "${argument#@}" "$LOCAL_REVIEW_CAPTURE"
  fi
  previous="$argument"
done
printf '%s\n' '{"response":"未发现阻塞问题","done":true,"done_reason":"stop"}'
EOF
chmod +x "$fake_bin/ollama" "$fake_bin/curl"

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name rename-evidence-test
cat >"$repo/config/application.yml" <<'EOF'
storage:
  endpoint: https://oss.example.invalid
  access-key-id: ${OSS_ACCESS_KEY_ID}
EOF
cat >"$repo/config/rewritten.yml" <<'EOF'
feature:
  enabled: false
EOF
git -C "$repo" add .
git -C "$repo" commit -qm base

mkdir -p "$repo/config/migration"
git -C "$repo" mv config/application.yml config/migration/application.yml
git -C "$repo" mv config/rewritten.yml config/migration/rewritten.yml
printf '  enabled: true\n' >>"$repo/config/migration/rewritten.yml"

PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  OLLAMA_REVIEW_NUM_CTX=65536 \
  OLLAMA_REVIEW_TOTAL_TIMEOUT_SECONDS=120 \
  "$repo_root/bin/local-review.sh" --repo "$repo" >/dev/null

grep -F -- 'Git 精确重命名证据' "$capture" >/dev/null || {
  echo 'missing exact rename evidence section' >&2
  exit 1
}
grep -F -- 'R100' "$capture" >/dev/null || {
  echo 'missing R100 marker in exact rename evidence' >&2
  exit 1
}
grep -F -- 'config/application.yml -> config/migration/application.yml' "$capture" >/dev/null || {
  echo 'missing old-to-new exact rename path' >&2
  exit 1
}
if grep -F -- 'unstaged：config/rewritten.yml -> config/migration/rewritten.yml' "$capture" >/dev/null; then
  echo 'content-changing rename was incorrectly marked as exact R100' >&2
  exit 1
fi
grep -F -- '不得把旧路径删除本身当作独立迁移缺陷' "$capture" >/dev/null || {
  echo 'missing narrow anti-duplicate rename instruction' >&2
  exit 1
}

printf 'rename evidence regression passed\n'
