#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-specialist.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

fake_bin="$fixture_root/bin"
repo="$fixture_root/repo"
tmp_dir="$fixture_root/tmp"
capture_dir="$fixture_root/captures"
mkdir -p "$fake_bin" "$repo/src" "$tmp_dir" "$capture_dir"

cat >"$fake_bin/ollama" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
body_file=""
previous=""
for argument in "$@"; do
  if [[ "$previous" == "--data-binary" && "$argument" == @* ]]; then
    body_file="${argument#@}"
  fi
  previous="$argument"
done
[[ -n "$body_file" ]] || { echo "fake curl did not receive request body" >&2; exit 2; }
count_file="${SPECIALIST_COUNT_FILE:?}"
count=0
if [[ -f "$count_file" ]]; then count="$(cat "$count_file")"; fi
count=$((count + 1))
printf '%s\n' "$count" >"$count_file"
cp "$body_file" "$SPECIALIST_CAPTURE_DIR/request-$count.json"
is_specialist=false
if jq -e '.system | contains("可选风险族复核")' >/dev/null <"$body_file"; then
  is_specialist=true
fi
if [[ "$is_specialist" == true ]]; then
  specialist_count_file="${SPECIALIST_ONLY_COUNT_FILE:?}"
  specialist_count=0
  if [[ -f "$specialist_count_file" ]]; then specialist_count="$(cat "$specialist_count_file")"; fi
  specialist_count=$((specialist_count + 1))
  printf '%s\n' "$specialist_count" >"$specialist_count_file"
  cp "$body_file" "$SPECIALIST_CAPTURE_DIR/specialist-$specialist_count.json"
fi
failure="${SPECIALIST_FAILURE:-}"
if [[ "$is_specialist" == true && "$failure" == transport ]]; then
  echo 'fake transport failure' >&2
  exit 22
fi
if [[ "$is_specialist" == true && "$failure" == malformed ]]; then
  printf '%s\n' '{"response":"截断但没有完成标记"}'
  exit 0
fi
if [[ "$is_specialist" == true ]]; then
  if [[ "$failure" == length ]]; then
    jq -n --arg response "${SPECIALIST_RESPONSE:?}" '{response:$response,done:true,done_reason:"length"}'
    exit 0
  fi
  specialist_key="SPECIALIST_RESPONSE_${specialist_count}"
  if [[ -n "${!specialist_key+x}" ]]; then
    response="${!specialist_key}"
  else
    response="${SPECIALIST_RESPONSE:?}"
  fi
else
  base_count_file="${BASE_ONLY_COUNT_FILE:?}"
  base_count=0
  if [[ -f "$base_count_file" ]]; then base_count="$(cat "$base_count_file")"; fi
  base_count=$((base_count + 1))
  printf '%s\n' "$base_count" >"$base_count_file"
  base_key="BASE_RESPONSE_${base_count}"
  if [[ -n "${!base_key+x}" ]]; then
    response="${!base_key}"
  else
    response="${BASE_RESPONSE:?}"
  fi
fi
chunk_path="$(jq -r '.prompt' "$body_file" | sed -n 's#^diff --git a/\([^ ]*\) b/.*#\1#p' | head -n 1)"
response="${response//__CHUNK_PATH__/$chunk_path}"
jq -n --arg response "$response" '{response:$response,done:true,done_reason:"stop"}'
EOF
chmod +x "$fake_bin/ollama" "$fake_bin/curl"

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name specialist-test
cat >"$repo/src/Example.java" <<'EOF'
class Example {
    int value = 1;
}
EOF
git -C "$repo" add .
git -C "$repo" commit -qm base
perl -0pi -e 's/int value = 1/int value = 2/' "$repo/src/Example.java"

run_review() {
  local output_file="$1"
  shift
  : >"$SPECIALIST_COUNT_FILE"
  : >"$SPECIALIST_ONLY_COUNT_FILE"
  : >"$BASE_ONLY_COUNT_FILE"
  rm -f "$capture_dir"/request-*.json
  PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" OLLAMA_SHOW_LOG="$fixture_root/show.log" \
    OLLAMA_REVIEW_LOCK_DIR="$tmp_dir/lock" OLLAMA_REVIEW_MODEL=fake \
    OLLAMA_REVIEW_MAX_DIFF_BYTES="${OLLAMA_REVIEW_MAX_DIFF_BYTES:-60000}" \
    OLLAMA_REVIEW_NUM_CTX="${OLLAMA_REVIEW_NUM_CTX:-65536}" \
    OLLAMA_REVIEW_NUM_PREDICT="${OLLAMA_REVIEW_NUM_PREDICT:-4096}" \
    OLLAMA_REVIEW_INPUT_RESERVE_TOKENS="${OLLAMA_REVIEW_INPUT_RESERVE_TOKENS:-1024}" \
    OLLAMA_REVIEW_RETRY_ATTEMPTS="${OLLAMA_REVIEW_RETRY_ATTEMPTS:-0}" \
    LOCAL_REVIEW_EXAMPLES_FILE=/dev/null SPECIALIST_COUNT_FILE="$SPECIALIST_COUNT_FILE" \
    SPECIALIST_CAPTURE_DIR="$capture_dir" "$@" >"$output_file"
}

export SPECIALIST_COUNT_FILE="$fixture_root/request-count"
export SPECIALIST_ONLY_COUNT_FILE="$fixture_root/specialist-count"
export BASE_ONLY_COUNT_FILE="$fixture_root/base-count"
export SPECIALIST_CAPTURE_DIR="$capture_dir"
export BASE_RESPONSE='未发现阻塞问题'
export SPECIALIST_RESPONSE='未发现阻塞问题'

default_output="$fixture_root/default.txt"
run_review "$default_output" "$repo_root/bin/local-review.sh" --repo "$repo"
[[ "$(cat "$SPECIALIST_COUNT_FILE")" == 1 ]]
! jq -e '.system | contains("可选风险族复核")' "$capture_dir/request-1.json" >/dev/null
default_system="$(jq -r '.system' "$capture_dir/request-1.json")"

for channel in auth-tenant concurrency-state external-io; do
  channel_output="$fixture_root/$channel.txt"
  OLLAMA_REVIEW_SPECIALIST_CHANNEL="$channel" run_review "$channel_output" "$repo_root/bin/local-review.sh" --repo "$repo"
  [[ "$(cat "$SPECIALIST_COUNT_FILE")" == 2 ]]
  [[ "$(jq -r '.system' "$capture_dir/request-1.json")" == "$default_system" ]]
  case "$channel" in
    auth-tenant) expected_guidance='身份、授权与租户边界' ;;
    concurrency-state) expected_guidance='并发、事务与状态机' ;;
    external-io) expected_guidance='外部输入、I/O 与数据暴露' ;;
  esac
  jq -e --arg guidance "$expected_guidance" '.system | contains($guidance)' \
    "$capture_dir/request-2.json" >/dev/null
done

if PATH="$fake_bin:$PATH" OLLAMA_REVIEW_SPECIALIST_CHANNEL=invalid \
  OLLAMA_REVIEW_MODEL=fake OLLAMA_REVIEW_LOCK_DIR="$tmp_dir/invalid-lock" \
  "$repo_root/bin/local-review.sh" --repo "$repo" >/dev/null 2>"$fixture_root/invalid.err"; then
  echo 'invalid specialist channel unexpectedly succeeded' >&2
  exit 1
fi
grep -F 'OLLAMA_REVIEW_SPECIALIST_CHANNEL' "$fixture_root/invalid.err" >/dev/null
[[ ! -e "$tmp_dir/invalid-lock/pid" ]]

export BASE_RESPONSE='P1 src/Example.java:2 - 基础审查问题
影响：基础审查影响。
修复建议：修复基础问题。
验证方式：执行基础测试。'
export SPECIALIST_RESPONSE='P1 src/Example.java:2 - 专项审查问题
影响：专项审查影响。
修复建议：修复专项问题。
验证方式：执行专项测试。'
specialist_output="$fixture_root/specialist.txt"
OLLAMA_REVIEW_SPECIALIST_CHANNEL=auth-tenant \
  run_review "$specialist_output" "$repo_root/bin/local-review.sh" --repo "$repo"
[[ "$(cat "$SPECIALIST_COUNT_FILE")" == 2 ]]
grep -F '基础审查问题' "$specialist_output" >/dev/null
grep -F '专项审查问题' "$specialist_output" >/dev/null
grep -F '可选风险族复核' "$capture_dir/request-2.json" >/dev/null

[[ "$(grep -Fc '基础审查问题' "$specialist_output")" == 1 ]]
[[ "$(grep -Fc '专项审查问题' "$specialist_output")" == 1 ]]

export BASE_RESPONSE='未发现阻塞问题'
export SPECIALIST_RESPONSE='未发现阻塞问题'
for failure in malformed transport length; do
  failure_output="$fixture_root/failure-$failure.txt"
  if OLLAMA_REVIEW_SPECIALIST_CHANNEL=auth-tenant SPECIALIST_FAILURE="$failure" \
    run_review "$failure_output" "$repo_root/bin/local-review.sh" --repo "$repo"; then
    echo "$failure specialist unexpectedly succeeded" >&2
    exit 1
  fi
  [[ ! -s "$failure_output" ]]
done

# Derive a context value that fits the ordinary request exactly but leaves no
# room for the extra specialist system instruction. This proves the specialist
# pass fails closed before curl rather than silently truncating its system rule.
default_prompt="$(jq -r '.prompt' "$capture_dir/request-1.json")"
estimate_text_tokens() {
  local text="$1" bytes ascii non_ascii
  bytes="$(printf '%s' "$text" | wc -c | tr -d ' ')"
  ascii="$(printf '%s' "$text" | LC_ALL=C tr -cd '\001-\177' | wc -c | tr -d ' ')"
  non_ascii=$((bytes - ascii))
  printf '%s\n' "$(( (ascii + 2) / 3 + (non_ascii + 2) / 3 ))"
}
default_tokens=$(( $(estimate_text_tokens "$default_system") + $(estimate_text_tokens "$default_prompt") ))
budget_ctx=$((default_tokens + 1024))
budget_output="$fixture_root/budget.txt"
budget_error="$fixture_root/budget.err"
if OLLAMA_REVIEW_SPECIALIST_CHANNEL=auth-tenant \
  OLLAMA_REVIEW_NUM_CTX="$budget_ctx" OLLAMA_REVIEW_NUM_PREDICT=1024 \
  OLLAMA_REVIEW_INPUT_RESERVE_TOKENS=0 \
  run_review "$budget_output" "$repo_root/bin/local-review.sh" --repo "$repo" 2>"$budget_error"; then
  echo 'over-budget specialist unexpectedly succeeded' >&2
  exit 1
fi
[[ ! -s "$budget_output" ]]
grep -F '超过可用预算' "$budget_error" >/dev/null
[[ "$(cat "$BASE_ONLY_COUNT_FILE")" == 1 ]]
[[ "$(cat "$SPECIALIST_ONLY_COUNT_FILE")" == 0 ]]

# Force two diff chunks. Each chunk must receive one base and one specialist
# request; final aggregation must keep the union exactly once, including two
# independent roots at the same location.
split_repo="$fixture_root/split-repo"
mkdir -p "$split_repo/src"
git -C "$split_repo" init -q
git -C "$split_repo" config user.email test@example.invalid
git -C "$split_repo" config user.name specialist-split-test
for file in ExampleA ExampleB; do
  {
    printf 'class %s {\n' "$file"
    for line in $(seq 1 100); do printf '    int value%03d = 1;\n' "$line"; done
    printf '}\n'
  } >"$split_repo/src/$file.java"
done
git -C "$split_repo" add .
git -C "$split_repo" commit -qm base
for file in ExampleA ExampleB; do
  perl -0pi -e 's/= 1;/= 2;/g' "$split_repo/src/$file.java"
done
export BASE_RESPONSE_1='P1 __CHUNK_PATH__:2 - 分片根因A
影响：A。
修复建议：修复A。
验证方式：测试A。'
export BASE_RESPONSE_2='未发现阻塞问题'
export SPECIALIST_RESPONSE_1='P1 __CHUNK_PATH__:2 - 分片根因B
影响：B。
修复建议：修复B。
验证方式：测试B。'
export SPECIALIST_RESPONSE_2='P1 __CHUNK_PATH__:2 - 分片根因C
影响：C。
修复建议：修复C。
验证方式：测试C。'
split_output="$fixture_root/split.txt"
OLLAMA_REVIEW_SPECIALIST_CHANNEL=auth-tenant OLLAMA_REVIEW_MAX_DIFF_BYTES=3000 \
  run_review "$split_output" "$repo_root/bin/local-review.sh" --repo "$split_repo"
[[ "$(cat "$SPECIALIST_COUNT_FILE")" == 4 ]]
[[ "$(cat "$BASE_ONLY_COUNT_FILE")" == 2 ]]
[[ "$(cat "$SPECIALIST_ONLY_COUNT_FILE")" == 2 ]]
for root in A B C; do
  [[ "$(grep -Fc "分片根因$root" "$split_output")" == 1 ]]
done
for index in 1 2; do
  request_base=$((index * 2 - 1))
  request_specialist=$((index * 2))
  marker="当前审查分片：chunk-$(printf '%04d' "$index")"
  jq -e --arg marker "$marker" '.prompt | contains($marker)' \
    "$capture_dir/request-$request_base.json" >/dev/null
  jq -e --arg marker "$marker" '.prompt | contains($marker)' \
    "$capture_dir/request-$request_specialist.json" >/dev/null
done

echo 'specialist channel regression passed'
