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
request_file=""
for ((i = 1; i <= $#; i++)); do
  if [[ "${!i}" == @* ]]; then
    request_file="${!i#@}"
    if jq -e '.input // .prompt // empty' "$request_file" >/dev/null 2>&1; then
      jq -r '.input // .prompt // empty' "$request_file" >>"$LOCAL_REVIEW_CAPTURE"
    else
      cat "$request_file" >>"$LOCAL_REVIEW_CAPTURE"
    fi
    printf '\n--- request boundary ---\n' >>"$LOCAL_REVIEW_CAPTURE"
  fi
done
if [[ "${LOCAL_REVIEW_FAKE_CLEAN:-}" == true ]] || {
  [[ -n "$request_file" ]] && grep -Eq 'access-key-id|PlatformProperties\.java' "$request_file";
}; then
  printf '{"response":"未发现阻塞问题","done":true,"done_reason":"stop"}\n'
  exit 0
fi
printf '{"response":"P1 A.txt:1 - 认证令牌从 URL 查询参数读取，分片变体 %s。\\n影响：令牌可能进入访问日志。\\n修复建议：改用受保护的请求头。\\n验证方式：检查代理日志。","done":true,"done_reason":"stop"}\n' "$count"
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

# A config-heavy diff adds deterministic credential evidence to each routed
# shard. The budget planner must account for that variable prompt section
# instead of relying on the old fixed reserve, while still completing every
# fake model request.
budget_repo="$fixture_root/budget-repo"
budget_meta="$fixture_root/budget.tsv"
mkdir -p "$budget_repo"
git -C "$budget_repo" init -q
git -C "$budget_repo" config user.email test@example.invalid
git -C "$budget_repo" config user.name sharding-budget-test
printf 'base\n' >"$budget_repo/A.txt"
git -C "$budget_repo" add A.txt
git -C "$budget_repo" commit -qm base
printf 'changed\n' >"$budget_repo/A.txt"
cat >"$budget_repo/application.yml" <<'EOF'
storage:
  endpoint: https://storage.example.invalid
  access-key-id: AKID_1234567890abcdef
  access-key-secret: SECRET_1234567890abcdef
  password: password_1234567890
gateway:
  internal-token: token_1234567890
  api-key: api_key_1234567890
database:
  username: app-user
  passwd: passwd_1234567890
  secret-key: secret_1234567890
EOF
PATH="$fake_bin:$PATH" LOCAL_REVIEW_CAPTURE="$capture" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review \
  LOCAL_REVIEW_FAKE_CLEAN=true \
  OLLAMA_REVIEW_MAX_DIFF_BYTES=1000 \
  OLLAMA_REVIEW_CHUNK_NUM_PREDICT=256 \
  OLLAMA_REVIEW_NUM_CTX=16384 \
  OLLAMA_REVIEW_RESOLVED_CHUNK_BYTES_FILE="$budget_meta" \
  "$repo_root/bin/local-review.sh" --repo "$budget_repo" >/dev/null
grep -E '^chunk_budget_preflight_reserve_tokens[[:space:]]+[5-9][0-9][0-9]$|^chunk_budget_preflight_reserve_tokens[[:space:]]+[1-9][0-9]{3,}$' "$budget_meta" >/dev/null || {
  echo 'budget planner did not expand the reserve for routed preflight evidence' >&2
  cat "$budget_meta" >&2
  exit 1
}

# Cross-file symbol evidence must be deterministic, scoped to the current
# snapshot, and routed only to shards containing the changed Java path. This
# fixture keeps the caller unchanged while growing the properties file enough
# to force the split path; the fake model makes the assertion independent of
# Ollama quality or availability.
evidence_repo="$fixture_root/evidence-repo"
evidence_capture="$fixture_root/evidence-requests"
mkdir -p "$evidence_repo/src/main/java/com/example"
git -C "$evidence_repo" init -q
git -C "$evidence_repo" config user.email test@example.invalid
git -C "$evidence_repo" config user.name cross-file-evidence-test
cat >"$evidence_repo/src/main/java/com/example/PlatformProperties.java" <<'EOF'
package com.example;

import lombok.Data;

@Data
final class PlatformProperties {
    private String internalToken;

    String requireInternalToken() {
        return internalToken;
    }
}
EOF
cat >"$evidence_repo/src/main/java/com/example/Caller.java" <<'EOF'
package com.example;

final class Caller {
    String read(PlatformProperties properties) {
        return properties.requireInternalToken();
    }
}
EOF
git -C "$evidence_repo" add .
git -C "$evidence_repo" commit -qm base
for field in $(seq 1 160); do
  printf '    private String field%03d;\n' "$field" >>"$evidence_repo/src/main/java/com/example/PlatformProperties.java"
done
PATH="$fake_bin:$PATH" LOCAL_REVIEW_CAPTURE="$evidence_capture" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review \
  OLLAMA_REVIEW_MAX_DIFF_BYTES=1000 \
  OLLAMA_REVIEW_CHUNK_NUM_PREDICT=256 \
  OLLAMA_REVIEW_NUM_CTX=16384 \
  "$repo_root/bin/local-review.sh" --repo "$evidence_repo" >/dev/null
grep -F '构建预检（确定性证据：跨文件符号文本索引）' "$evidence_capture" >/dev/null || {
  echo 'cross-file evidence heading was not routed to a shard request' >&2
  exit 1
}
grep -F 'PlatformProperties.java：跨文件符号文本索引显示 requireInternalToken()' "$evidence_capture" >/dev/null || {
  echo 'cross-file require* evidence was not indexed or routed' >&2
  exit 1
}

# Transaction/row-lock evidence must include unchanged related operations so
# the model can compare lock sequences across files. A directly visible
# reverse sequence is also emitted as a conservative deterministic candidate;
# the prompt-only evidence itself must never leak into the final output.
lock_repo="$fixture_root/lock-repo"
lock_capture="$fixture_root/lock-requests"
mkdir -p "$lock_repo/src/main/java/com/example"
git -C "$lock_repo" init -q
git -C "$lock_repo" config user.email test@example.invalid
git -C "$lock_repo" config user.name lock-evidence-test
cat >"$lock_repo/src/main/java/com/example/ReturnService.java" <<'EOF'
package com.example;

final class ReturnService {
    private final SalesOrderRepository salesOrderRepository;
    private final ReturnRepository returnRepository;

    @Transactional
    void submit(long id) {
        salesOrderRepository.findByIdForUpdate(id);
        returnRepository.findByIdForUpdate(id);
    }
}
EOF
cat >"$lock_repo/src/main/java/com/example/InspectionService.java" <<'EOF'
package com.example;

final class InspectionService {
    private final InspectionRepository inspectionRepository;
    private final ReturnRepository returnRepository;
    private final SalesOrderRepository salesOrderRepository;

    @Transactional
    void confirm(long id) {
        inspectionRepository.findByIdForUpdate(id);
        returnRepository.findByIdForUpdate(id);
        refresh(id);
    }

    private void refresh(long id) {
        salesOrderRepository.findByIdForUpdate(id);
    }
}
EOF
git -C "$lock_repo" add .
git -C "$lock_repo" commit -qm base
printf '\n    // changed transaction path\n' >>"$lock_repo/src/main/java/com/example/ReturnService.java"
for line in $(seq 1 160); do
  printf '    // filler-%03d\n' "$line" >>"$lock_repo/src/main/java/com/example/ReturnService.java"
done
lock_output="$(PATH="$fake_bin:$PATH" LOCAL_REVIEW_CAPTURE="$lock_capture" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review \
  LOCAL_REVIEW_FAKE_CLEAN=true \
  OLLAMA_REVIEW_MAX_DIFF_BYTES=1000 \
  OLLAMA_REVIEW_CHUNK_NUM_PREDICT=256 \
  OLLAMA_REVIEW_NUM_CTX=16384 \
  "$repo_root/bin/local-review.sh" --repo "$lock_repo")"
grep -F 'P1 src/main/java/com/example/ReturnService.java:9,10 - 事务内行锁存在反向锁序候选' <<<"$lock_output" >/dev/null || {
  echo 'deterministic reverse lock-order candidate was not emitted' >&2
  printf '%s\n' "$lock_output" >&2
  exit 1
}
if printf '%s\n' "$lock_output" | grep -F '跨事务/行锁文本序列' >/dev/null; then
  echo 'prompt-only lock evidence leaked into final findings' >&2
  exit 1
fi
grep -F '构建预检（确定性证据：跨事务/行锁文本序列；仅供模型核验）' "$lock_capture" >/dev/null || {
  echo 'transaction lock evidence heading was not included' >&2
  exit 1
}
grep -F 'InspectionService.java（未变更关联文件）' "$lock_capture" >/dev/null || {
  echo 'unchanged lock-related Java file was not included in evidence' >&2
  exit 1
}
grep -F 'findByIdForUpdate' "$lock_capture" >/dev/null || {
  echo 'transaction lock evidence did not include row-lock calls' >&2
  exit 1
}
extract_lock_block() {
  local target="$1"
  awk -v target="$target" '
    index($0, target "（") { in_block = 1; next }
    in_block && /^--- 跨事务\/行锁文本证据结束 ---/ { exit }
    in_block && /\.java（/ { exit }
    in_block { print }
  ' "$lock_capture"
}
return_order="$(extract_lock_block 'ReturnService.java' | grep -oE '[a-z][A-Za-z0-9_]*Repository\.findByIdForUpdate' | sed 's/\.findByIdForUpdate$//' | awk '!seen[$0]++' | paste -sd '>' -)"
[[ "$return_order" == 'salesOrderRepository>returnRepository' ]] || {
  echo 'changed transaction lock order was not preserved in evidence' >&2
  printf '%s\n' "$return_order" >&2
  exit 1
}
inspection_order="$(extract_lock_block 'InspectionService.java' | grep -oE '[a-z][A-Za-z0-9_]*Repository\.findByIdForUpdate' | sed 's/\.findByIdForUpdate$//' | awk '!seen[$0]++' | paste -sd '>' -)"
[[ "$inspection_order" == 'inspectionRepository>returnRepository>salesOrderRepository' ]] || {
  echo 'unchanged transaction lock order was not preserved in evidence' >&2
  printf '%s\n' "$inspection_order" >&2
  exit 1
}
echo 'diff sharding regression passed'
