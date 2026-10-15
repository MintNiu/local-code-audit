#!/usr/bin/env bash
set -euo pipefail

# Inspect actual Ollama JSON requests without contacting a model. Small diffs
# must not lose useful context merely because a worst-case shard would not fit.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-prompt-budget.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
fixture_repo="$fixture_root/repo"
fake_bin="$fixture_root/bin"
mkdir -p "$fixture_repo" "$fake_bin" "$fixture_root/tmp"

cat >"$fake_bin/ollama" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
capture_dir="${LOCAL_REVIEW_BUDGET_CAPTURE_DIR:?}"
count=0
if [[ -f "$capture_dir/count" ]]; then count="$(<"$capture_dir/count")"; fi
count=$((count + 1))
printf '%s\n' "$count" >"$capture_dir/count"
payload=""
for argument in "$@"; do
  if [[ "$argument" == @* ]]; then payload="${argument#@}"; fi
done
[[ -f "$payload" ]] || exit 2
cp "$payload" "$capture_dir/request-$(printf '%03d' "$count").json"
if [[ "${LOCAL_REVIEW_BUDGET_INITIAL_LENGTH:-false}" == true && "$count" == 1 ]]; then
  printf '%s\n' '{"response":"未发现阻塞问题","done":true,"done_reason":"length"}'
  exit 0
fi
printf '%s\n' '{"response":"未发现阻塞问题","done":true,"done_reason":"stop"}'
EOF
chmod +x "$fake_bin/ollama" "$fake_bin/curl"

git -C "$fixture_repo" init -q
git -C "$fixture_repo" config user.email test@example.invalid
git -C "$fixture_repo" config user.name prompt-budget-test
awk 'BEGIN {
  print "final class BudgetSample {"
  print "    String forward(String token) {"
  print "        String target = \"https://service.example/data\";"
  for (i = 1; i <= 240; i++) {
    printf "        // Unchanged method context %03d: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n", i
  }
  print "        return target;"
  print "    }"
  print "}"
}' >"$fixture_repo/BudgetSample.java"
git -C "$fixture_repo" add BudgetSample.java
git -C "$fixture_repo" commit -qm baseline
sed 's@https://service.example/data";@https://service.example/data?x-token=" + token;@' \
  "$fixture_repo/BudgetSample.java" >"$fixture_root/changed.java"
cp "$fixture_root/changed.java" "$fixture_repo/BudgetSample.java"

examples="$fixture_root/examples.md"
awk 'BEGIN {
  print "EXAMPLE_CONTEXT_MUST_SURVIVE_SMALL_DIFF"
  for (i = 1; i <= 40; i++) {
    print "Safe example: report only an evidenced changed-line defect."
  }
}' >"$examples"
large_examples="$fixture_root/large-examples.md"
awk 'BEGIN {
  print "OVERSIZED_OPTIONAL_EXAMPLE_MARKER"
  for (i = 1; i <= 1500; i++) {
    print "Optional example material must not consume mandatory input space."
  }
}' >"$large_examples"

run_review() {
  local capture_dir="$1"
  shift
  mkdir -p "$capture_dir"
  (
    export PATH="$fake_bin:$PATH"
    export TMPDIR="$fixture_root/tmp"
    export LOCAL_REVIEW_BUDGET_CAPTURE_DIR="$capture_dir"
    export LOCAL_REVIEW_EXAMPLES_FILE="$examples"
    export OLLAMA_REVIEW_MODEL=devstral-small-2-review
    export OLLAMA_REVIEW_RETRY_ATTEMPTS=0
    export OLLAMA_REVIEW_TIMEOUT_SECONDS=30
    export OLLAMA_REVIEW_TOTAL_TIMEOUT_SECONDS=120
    export OLLAMA_REVIEW_LOCK_DIR="$capture_dir/lock"
    export OLLAMA_REVIEW_MAX_DIFF_BYTES=6000
    export OLLAMA_REVIEW_NUM_CTX=16384
    export OLLAMA_REVIEW_NUM_PREDICT=4096
    export OLLAMA_REVIEW_CHUNK_NUM_PREDICT=4096
    export OLLAMA_REVIEW_INPUT_RESERVE_TOKENS=1024
    export OLLAMA_REVIEW_JAVA_METHOD_SIDECAR=false
    unset OLLAMA_REVIEW_SPECIALIST_CHANNEL
    for assignment in "$@"; do export "$assignment"; done
    review_status=0
    "$repo_root/bin/local-review.sh" --repo "$fixture_repo" \
      >"$capture_dir/output" 2>"$capture_dir/stderr" || review_status=$?
    if (( review_status != 0 )); then cat "$capture_dir/stderr" >&2; fi
    exit "$review_status"
  )
}

assert_one_request() {
  [[ -f "$1/count" && "$(<"$1/count")" == 1 ]] || {
    echo "expected one request: $1" >&2
    cat "$1/stderr" >&2
    exit 1
  }
}

assert_contains() {
  local path="$1"
  local text="$2"
  grep -F -- "$text" "$path" >/dev/null || {
    echo "missing expected text: $text ($path)" >&2
    cat "$path" >&2
    exit 1
  }
}

small_capture="$fixture_root/small"
run_review "$small_capture" \
  "OLLAMA_REVIEW_RESOLVED_CHUNK_BYTES_FILE=$small_capture/budget.tsv"
assert_one_request "$small_capture"
assert_contains "$small_capture/budget.tsv" $'budget_mode\tinitial'
assert_contains "$small_capture/budget.tsv" $'chunk_budget_preflight_reserve_tokens\t0'
jq -e '.options.num_ctx == 16384 and .options.num_predict == 4096' \
  "$small_capture/request-001.json" >/dev/null
jq -r '.prompt' "$small_capture/request-001.json" >"$small_capture/prompt"
assert_contains "$small_capture/prompt" EXAMPLE_CONTEXT_MUST_SURVIVE_SMALL_DIFF
assert_contains "$small_capture/prompt" '--- 构建预检（确定性证据） ---'
assert_contains "$small_capture/prompt" '凭据值被拼接到 URL'
assert_contains "$small_capture/prompt" '+        String target = "https://service.example/data?x-token=" + token;'
assert_contains "$small_capture/output" '凭据值被拼接到 URL'
if grep -F '移除人工示例' "$small_capture/stderr" >/dev/null; then
  echo 'a fitting small diff unnecessarily discarded its examples' >&2
  exit 1
fi

# Oversized optional examples can be omitted without hiding deterministic
# findings or deleting the changed lines, for both unsplit and split reviews.
for shape in unsplit split; do
  capture="$fixture_root/large-examples-$shape"
  diff_cap=6000
  if [[ "$shape" == split ]]; then
    diff_cap=1000
    awk 'BEGIN { for (i = 1; i <= 120; i++) printf "additional changed line %03d\n", i }' \
      >"$fixture_repo/Noise.txt"
  fi
  run_review "$capture" \
    "LOCAL_REVIEW_EXAMPLES_FILE=$large_examples" \
    "OLLAMA_REVIEW_MAX_DIFF_BYTES=$diff_cap"
  if [[ "$shape" == unsplit ]]; then assert_one_request "$capture"; fi
  [[ -f "$capture/count" ]] || exit 1
  jq -r '.prompt' "$capture"/request-*.json >"$capture/prompt"
  if grep -F OVERSIZED_OPTIONAL_EXAMPLE_MARKER "$capture/prompt" >/dev/null; then
    echo "$shape review sent oversized examples" >&2
    exit 1
  fi
  assert_contains "$capture/stderr" '移除人工示例'
  assert_contains "$capture/prompt" '+        String target = "https://service.example/data?x-token=" + token;'
  assert_contains "$capture/output" '凭据值被拼接到 URL'
  if [[ "$shape" == unsplit ]]; then
    assert_contains "$capture/prompt" '凭据值被拼接到 URL'
  else
    assert_contains "$capture/stderr" '分片'
    [[ "$(<"$capture/count")" -gt 1 ]] || {
      echo 'split review did not make multiple requests' >&2
      exit 1
    }
    rm "$fixture_repo/Noise.txt"
  fi
done

# The exact small-diff fast path must not approve a genuinely over-budget
# mandatory prompt. Even the fake HTTP transport must never be invoked.
overflow_capture="$fixture_root/mandatory-overflow"
if run_review "$overflow_capture" OLLAMA_REVIEW_NUM_CTX=8192; then
  echo 'mandatory prompt overflow was accepted' >&2
  exit 1
fi
assert_contains "$overflow_capture/stderr" '超过可用预算'
[[ ! -f "$overflow_capture/count" ]] || {
  echo 'mandatory prompt overflow reached Ollama' >&2
  exit 1
}

# A long unchanged method fits the sidecar byte caps but not the actual
# 16K/4096 input budget. Fallback must preserve the exact original request,
# including examples and preflight; it must not bypass the request guard.
sidecar_capture="$fixture_root/sidecar-overflow"
run_review "$sidecar_capture" \
  OLLAMA_REVIEW_JAVA_METHOD_SIDECAR=true \
  OLLAMA_REVIEW_JAVA_METHOD_SIDECAR_MAX_BYTES=60000 \
  OLLAMA_REVIEW_JAVA_METHOD_SIDECAR_MAX_METHOD_BYTES=60000 \
  OLLAMA_REVIEW_JAVA_METHOD_SIDECAR_MAX_METHODS=6
assert_one_request "$sidecar_capture"
assert_contains "$sidecar_capture/stderr" 'sidecar 超出当前上下文预算'
cmp "$small_capture/request-001.json" "$sidecar_capture/request-001.json"
cmp "$small_capture/output" "$sidecar_capture/output"

# A recoverable initial truncation must invalidate the initial-only budget.
# Initial and shard requests intentionally reserve different output lengths:
# the latter must re-plan its smaller input space before sending any shard.
recovery_capture="$fixture_root/replanned-shards"
awk 'BEGIN { for (i = 1; i <= 360; i++) printf "recovery changed line %03d\n", i }' \
  >"$fixture_repo/Noise.txt"
run_review "$recovery_capture" \
  LOCAL_REVIEW_BUDGET_INITIAL_LENGTH=true \
  OLLAMA_REVIEW_MAX_DIFF_BYTES=20000 \
  OLLAMA_REVIEW_NUM_PREDICT=256 \
  OLLAMA_REVIEW_CHUNK_NUM_PREDICT=4096 \
  "OLLAMA_REVIEW_RESOLVED_CHUNK_BYTES_FILE=$recovery_capture/budget.tsv"
[[ "$(<"$recovery_capture/count")" -ge 3 ]] || {
  echo 'initial truncation did not recover through multiple bounded shards' >&2
  cat "$recovery_capture/stderr" >&2
  exit 1
}
jq -e '.options.num_predict == 256' "$recovery_capture/request-001.json" >/dev/null
assert_contains "$recovery_capture/budget.tsv" $'budget_mode\tshard'
assert_contains "$recovery_capture/budget.tsv" $'chunk_budget_available_tokens\t11264'
for request_file in "$recovery_capture"/request-*.json; do
  [[ "$request_file" != "$recovery_capture/request-001.json" ]] || continue
  jq -e '.options.num_predict == 4096' "$request_file" >/dev/null
  jq -r '.prompt' "$request_file" >>"$recovery_capture/shard-prompts"
done
assert_contains "$recovery_capture/shard-prompts" '--- 当前审查分片：'
assert_contains "$recovery_capture/shard-prompts" '+recovery changed line 001'
assert_contains "$recovery_capture/shard-prompts" '+recovery changed line 360'
recovered_line_count="$(grep -E '^\+recovery changed line [0-9]{3}$' \
  "$recovery_capture/shard-prompts" | LC_ALL=C sort -u | wc -l | tr -d ' ')"
[[ "$recovered_line_count" == 360 ]] || {
  echo "shard recovery omitted changed lines: $recovered_line_count/360" >&2
  exit 1
}
assert_contains "$recovery_capture/output" '凭据值被拼接到 URL'

# Independently validate the transport payload sizes with the documented
# conservative UTF-8 estimate, not merely the runner's success exit code.
for request_file in "$fixture_root"/*/request-*.json; do
  jq -e '
    def estimate:
      utf8bytelength as $bytes
      | (gsub("[^\u0001-\u007f]"; "") | length) as $ascii
      | ((($ascii + 2) / 3) | floor) + (((($bytes - $ascii) + 2) / 3) | floor);
    ((.system | estimate) + (.prompt | estimate))
      <= (.options.num_ctx - .options.num_predict - 1024)
  ' "$request_file" >/dev/null || {
    echo "transport received an over-budget prompt: $request_file" >&2
    exit 1
  }
done

echo 'small-diff prompt budget regression passed'
