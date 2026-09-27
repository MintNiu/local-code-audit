#!/usr/bin/env bash
set -euo pipefail

# Regression coverage for evidence-sensitive output filtering.  This suite
# never contacts Ollama: a fake curl returns fixed model blocks and a fake
# ollama satisfies the local model probe.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-filter-evidence.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
fake_bin="$fixture_root/bin"
response_file="$fixture_root/response.txt"
filter_evidence_failures=0
mkdir -p "$fake_bin"

export LOCAL_REVIEW_EXAMPLES_FILE=/dev/null
export OLLAMA_REVIEW_MODEL=filter-evidence-fixture
export OLLAMA_REVIEW_MAX_DIFF_BYTES=60000
export OLLAMA_REVIEW_NUM_CTX=65536
export OLLAMA_REVIEW_RETRY_ATTEMPTS=0
export LOCAL_REVIEW_TEST_RESPONSE="$response_file"

cat >"$fake_bin/ollama" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "show" ]]; then
  exit 0
fi
exit 0
EOF
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec jq -n --rawfile response "$LOCAL_REVIEW_TEST_RESPONSE" \
  '{response: $response, done: true, done_reason: "stop"}'
EOF
chmod +x "$fake_bin/ollama" "$fake_bin/curl"

new_repo() {
  local name="$1" repo
  repo="$fixture_root/$name"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name filter-evidence-test
  printf '%s\n' "$repo"
}

run_review() {
  local name="$1" repo="$2" response="$3" output error
  output="$fixture_root/$name.out"
  error="$fixture_root/$name.err"
  local status=0
  printf '%s\n' "$response" >"$response_file"
  if PATH="$fake_bin:$PATH" "$repo_root/bin/local-review.sh" --repo "$repo" >"$output" 2>"$error"; then
    status=0
  else
    status=$?
  fi
  if [[ "$status" != 0 ]]; then
    printf 'FAIL %s: review exited %s\n' "$name" "$status" >&2
    cat "$output" "$error" >&2
    filter_evidence_failures=$((filter_evidence_failures + 1))
  fi
  printf '%s\n' "$output"
}

assert_contains() {
  local name="$1" output="$2" marker="$3"
  grep -F "$marker" "$output" >/dev/null || {
    printf 'FAIL %s: expected independent finding marker %s\n' "$name" "$marker" >&2
    cat "$output" >&2
    filter_evidence_failures=$((filter_evidence_failures + 1))
  }
}

# A single mapper contains one correctly correlated EXISTS query and another
# query with no tenant predicate.  Path-wide evidence must not let the safe
# query hide the independent cross-tenant finding.
mixed_repo="$(new_repo mixed-mapper)"
mkdir -p "$mixed_repo/src/main/resources"
cat >"$mixed_repo/src/main/resources/EmployeeMapper.xml" <<'EOF'
<mapper namespace="example.EmployeeMapper">
  <select id="findSafe">
    SELECT * FROM employee employment
    WHERE EXISTS (
      SELECT 1 FROM assignment selectable_primary
      WHERE selectable_primary.tenant_id = employment.tenant_id
        AND selectable_primary.employment_id = employment.id
    )
  </select>
</mapper>
EOF
git -C "$mixed_repo" add .
git -C "$mixed_repo" commit -qm base
sed -i.bak '$d' "$mixed_repo/src/main/resources/EmployeeMapper.xml"
rm -f "$mixed_repo/src/main/resources/EmployeeMapper.xml.bak"
cat >>"$mixed_repo/src/main/resources/EmployeeMapper.xml" <<'EOF'
  <select id="findUnsafe">
    SELECT * FROM employee employment
    WHERE employment.status = 'ACTIVE'
  </select>
</mapper>
EOF
mixed_output="$(run_review mixed-mapper "$mixed_repo" 'P2 src/main/resources/EmployeeMapper.xml:4-7 - SAFE_GENERIC_MARKER：EXISTS 子查询未显式限制租户隔离，可能返回其他租户数据。
影响：跨租户查询可能泄漏数据。
修复建议：增加 tenant_id 约束。
验证方式：使用两个租户执行查询。

P1 src/main/resources/EmployeeMapper.xml:11-13 - MIXED_UNSAFE_MARKER：另一条查询未限制租户隔离，可能返回其他租户数据。
影响：查询没有 tenant_id 条件，可直接跨租户读取记录。
修复建议：在该查询中绑定当前租户并补充跨租户回归。
验证方式：使用两个租户分别执行 findUnsafe，确认结果集合互不相交。')"
assert_contains mixed-mapper "$mixed_output" MIXED_UNSAFE_MARKER

# A deleted tenant guard is evidence of a regression, not proof that a guard
# still exists.  The deleted line is intentionally present in the diff input;
# the filter must not suppress the model's concrete deletion finding.
deleted_repo="$(new_repo deleted-tenant-guard)"
mkdir -p "$deleted_repo/src/main/resources"
cat >"$deleted_repo/src/main/resources/EmployeeMapper.xml" <<'EOF'
<mapper namespace="example.EmployeeMapper">
  <select id="findById">
    SELECT * FROM employee employment
    WHERE EXISTS (
      SELECT 1 FROM assignment selectable_primary
      WHERE selectable_primary.tenant_id = employment.tenant_id
        AND selectable_primary.employment_id = employment.id
    )
  </select>
</mapper>
EOF
git -C "$deleted_repo" add .
git -C "$deleted_repo" commit -qm base
sed -i.bak '/selectable_primary\.tenant_id = employment\.tenant_id/d' \
  "$deleted_repo/src/main/resources/EmployeeMapper.xml"
rm -f "$deleted_repo/src/main/resources/EmployeeMapper.xml.bak"
deleted_output="$(run_review deleted-tenant-guard "$deleted_repo" 'P1 src/main/resources/EmployeeMapper.xml:6 - DELETED_TENANT_GUARD_MARKER：删除了 tenant_id 关联条件，导致当前 EXISTS 子查询未限制租户隔离。
影响：删除行会使其他租户的 assignment 进入结果，造成跨租户数据泄漏。
修复建议：恢复 selectable_primary.tenant_id = employment.tenant_id，并补充删除路径回归。
验证方式：用两个租户执行 findById，确认租户条件仍然存在且结果隔离。')"
assert_contains deleted-tenant-guard "$deleted_output" DELETED_TENANT_GUARD_MARKER

# An alias mismatch is an independent tenant defect even though the same
# subquery also contains a tenant_id equality pattern.  Keep the concrete
# error visible instead of treating any matching equality as a valid guard.
alias_repo="$(new_repo alias-mismatch)"
mkdir -p "$alias_repo/src/main/resources"
cat >"$alias_repo/src/main/resources/EmployeeMapper.xml" <<'EOF'
<mapper namespace="example.EmployeeMapper">
  <select id="findById">
    SELECT * FROM employee employment
    WHERE EXISTS (
      SELECT 1 FROM assignment selectable_primary
      WHERE selectable_primary.tenant_id = employment.tenant_id
        AND selectable_primary.employment_id = employment.id
    )
  </select>
</mapper>
EOF
git -C "$alias_repo" add .
git -C "$alias_repo" commit -qm base
sed -i.bak 's/employment\.tenant_id/employments.tenant_id/' \
  "$alias_repo/src/main/resources/EmployeeMapper.xml"
rm -f "$alias_repo/src/main/resources/EmployeeMapper.xml.bak"
alias_output="$(run_review alias-mismatch "$alias_repo" 'P1 src/main/resources/EmployeeMapper.xml:6 - ALIAS_MISMATCH_MARKER：子查询 tenant_id 别名错误且不匹配外层表别名，租户条件实际不可用。
影响：SQL 可能因未知列失败，或无法按预期隔离租户。
修复建议：统一子查询和外层查询的表别名，并增加 SQL 映射测试。
验证方式：执行 findById 的 SQL 解析/集成测试，确认别名可解析且两个租户结果隔离。')"
assert_contains alias-mismatch "$alias_output" ALIAS_MISMATCH_MARKER

# A structured P1 for a token that is actually written to logs is concrete
# evidence.  It must survive the generic "missing logging is out of scope"
# filter even when the wording contains 日志记录.
log_repo="$(new_repo token-log)"
mkdir -p "$log_repo/src/main/java/example"
cat >"$log_repo/src/main/java/example/AuditLogger.java" <<'EOF'
package example;

final class AuditLogger {
    private final Logger logger = new Logger();

    void record(String token) {
        logger.info("authentication token redacted");
    }

    static final class Logger {
        void info(String format, Object value) { }
    }
}
EOF
git -C "$log_repo" add .
git -C "$log_repo" commit -qm base
sed -i.bak 's/logger\.info("authentication token redacted");/logger.info("authentication token={}", token);/' \
  "$log_repo/src/main/java/example/AuditLogger.java"
rm -f "$log_repo/src/main/java/example/AuditLogger.java.bak"
log_output="$(run_review token-log "$log_repo" 'P1 src/main/java/example/AuditLogger.java:7 - STRUCTURED_TOKEN_LOG_MARKER：认证 token 在日志记录中以明文输出，可能进入访问日志。
影响：token 可能被日志、代理或集中式采集系统持久化，造成凭据泄漏。
修复建议：禁止记录 token，仅记录不可逆的请求标识或脱敏摘要。
验证方式：执行 record 并检查应用、网关和集中式日志，确认不再出现 token 值。')"
assert_contains token-log "$log_output" STRUCTURED_TOKEN_LOG_MARKER

if (( filter_evidence_failures > 0 )); then
  printf 'filter evidence regression failed: %s cases\n' "$filter_evidence_failures" >&2
  exit 1
fi
printf 'filter evidence regression passed: 4 cases\n'
