#!/usr/bin/env bash
set -euo pipefail

# Regression for oversized unified-diff hunks. The splitter must retain every
# changed line and advance the @@ coordinates for each generated window.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-sharding-test.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
repo="$fixture_root/repo"
fake_bin="$fixture_root/bin"
capture="$fixture_root/requests"
trace_file="$fixture_root/trace.tsv"
mkdir -p "$repo" "$fake_bin"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name sharding-test
seq 1 120 | awk '{ printf "line-%03d\n", $1 }' >"$repo/A.txt"
git -C "$repo" add A.txt
git -C "$repo" commit -qm base
seq 1 120 | awk '{ printf "changed-%03d\n", $1 }' >"$repo/A.txt.new"
mv "$repo/A.txt.new" "$repo/A.txt"

cat >"$fake_bin/ollama" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
count_file="${LOCAL_REVIEW_CAPTURE}.count"
count=0
if [[ -f "$count_file" ]]; then
  count="$(cat "$count_file")"
fi
count=$((count + 1))
printf '%s\n' "$count" >"$count_file"
for ((i = 1; i <= $#; i++)); do
  if [[ "${!i}" == @* ]]; then
    cat "${!i#@}" >>"$LOCAL_REVIEW_CAPTURE"
    printf '\n--- request boundary ---\n' >>"$LOCAL_REVIEW_CAPTURE"
  fi
done
printf '{"response":"P1 A.txt:1 - 认证令牌从 URL 查询参数读取，分片变体 %s。影响：令牌可能进入访问日志。修复建议：改用受保护的请求头。验证方式：检查代理日志。","done":true,"done_reason":"stop"}\n' "$count"
EOF
chmod +x "$fake_bin/ollama" "$fake_bin/curl"

sharded_output="$(PATH="$fake_bin:$PATH" \
  LOCAL_REVIEW_CAPTURE="$capture" \
  OLLAMA_REVIEW_TRACE_FILE="$trace_file" \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review \
  OLLAMA_REVIEW_MAX_DIFF_BYTES=1000 \
  OLLAMA_REVIEW_CHUNK_NUM_PREDICT=256 \
  OLLAMA_REVIEW_NUM_CTX=16384 \
  "$repo_root/bin/local-review.sh" --repo "$repo")"

expected="$(printf '%s\n' \
  '@@ -1,86 +1,0 @@' \
  '@@ -87,34 +1,43 @@' \
  '@@ -121,0 +44,69 @@' \
  '@@ -121,0 +113,8 @@' | sort)"
actual="$(grep -o '@@ -[0-9,]* +[0-9,]* @@' "$capture" | sort -u)"
[[ "$actual" == "$expected" ]] || {
  echo 'oversized hunk coordinates changed unexpectedly' >&2
  printf '%s\n' "$actual" >&2
  exit 1
}

shard_finding_count="$(printf '%s\n' "$sharded_output" | grep -c '^P1 A.txt:1' || true)"
[[ "$shard_finding_count" == "1" ]] || {
  echo 'semantic shard aggregation retained repeated findings at one location' >&2
  printf '%s\n' "$sharded_output" >&2
  exit 1
}

grep -E '^chunk_count[[:space:]]+[2-9][0-9]*$' "$trace_file" >/dev/null || {
  echo 'sharding trace did not record the generated chunk count' >&2
  cat "$trace_file" >&2
  exit 1
}
if awk -F '\t' '$1 == "chunk_status" && ($3 != 0 || $4 !~ /^[0-9]+$/ || $5 !~ /^[1-9][0-9]*$/) { bad = 1 } END { exit(bad ? 1 : 0) }' "$trace_file"; then
  :
else
  echo 'sharding trace recorded a failed or malformed chunk status' >&2
  cat "$trace_file" >&2
  exit 1
fi
grep -E '^chunk_paths[[:space:]]+chunk-[0-9]{4}[[:space:]]+[^[:space:]]' "$trace_file" >/dev/null || {
  echo 'sharding trace did not record chunk paths' >&2
  cat "$trace_file" >&2
  exit 1
}
if awk -F '\t' '$1 == "chunk_prompt" && ($3 !~ /^[1-9][0-9]*$/ || $4 !~ /^[1-9][0-9]*$/) { bad = 1 } END { exit(bad ? 1 : 0) }' "$trace_file"; then
  :
else
  echo 'sharding trace recorded malformed prompt size/token estimates' >&2
  cat "$trace_file" >&2
  exit 1
fi

echo 'diff sharding regression passed'
