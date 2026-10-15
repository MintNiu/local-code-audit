#!/usr/bin/env bash
set -euo pipefail

# A model can satisfy the paragraph fields while leaving the human-readable
# issue title empty (`P1 path:line -`).  The review runner must reject that
# response instead of returning a low-signal finding as if it were complete.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The producer contract must require the same non-empty title as the gate.
# A bare `path:line -` example used to invite output the validator rejected.
for protocol_file in "$repo_root/bin/local-review.sh" "$repo_root/config/Modelfile"; do
  grep -F 'P1 path/to/File.java:12-15 - 具体问题标题' "$protocol_file" >/dev/null
  grep -F '同一行的 ` - ` 后写出非空' "$protocol_file" >/dev/null
done
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-response-validation.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
fake_bin="$fixture_root/bin"
repo="$fixture_root/repo"
mkdir -p "$fake_bin" "$repo/src/main/java/example"

cat >"$fake_bin/ollama" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${VALIDATION_RESPONSE:-}" ]]; then
  jq -n --arg response "$VALIDATION_RESPONSE" '{response: $response, done: true, done_reason: "stop"}'
  exit 0
fi
printf '%s\n' '{"response":"P1 src/main/java/example/Sample.java:5 -\n影响：返回值可能不符合调用方预期。\n修复建议：核对实现与业务契约。\n验证方式：执行边界和回归测试。","done":true,"done_reason":"stop"}'
EOF
chmod +x "$fake_bin/ollama" "$fake_bin/curl"

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name response-validation-test
cat >"$repo/src/main/java/example/Sample.java" <<'EOF'
package example;

final class Sample {
    int value() {
        return 1;
    }
}
EOF
git -C "$repo" add .
git -C "$repo" commit -qm base
sed -i '' 's/return 1;/return 2;/' "$repo/src/main/java/example/Sample.java"

stdout_file="$fixture_root/stdout.txt"
stderr_file="$fixture_root/stderr.txt"
set +e
PATH="$fake_bin:$PATH" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_LOCK_DIR="$fixture_root/lock" \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  OLLAMA_REVIEW_RETRY_ATTEMPTS=0 \
  OLLAMA_REVIEW_NUM_CTX=16384 \
  OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  "$repo_root/bin/local-review.sh" --repo "$repo" >"$stdout_file" 2>"$stderr_file"
status=$?
set -e

[[ "$status" -ne 0 ]] || {
  echo 'empty-title model response was accepted' >&2
  cat "$stdout_file" >&2
  cat "$stderr_file" >&2
  exit 1
}
grep -F '模型输出缺少可验证的严重级别或文件/行号' "$stderr_file" >/dev/null || {
  echo 'empty-title rejection did not use the response validation path' >&2
  cat "$stderr_file" >&2
  exit 1
}
grep -F 'P1 src/main/java/example/Sample.java:5 -' "$stderr_file" >/dev/null || {
  echo 'empty-title response was not preserved for diagnostics' >&2
  cat "$stderr_file" >&2
  exit 1
}
[[ ! -s "$stdout_file" ]] || {
  echo 'invalid empty-title response leaked to stdout' >&2
  cat "$stdout_file" >&2
  exit 1
}

for response in \
  $'P1 src/main/java/example/Sample.java:5 - 返回值违背固定值契约。\n影响：调用方收到错误的值。\n修复建议：恢复契约要求的返回值。\n验证方式：执行返回值断言。' \
  '未发现阻塞问题'; do
  accepted="$(PATH="$fake_bin:$PATH" \
    VALIDATION_RESPONSE="$response" \
    LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
    OLLAMA_REVIEW_LOCK_DIR="$fixture_root/lock" \
    OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
    OLLAMA_REVIEW_NUM_CTX=16384 \
    "$repo_root/bin/local-review.sh" --repo "$repo")"
  [[ "$accepted" == "$response" ]] || {
    echo 'valid title or clean response was changed by the output gate' >&2
    printf '%s\n' "$accepted" >&2
    exit 1
  }
done

printf 'empty-title response validation regression passed\n'
