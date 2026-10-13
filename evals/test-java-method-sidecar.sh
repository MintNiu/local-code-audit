#!/usr/bin/env bash
set -euo pipefail

# Hermetic request-level regression for the optional Java method sidecar. The
# fake transport records each Ollama JSON request; no model is contacted.
repo_root="$(cd "$(dirname "$BASH_SOURCE")/.." && pwd)"
tmp_base="${TMPDIR:-/tmp}"
fixture_root="$(mktemp -d "$tmp_base/local-review-java-method-sidecar.XXXXXX")"
fake_bin="$fixture_root/bin"
repo="$fixture_root/repo"
tmp_dir="$fixture_root/tmp"
trap 'rm -rf "$fixture_root"' EXIT

mkdir -p "$fake_bin" "$repo" "$tmp_dir"

cat >"$fake_bin/ollama" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
capture_dir="$LOCAL_REVIEW_SIDECAR_CAPTURE_DIR"
mkdir -p "$capture_dir"
count_file="$capture_dir/.count"
count=0
if [[ -f "$count_file" ]]; then
  count="$(<"$count_file")"
fi
count=$((count + 1))
printf '%s\n' "$count" >"$count_file"
request_file=""
for argument in "$@"; do
  if [[ "$argument" == @* ]]; then
    request_file="$(printf '%s' "$argument" | sed 's/^@//')"
  fi
done
[[ -n "$request_file" && -f "$request_file" ]] || exit 2
cp "$request_file" "$capture_dir/request-$(printf '%03d' "$count").json"
printf '%s\n' '{"response":"未发现阻塞问题","done":true,"done_reason":"stop"}'
EOF
chmod +x "$fake_bin/ollama" "$fake_bin/curl"

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name java-method-sidecar-test

cat >"$repo/Sample.java" <<'EOF'
public final class Sample {
    static Object target(Object input) {
        return input;
    }

    static Object next() {
        return "next";
    }
}
EOF
git -C "$repo" add Sample.java
git -C "$repo" commit -qm baseline
cat >"$repo/Sample.java" <<'EOF'
public final class Sample {
    static Object target(Object input) {
        audit(input);
        return input;
    }

    static Object next() {
        return "next";
    }
}
EOF

run_review() {
  local capture_dir="$1"
  shift
  mkdir -p "$capture_dir"
  (
    export PATH="$fake_bin:$PATH"
    export TMPDIR="$tmp_dir"
    export LOCAL_REVIEW_SIDECAR_CAPTURE_DIR="$capture_dir"
    export LOCAL_REVIEW_EXAMPLES_FILE=/dev/null
    export OLLAMA_REVIEW_MODEL=devstral-small-2-review
    export OLLAMA_REVIEW_RETRY_ATTEMPTS=0
    export OLLAMA_REVIEW_TIMEOUT_SECONDS=30
    export OLLAMA_REVIEW_TOTAL_TIMEOUT_SECONDS=120
    export OLLAMA_REVIEW_LOCK_DIR="$capture_dir/lock"
    export OLLAMA_REVIEW_MAX_DIFF_BYTES=60000
    export OLLAMA_REVIEW_NUM_CTX=16384
    export OLLAMA_REVIEW_NUM_PREDICT=256
    export OLLAMA_REVIEW_CHUNK_NUM_PREDICT=256
    export OLLAMA_REVIEW_INPUT_RESERVE_TOKENS=256
    unset OLLAMA_REVIEW_JAVA_METHOD_SIDECAR
    for assignment in "$@"; do
      export "$assignment"
    done
    if ! "$repo_root/bin/local-review.sh" --repo "$repo" >"$capture_dir/output" 2>"$capture_dir/stderr"; then
      echo "review failed for $capture_dir" >&2
      cat "$capture_dir/stderr" >&2
      exit 1
    fi
  )
}

request_count() {
  find "$1" -maxdepth 1 -name 'request-*.json' -type f -print | wc -l | tr -d ' '
}

prompt_for() {
  jq -r '.prompt' "$1"
}

assert_single_request() {
  local capture_dir="$1"
  [[ "$(request_count "$capture_dir")" == 1 ]] || {
    echo "expected one Ollama request in $capture_dir" >&2
    ls -la "$capture_dir" >&2
    cat "$capture_dir/stderr" >&2 || true
    exit 1
  }
}

# The feature is opt-in. The default request must remain exactly the normal
# review prompt and must not contain source-window metadata.
default_capture="$fixture_root/default"
run_review "$default_capture"
assert_single_request "$default_capture"
if prompt_for "$default_capture/request-001.json" | grep -F -- '当前变更方法窗口' >/dev/null; then
  echo 'Java method sidecar was enabled by default' >&2
  exit 1
fi

# An enabled sidecar must include only the method containing the added line,
# never an adjacent unchanged method.
enabled_capture="$fixture_root/enabled"
run_review "$enabled_capture" \
  OLLAMA_REVIEW_JAVA_METHOD_SIDECAR=true \
  OLLAMA_REVIEW_JAVA_METHOD_SIDECAR_MAX_BYTES=6000 \
  OLLAMA_REVIEW_JAVA_METHOD_SIDECAR_MAX_METHOD_BYTES=4000 \
  OLLAMA_REVIEW_JAVA_METHOD_SIDECAR_MAX_METHODS=6
assert_single_request "$enabled_capture"
enabled_prompt="$(prompt_for "$enabled_capture/request-001.json" | sed -n '/^--- 当前变更方法窗口/,/^--- 变更方法窗口结束 ---/p')"
grep -F -- '--- 当前变更方法窗口（源码证据，非预检；仅包含新增行所在方法） ---' <<<"$enabled_prompt" >/dev/null
grep -F -- 'static Object target(Object input)' <<<"$enabled_prompt" >/dev/null
if grep -F -- 'static Object next()' <<<"$enabled_prompt" >/dev/null; then
  echo 'enabled Java method sidecar crossed into an adjacent method' >&2
  exit 1
fi

# Both independent budgets are fail-closed: omitting an entire method is safer
# than sending a partial source window. The normal request remains valid.
for budget_name in method total; do
  budget_capture="$fixture_root/budget-$budget_name"
  if [[ "$budget_name" == method ]]; then
    run_review "$budget_capture" \
      OLLAMA_REVIEW_JAVA_METHOD_SIDECAR=true \
      OLLAMA_REVIEW_JAVA_METHOD_SIDECAR_MAX_BYTES=6000 \
      OLLAMA_REVIEW_JAVA_METHOD_SIDECAR_MAX_METHOD_BYTES=1 \
      OLLAMA_REVIEW_JAVA_METHOD_SIDECAR_MAX_METHODS=6
  else
    run_review "$budget_capture" \
      OLLAMA_REVIEW_JAVA_METHOD_SIDECAR=true \
      OLLAMA_REVIEW_JAVA_METHOD_SIDECAR_MAX_BYTES=1 \
      OLLAMA_REVIEW_JAVA_METHOD_SIDECAR_MAX_METHOD_BYTES=4000 \
      OLLAMA_REVIEW_JAVA_METHOD_SIDECAR_MAX_METHODS=6
  fi
  assert_single_request "$budget_capture"
  if prompt_for "$budget_capture/request-001.json" | grep -F -- '当前变更方法窗口' >/dev/null; then
    echo "$budget_name sidecar budget did not omit the whole method" >&2
    exit 1
  fi
done

generate_large_repo() {
  local large_repo="$1"
  local with_preflight="$2"
  local filler_lines="${3:-240}"
  mkdir -p "$large_repo"
  git -C "$large_repo" init -q
  git -C "$large_repo" config user.email test@example.invalid
  git -C "$large_repo" config user.name java-method-sidecar-budget-test
  awk -v filler_lines="$filler_lines" 'BEGIN {
    print "public final class LargeSample {"
    print "    static Object target(Object input) {"
    for (i = 1; i <= filler_lines; i++) {
      printf "        String filler%03d = \"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\";\n", i
    }
    print "        return input;"
    print "    }"
    print ""
    print "    static Object next() {"
    print "        return \"next\";"
    print "    }"
    print "}"
  }' >"$large_repo/LargeSample.java"
  seq 1 120 | awk '{ printf "line-%03d\n", $1 }' >"$large_repo/Noise.txt"
  git -C "$large_repo" add .
  git -C "$large_repo" commit -qm baseline
  awk -v with_preflight="$with_preflight" -v filler_lines="$filler_lines" 'BEGIN {
    print "public final class LargeSample {"
    print "    static Object target(Object input) {"
    if (with_preflight == "yes") {
      print "        String token1 = request.getParameter(\"x-token\");"
      print "        String token2 = request.getParameter(\"authorization\");"
      print "        String token3 = request.getParameter(\"api-key\");"
    }
    print "        audit(input);"
    for (i = 1; i <= filler_lines; i++) {
      printf "        String filler%03d = \"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\";\n", i
    }
    print "        return input;"
    print "    }"
    print ""
    print "    static Object next() {"
    print "        return \"next\";"
    print "    }"
    print "}"
  }' >"$large_repo/LargeSample.java"
  seq 1 120 | awk '{ printf "changed-%03d\n", $1 }' >"$large_repo/Noise.txt"
}

# A huge unchanged body makes the optional window exceed the request budget
# without enlarging the diff. Compare real JSON payloads, not just logs.
assert_fallback_pair() {
  local case_name="$1"
  local expected_shape="$2"
  shift 2
  local baseline="$fixture_root/$case_name-baseline"
  local fallback="$fixture_root/$case_name-fallback"
  run_review "$baseline" OLLAMA_REVIEW_JAVA_METHOD_SIDECAR=false "$@"
  run_review "$fallback" \
    OLLAMA_REVIEW_JAVA_METHOD_SIDECAR=true \
    OLLAMA_REVIEW_JAVA_METHOD_SIDECAR_MAX_BYTES=60000 \
    OLLAMA_REVIEW_JAVA_METHOD_SIDECAR_MAX_METHOD_BYTES=60000 \
    OLLAMA_REVIEW_JAVA_METHOD_SIDECAR_MAX_METHODS=6 "$@"
  if [[ "$expected_shape" == single ]]; then
    assert_single_request "$baseline"
    assert_single_request "$fallback"
  else
    [[ "$(request_count "$baseline")" -ge 2 ]] || {
      echo "$case_name did not create multiple requests" >&2
      cat "$baseline/stderr" >&2
      exit 1
    }
  fi
  [[ "$(request_count "$fallback")" == "$(request_count "$baseline")" ]] || {
    echo "$case_name changed the request count after sidecar fallback" >&2
    exit 1
  }
  grep -F 'sidecar 超出当前上下文预算' "$fallback/stderr" >/dev/null || {
    echo "$case_name did not exercise context-budget fallback" >&2
    cat "$fallback/stderr" >&2
    exit 1
  }
  for request_file in "$baseline"/request-*.json; do
    cmp "$request_file" "$fallback/$(basename "$request_file")"
  done
  cmp "$baseline/output" "$fallback/output"
}

# Non-split prompts preserve their original preflight policy both when the
# planner keeps preflight and when a smaller budget disables that context.
large_repo="$fixture_root/large-repo"
generate_large_repo "$large_repo" yes
repo="$large_repo"
assert_fallback_pair unsplit-preflight single
assert_fallback_pair unsplit-no-preflight single OLLAMA_REVIEW_NUM_CTX=12288
grep -F '从模型分片提示中移除' "$fixture_root/unsplit-no-preflight-baseline/stderr" >/dev/null

# Split fallback must reuse the bounded (or disabled) preflight file, not the
# original unbounded three-finding file. All three findings still reach the
# final result even when only one complete paragraph fits the prompt.
assert_fallback_pair split-bounded multiple \
  OLLAMA_REVIEW_MAX_DIFF_BYTES=1000 \
  OLLAMA_REVIEW_CHUNK_PREFLIGHT_BYTES=1000
bounded_prompt_count="$(jq -r '.prompt' "$fixture_root/split-bounded-baseline"/request-*.json | grep -c '^P1 LargeSample.java:' || true)"
[[ "$bounded_prompt_count" == 1 ]] || {
  echo "bounded preflight expected one prompt paragraph, got $bounded_prompt_count" >&2
  exit 1
}
[[ "$(grep -c '^P1 LargeSample.java:' "$fixture_root/split-bounded-fallback/output")" == 3 ]]
assert_fallback_pair split-no-preflight multiple \
  OLLAMA_REVIEW_MAX_DIFF_BYTES=1000 \
  OLLAMA_REVIEW_CHUNK_PREFLIGHT_BYTES=1000 \
  OLLAMA_REVIEW_NUM_CTX=12288
if jq -r '.prompt' "$fixture_root/split-no-preflight-fallback"/request-*.json | grep -q '^P1 LargeSample.java:'; then
  echo 'sidecar fallback restored disabled preflight context' >&2
  exit 1
fi

# This shorter window fits the initial 256-token output budget but not the
# actual 4096-token shard output budget. Checking sidecar before switching
# num_predict used to accept it, then fail the first real shard request.
unequal_repo="$fixture_root/unequal-budget-repo"
generate_large_repo "$unequal_repo" no 170
repo="$unequal_repo"
assert_fallback_pair split-output-budget multiple \
  OLLAMA_REVIEW_MAX_DIFF_BYTES=1000 \
  OLLAMA_REVIEW_NUM_PREDICT=256 \
  OLLAMA_REVIEW_CHUNK_NUM_PREDICT=4096
for request_file in "$fixture_root/split-output-budget-fallback"/request-*.json; do
  [[ "$(jq -r '.options.num_predict' "$request_file")" == 4096 ]] || {
    echo 'split request did not use OLLAMA_REVIEW_CHUNK_NUM_PREDICT' >&2
    exit 1
  }
done

echo 'Java method sidecar request-budget regression passed'
