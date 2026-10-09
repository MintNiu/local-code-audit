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
  if [[ "${SPECIALIST_FAILURE:-}" == "length" ]]; then
    jq -n --arg response "${SPECIALIST_RESPONSE:?}" '{response:$response,done:true,done_reason:"length"}'
    exit 0
  fi
  response="${SPECIALIST_RESPONSE:?}"
else
  response="${BASE_RESPONSE:?}"
fi
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
  rm -f "$capture_dir"/request-*.json
  PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" OLLAMA_SHOW_LOG="$fixture_root/show.log" \
    OLLAMA_REVIEW_LOCK_DIR="$tmp_dir/lock" OLLAMA_REVIEW_MODEL=fake \
    OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 OLLAMA_REVIEW_NUM_CTX=65536 \
    LOCAL_REVIEW_EXAMPLES_FILE=/dev/null SPECIALIST_COUNT_FILE="$SPECIALIST_COUNT_FILE" \
    SPECIALIST_CAPTURE_DIR="$capture_dir" "$@" >"$output_file"
}

export SPECIALIST_COUNT_FILE="$fixture_root/request-count"
export SPECIALIST_CAPTURE_DIR="$capture_dir"
export BASE_RESPONSE='未发现阻塞问题'
export SPECIALIST_RESPONSE='未发现阻塞问题'

default_output="$fixture_root/default.txt"
run_review "$default_output" "$repo_root/bin/local-review.sh" --repo "$repo"
[[ "$(cat "$SPECIALIST_COUNT_FILE")" == 1 ]]
! jq -e '.system | contains("可选风险族复核")' "$capture_dir/request-1.json" >/dev/null

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

failure_output="$fixture_root/failure.txt"
if OLLAMA_REVIEW_SPECIALIST_CHANNEL=auth-tenant SPECIALIST_FAILURE=length \
  run_review "$failure_output" "$repo_root/bin/local-review.sh" --repo "$repo"; then
  echo 'truncated specialist unexpectedly succeeded' >&2
  exit 1
fi
[[ ! -s "$failure_output" ]]

echo 'specialist channel regression passed'
