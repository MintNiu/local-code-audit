#!/usr/bin/env bash
set -euo pipefail

# Test request configuration, not model quality. Both Ollama and every HTTP
# endpoint are replaced; no installed model or listening service is required.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-thinking-options.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
fake_bin="$fixture_root/bin"
repo="$fixture_root/repo"
split_repo="$fixture_root/split-repo"
mkdir -p "$fake_bin" "$repo" "$split_repo"

cat >"$fake_bin/ollama" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$THINKING_TEST_CASE/ollama.log"
[[ "${1:-}" == show && "${2:-}" == thinking-selected && $# == 2 ]] || {
  echo 'fake Ollama refuses any command except the selected-model show' >&2
  exit 97
}
EOF

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url=""
body_file=""
output_file=""
write_out=""
resolve=""
previous=""
for argument in "$@"; do
  if [[ "$previous" == --data-binary && "$argument" == @* ]]; then
    body_file="${argument#@}"
  elif [[ "$previous" == --output || "$previous" == -o ]]; then
    output_file="$argument"
  elif [[ "$previous" == --write-out || "$previous" == -w ]]; then
    write_out="$argument"
  elif [[ "$previous" == --resolve ]]; then
    resolve="$argument"
  fi
  case "$argument" in
    http://*|https://*) url="$argument" ;;
  esac
  previous="$argument"
done
printf '%s\n' "$url" >>"$THINKING_TEST_CASE/http.log"
[[ -n "$body_file" && -f "$body_file" ]] || {
  echo 'fake curl requires a JSON request file' >&2
  exit 97
}
case "$url" in
  http://127.0.0.1:11434/api/show|http://localhost:011434/api/show)
    count=0
    [[ ! -f "$THINKING_TEST_CASE/show.count" ]] || count="$(cat "$THINKING_TEST_CASE/show.count")"
    count=$((count + 1))
    printf '%s\n' "$count" >"$THINKING_TEST_CASE/show.count"
    cp "$body_file" "$THINKING_TEST_CASE/show-$count.json"
    if [[ "$url" == http://localhost:011434/api/show ]]; then
      [[ "$resolve" == localhost:11434:127.0.0.1 ]] || {
        echo 'localhost resolve entry did not normalize the leading-zero port' >&2
        exit 97
      }
      printf '%s\n' "$resolve" >"$THINKING_TEST_CASE/resolve.txt"
    fi
    case "${THINKING_TEST_MODE:-normal}" in
      transport-error) echo 'controlled HTTP error' >&2; exit 22 ;;
      timeout) echo 'controlled timeout' >&2; exit 28 ;;
    esac
    [[ -n "$output_file" && "$write_out" == '%{http_code}' ]] || {
      echo 'metadata probe must capture the HTTP status separately from its body' >&2
      exit 97
    }
    cp "$THINKING_TEST_CASE/metadata.json" "$output_file"
    if [[ "${THINKING_TEST_MODE:-normal}" == redirect ]]; then printf '302'; else printf '200'; fi
    ;;
  http://127.0.0.1:11434/api/generate|http://localhost:011434/api/generate)
    count=0
    [[ ! -f "$THINKING_TEST_CASE/generate.count" ]] || count="$(cat "$THINKING_TEST_CASE/generate.count")"
    count=$((count + 1))
    printf '%s\n' "$count" >"$THINKING_TEST_CASE/generate.count"
    cp "$body_file" "$THINKING_TEST_CASE/request-$count.json"
    # Inspect the trace inside the transport replacement: recording only
    # after curl returns would not satisfy the actual-attempt evidence rule.
    if [[ "${OLLAMA_REVIEW_THINK+x}" == x ]]; then
      expected_sent=$'think_sent\ttrue'
      expected_json=$'think_json\t'"$(jq -c .think "$body_file")"
      [[ "$(grep -Fxc "$expected_sent" "$OLLAMA_REVIEW_TRACE_FILE" || true)" == "$count" ]] || exit 97
      [[ "$(grep -Fxc "$expected_json" "$OLLAMA_REVIEW_TRACE_FILE" || true)" == "$count" ]] || exit 97
    else
      [[ "$(grep -Fxc $'think_sent\tfalse' "$OLLAMA_REVIEW_TRACE_FILE" || true)" == "$count" ]] || exit 97
      if grep -F $'think_json\t' "$OLLAMA_REVIEW_TRACE_FILE" >/dev/null; then exit 97; fi
    fi
    printf '%s\n' '{"response":"未发现阻塞问题","done":true,"done_reason":"stop"}'
    ;;
  *)
    echo 'fake curl refuses unrecognized or non-loopback endpoints' >&2
    exit 97
    ;;
esac
EOF
chmod +x "$fake_bin/ollama" "$fake_bin/curl"

for target_repo in "$repo" "$split_repo"; do
  git -C "$target_repo" init -q
  git -C "$target_repo" config user.email test@example.invalid
  git -C "$target_repo" config user.name thinking-options-test
  printf 'original\n' >"$target_repo/Notes.txt"
  git -C "$target_repo" add Notes.txt
  git -C "$target_repo" commit -qm base
done
printf 'changed\n' >"$repo/Notes.txt"
for ((line = 1; line <= 100; line++)); do
  printf 'changed-neutral-line-%03d\n' "$line"
done >"$split_repo/Notes.txt"

all_values='{"thinking":{"values":[false,true,"low","medium","high","xhigh"]}}'
case_count=0
last_case=""

fail() {
  printf 'thinking options regression failed: %s (case %s)\n' "$1" "${last_case##*/}" >&2
  [[ ! -f "$last_case/stderr" ]] || cat "$last_case/stderr" >&2
  [[ ! -f "$last_case/http.log" ]] || cat "$last_case/http.log" >&2
  exit 1
}

count_calls() {
  local type="$1"
  if [[ -f "$last_case/$type.count" ]]; then cat "$last_case/$type.count"; else printf '0\n'; fi
}

run_case() {
  local name="$1" requested="$2" expected_status="$3" metadata="$4"
  local mode="${5:-normal}" target_repo="${6:-$repo}" max_diff="${7:-60000}" channel="${8:-}"
  local origin="${9:-http://127.0.0.1:11434}"
  local status=0
  last_case="$fixture_root/$name"
  mkdir -p "$last_case/tmp"
  printf '%s\n' "$metadata" >"$last_case/metadata.json"
  (
    # Do not inherit private examples, trace destinations, sidecars, or a real
    # server address from an interactive developer session.
    unset OLLAMA_REVIEW_THINK OLLAMA_REVIEW_TRACE_FILE OLLAMA_REVIEW_RESOLVED_CHUNK_BYTES_FILE
    export PATH="$fake_bin:$PATH" TMPDIR="$last_case/tmp"
    export OLLAMA_HOST="$origin" OLLAMA_REVIEW_TRACE_FILE="$last_case/trace.tsv"
    export OLLAMA_REVIEW_MODEL=ignored-by-explicit-model
    export OLLAMA_REVIEW_LOCK_DIR="$last_case/lock"
    export OLLAMA_REVIEW_SPECIALIST_CHANNEL="$channel" OLLAMA_REVIEW_JAVA_METHOD_SIDECAR=false
    export OLLAMA_REVIEW_MAX_DIFF_BYTES="$max_diff" OLLAMA_REVIEW_NUM_CTX=65536
    export OLLAMA_REVIEW_NUM_PREDICT=256 OLLAMA_REVIEW_CHUNK_NUM_PREDICT=256
    export OLLAMA_REVIEW_INPUT_RESERVE_TOKENS=1024 OLLAMA_REVIEW_RETRY_ATTEMPTS=0
    export OLLAMA_REVIEW_TEMPERATURE=0 OLLAMA_REVIEW_SEED=42
    export OLLAMA_REVIEW_TOP_K=40 OLLAMA_REVIEW_TOP_P=0.9 OLLAMA_REVIEW_KEEP_ALIVE=0
    export OLLAMA_REVIEW_PROBE_TIMEOUT_SECONDS=5 OLLAMA_REVIEW_TIMEOUT_SECONDS=30
    export OLLAMA_REVIEW_CHUNK_TIMEOUT_SECONDS=30 OLLAMA_REVIEW_TOTAL_TIMEOUT_SECONDS=60
    export LOCAL_REVIEW_EXAMPLES_FILE=/dev/null
    export THINKING_TEST_CASE="$last_case" THINKING_TEST_MODE="$mode"
    if [[ "$mode" == over-budget ]]; then export OLLAMA_REVIEW_NUM_CTX=2048; fi
    if [[ "$requested" != __UNSET__ ]]; then export OLLAMA_REVIEW_THINK="$requested"; fi
    bash "$repo_root/bin/local-review.sh" --repo "$target_repo" --model thinking-selected
  ) >"$last_case/stdout" 2>"$last_case/stderr" || status=$?
  [[ "$status" == "$expected_status" ]] || fail "expected exit $expected_status, got $status"
  case_count=$((case_count + 1))
  if [[ -f "$last_case/ollama.log" ]] && grep -Fvx 'show thinking-selected' "$last_case/ollama.log" >/dev/null; then
    fail 'review attempted a model download or unexpected Ollama command'
  fi
  if [[ "$expected_status" == 0 ]]; then
    [[ "$(cat "$last_case/stdout")" == '未发现阻塞问题' ]] || fail 'fake clean response was changed'
    [[ "$(count_calls generate)" -ge 1 ]] || fail 'successful review sent no request'
  else
    [[ "$(count_calls generate)" == 0 ]] || fail 'invalid thinking option reached inference'
    [[ ! -s "$last_case/stdout" ]] || fail 'rejected option emitted review output'
    if [[ "$mode" == over-budget ]]; then
      grep -F '预算' "$last_case/stderr" >/dev/null || fail 'missing explicit budget diagnostic'
    else
      grep -F OLLAMA_REVIEW_THINK "$last_case/stderr" >/dev/null || fail 'missing explicit thinking diagnostic'
    fi
    if [[ -f "$last_case/trace.tsv" ]] && grep -E '^think_sent[[:space:]]+true$|^think_json[[:space:]]' "$last_case/trace.tsv" >/dev/null; then
      fail 'pre-inference rejection falsely recorded a sent thinking request'
    fi
  fi
  for metadata_request in "$last_case"/show-*.json; do
    [[ -f "$metadata_request" ]] || continue
    jq -e '. == {model:"thinking-selected"}' "$metadata_request" >/dev/null || fail 'metadata did not target the selected model'
  done
}

assert_think() {
  local expected_json="$1" request
  [[ "$(count_calls show)" == 1 ]] || fail 'explicit thinking must be validated once per review'
  for request in "$last_case"/request-*.json; do
    jq -e --argjson expected "$expected_json" '
      .model == "thinking-selected" and has("think") and
      (.think == $expected) and ((.think | type) == ($expected | type)) and
      (.options | has("think") | not)
    ' "$request" >/dev/null || fail 'top-level think value/type was lost or changed'
  done
}

# Unset must retain the legacy request and avoid even an optional show probe.
run_case unset __UNSET__ 0 '{"error":"metadata must not be requested when unset"}'
[[ "$(count_calls show)" == 0 && "$(count_calls generate)" == 1 ]] || fail 'unset added a metadata probe'
jq -e 'has("think") | not' "$last_case/request-1.json" >/dev/null || fail 'unset added think to the request'
unset_request="$last_case/request-1.json"

run_case explicit-false false 0 "$all_values"
assert_think false
cmp -s <(jq -S 'del(.think)' "$last_case/request-1.json") <(jq -S . "$unset_request") || fail 'explicit think changed unrelated request fields'
run_case explicit-true true 0 "$all_values"
assert_think true
for level in low medium high xhigh; do
  run_case "explicit-$level" "$level" 0 "$all_values"
  assert_think "\"$level\""
done

run_case unsupported-true true 2 '{"thinking":{"values":[false,"low"]}}'
[[ "$(count_calls show)" == 1 ]] || fail 'unsupported true was not checked against metadata'
run_case unsupported-high high 2 '{"thinking":{"values":[false,"low"]}}'
[[ "$(count_calls show)" == 1 ]] || fail 'unsupported high was not checked against metadata'
run_case string-false-is-not-boolean false 2 '{"thinking":{"values":["false"]}}'
[[ "$(count_calls show)" == 1 ]] || fail 'string false metadata was not inspected'

for invalid in '' FALSE unsupported; do
  run_case "invalid-$case_count" "$invalid" 2 "$all_values"
  [[ "$(count_calls show)" == 0 ]] || fail 'invalid syntax caused an unnecessary API probe'
done
printf -v injection_value '$(touch %q)' "$fixture_root/injection-executed"
run_case invalid-injection "$injection_value" 2 "$all_values"
[[ "$(count_calls show)" == 0 && ! -e "$fixture_root/injection-executed" ]] || fail 'invalid value was evaluated or probed'

run_case metadata-api-error false 2 '{"error":"controlled metadata error","thinking":{"values":[false]}}'
run_case metadata-incomplete-json false 2 '{"thinking":'
run_case metadata-json-stream false 2 '{"thinking":{"values":[false]}} {"thinking":{"values":[false]}}'
run_case metadata-null false 2 null
run_case metadata-missing-values false 2 '{"thinking":{}}'
run_case metadata-values-not-array false 2 '{"thinking":{"values":false}}'
run_case metadata-transport-error false 2 "$all_values" transport-error
run_case metadata-timeout false 2 "$all_values" timeout
run_case metadata-redirect false 2 "$all_values" redirect

run_case localhost-leading-zero-port false 0 "$all_values" normal "$repo" 60000 '' http://localhost:011434
assert_think false
[[ "$(cat "$last_case/resolve.txt")" == localhost:11434:127.0.0.1 ]] || fail 'localhost resolution pin was not retained'
grep -Fx http://localhost:011434/api/show "$last_case/http.log" >/dev/null || fail 'metadata URL unexpectedly rewrote the requested origin'
run_case pre-inference-budget false 1 "$all_values" over-budget

# Direct sharding and optional specialist requests share the same validated
# value. Neither branch may drop false or repeat model capability discovery.
run_case sharded-false false 0 "$all_values" normal "$split_repo" 1000
assert_think false
[[ "$(count_calls generate)" -ge 2 ]] || fail 'sharding fixture did not create multiple requests'
for request in "$last_case"/request-*.json; do
  jq -e '.prompt | contains("当前审查分片：")' "$request" >/dev/null || fail 'expected a shard request'
done

run_case specialist-low low 0 "$all_values" normal "$repo" 60000 auth-tenant
assert_think '"low"'
[[ "$(count_calls generate)" == 2 ]] || fail 'specialist fixture did not send both passes'
jq -e '.system | contains("可选风险族复核") | not' "$last_case/request-1.json" >/dev/null || fail 'first pass was not the base review'
jq -e '.system | contains("可选风险族复核")' "$last_case/request-2.json" >/dev/null || fail 'second pass was not the specialist review'

printf 'thinking options regression passed (%s cases; no real model or network)\n' "$case_count"
