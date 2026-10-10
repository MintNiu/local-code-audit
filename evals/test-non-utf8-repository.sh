#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-non-utf8.XXXXXX")"
fake_bin="$fixture_root/bin"
repo="$fixture_root/repo"
stderr_file="$fixture_root/stderr.log"
trap 'rm -rf "$fixture_root"' EXIT
mkdir -p "$fake_bin" "$repo/src/main/java/example"

cat >"$fake_bin/ollama" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"未发现阻塞问题","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/ollama" "$fake_bin/curl"

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name non-utf8-repository
git -C "$repo" commit --allow-empty -qm 基线

# Legacy repositories can contain source/Javadoc bytes outside UTF-8.  The
# reviewer must preserve the diff and fail closed on review semantics, not
# abort in an awk locale conversion before deterministic checks run.
printf 'package example;\nclass Legacy { // byte: \377\n}\n' >"$repo/src/main/java/example/Legacy.java"

output="$(PATH="$fake_bin:$PATH" TMPDIR="$fixture_root" \
  OLLAMA_REVIEW_LOCK_DIR="$fixture_root/lock" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_NUM_CTX=65536 \
  OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  OLLAMA_REVIEW_TOTAL_TIMEOUT_SECONDS=120 \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo" 2>"$stderr_file")"
printf '%s\n' "$output" | grep -Fx '未发现阻塞问题' >/dev/null
if grep -Eq 'multibyte conversion failure|towc:' "$stderr_file"; then
  echo 'non-UTF-8 source triggered an awk locale failure' >&2
  cat "$stderr_file" >&2
  printf '%s\n' "$output" >&2
  exit 1
fi

echo 'non-UTF-8 repository regression passed'
