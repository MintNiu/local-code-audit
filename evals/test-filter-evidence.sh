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
if [[ "${LOCAL_REVIEW_TEST_TRANSPORT_FAIL:-0}" == "1" ]]; then
  exit 28
fi
done_reason="${LOCAL_REVIEW_TEST_DONE_REASON:-stop}"
exec jq -n --rawfile response "$LOCAL_REVIEW_TEST_RESPONSE" --arg done_reason "$done_reason" \
  '{response: $response, done: true, done_reason: $done_reason}'
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

assert_truncated_independent_finding_fails() {
  local name="$1" repo="$2" response="$3"
  local output="$fixture_root/$name.out" error="$fixture_root/$name.err" status=0
  printf '%s\n' "$response" >"$response_file"
  if PATH="$fake_bin:$PATH" "$repo_root/bin/local-review.sh" --repo "$repo" >"$output" 2>"$error"; then
    status=0
  else
    status=$?
  fi
  if [[ "$status" == 0 ]] || grep -Fx '未发现阻塞问题' "$output" >/dev/null; then
    printf 'FAIL %s: truncated response with an independent finding was accepted as clean\n' "$name" >&2
    cat "$output" "$error" >&2
    filter_evidence_failures=$((filter_evidence_failures + 1))
    return
  fi
  grep -F 'MODEL_NPE_MARKER' "$error" >/dev/null || {
    printf 'FAIL %s: independent finding was not preserved in truncation diagnostic\n' "$name" >&2
    cat "$output" "$error" >&2
    filter_evidence_failures=$((filter_evidence_failures + 1))
  }
}

assert_truncated_response_fails() {
  local name="$1" repo="$2" response="$3" expected_marker="$4"
  local output="$fixture_root/$name.out" error="$fixture_root/$name.err" status=0
  printf '%s\n' "$response" >"$response_file"
  if PATH="$fake_bin:$PATH" "$repo_root/bin/local-review.sh" --repo "$repo" >"$output" 2>"$error"; then
    status=0
  else
    status=$?
  fi
  if [[ "$status" == 0 ]] || grep -Fx '未发现阻塞问题' "$output" >/dev/null; then
    printf 'FAIL %s: truncated response was accepted as a complete review\n' "$name" >&2
    cat "$output" "$error" >&2
    filter_evidence_failures=$((filter_evidence_failures + 1))
    return
  fi
  grep -F '模型输出因长度限制被截断' "$error" >/dev/null || {
    printf 'FAIL %s: truncation was not reported fail-closed\n' "$name" >&2
    cat "$output" "$error" >&2
    filter_evidence_failures=$((filter_evidence_failures + 1))
  }
  grep -F "$expected_marker" "$error" >/dev/null || {
    printf 'FAIL %s: deterministic diagnostic was not preserved\n' "$name" >&2
    cat "$output" "$error" >&2
    filter_evidence_failures=$((filter_evidence_failures + 1))
  }
}

# Compatibility name for the two historical fixtures: they now assert the
# safer fail-closed contract instead of treating a truncated response as a
# successful recovery.
assert_truncated_response_recovers_deterministic_only() {
  assert_truncated_response_fails "$@"
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

# A model explanation of a safe header-only transport is not an information
# finding.  It must normalize to the clean marker without hiding a concrete
# security claim.
safe_output="$(run_review safe-negative "$mixed_repo" '信息 src/main/resources/EmployeeMapper.xml:1-13 - 令牌只通过内部请求头传递，符合安全边界规则，无需修复。
影响：没有证据表明该请求会进入日志或外部边界。
修复建议：无需修复，当前实现符合安全负例契约。
验证方式：确认差异中没有日志、持久化或外部跳转证据。')"
if ! grep -Fx '未发现阻塞问题' "$safe_output" >/dev/null; then
  printf 'FAIL safe-negative: expected clean marker\n' >&2
  cat "$safe_output" >&2
  filter_evidence_failures=$((filter_evidence_failures + 1))
fi

# A permission-interceptor migration has a deterministic preflight finding.
# The model must not turn the missing service implementation from a shard into
# repeated conditional "if the service does not validate" findings; the
# preflight paragraph remains the authoritative visible issue.
permission_repo="$(new_repo xxl-permission-migration)"
mkdir -p "$permission_repo/src/main/java/example"
cat >"$permission_repo/src/main/java/example/JobInfoController.java" <<'EOF'
package example;

class JobInfoController {
  @RequestMapping("/jobinfo/remove")
  void remove(LoginUser loginUser) {
    xxlJobService.remove();
  }
}
EOF
git -C "$permission_repo" add .
git -C "$permission_repo" commit -qm base
printf '%s\n' '  private PermissionInterceptor permissionInterceptor;' >>"$permission_repo/src/main/java/example/JobInfoController.java"
permission_output="$(run_review permission-migration "$permission_repo" 'P1 src/main/java/example/JobInfoController.java:7 - SPECULATIVE_PERMISSION_MARKER：当前分片未展示服务层实现，如果服务层未执行 job group 权限校验，普通用户可能越权修改任务。
影响：如果服务层缺少权限校验，可能发生越权。
修复建议：检查服务层是否调用 validJobGroupPermission。
验证方式：检查服务层实现并执行跨组请求。')"
if grep -F 'SPECULATIVE_PERMISSION_MARKER' "$permission_output" >/dev/null ||
   ! grep -F '权限拦截器重构后仍有同类任务/日志入口未执行' "$permission_output" >/dev/null; then
  printf 'FAIL permission-migration: speculative model duplicate was not filtered or preflight finding missing\n' >&2
  cat "$permission_output" >&2
  filter_evidence_failures=$((filter_evidence_failures + 1))
fi

# If the same narrow permission response reaches Ollama's length cap, the
# wrapper must fail closed even though the deterministic preflight is known.
# The unseen suffix could contain another independent authorization root.
export LOCAL_REVIEW_TEST_DONE_REASON=length
assert_truncated_response_fails permission-migration-truncated "$permission_repo" 'P1 src/main/java/example/JobInfoController.java:7 - SPECULATIVE_PERMISSION_MARKER：当前分片未展示服务层实现，如果服务层未执行 job group 权限校验，普通用户可能越权修改任务。
影响：如果服务层缺少权限校验，可能发生越权。
修复建议：检查服务层是否调用 validJobGroupPermission。
验证方式：检查服务层实现并执行跨组请求。

P1 src/main/java/example/JobInfoController.java:1-8 - 权限拦截器重构后仍有同类任务/日志入口未执行 job group 权限校验，授权修复不完整。
影响：普通用户可能越权访问任务。
修复建议：统一调用 validJobGroupPermission。
验证方式：执行跨组请求。' '权限拦截器重构后仍有同类任务/日志入口未执行'
export LOCAL_REVIEW_TEST_DONE_REASON=stop

# Legal generated-column syntax and an unconstrained DDL tenant-column
# suggestion are information-level speculation without a visible contract;
# both must normalize to clean while concrete SQL/tenant findings remain.
ddl_repo="$(new_repo ddl-safe-info)"
mkdir -p "$ddl_repo/sql"
cat >"$ddl_repo/sql/schema.sql" <<'EOF'
CREATE TABLE hr_employment (
  id BIGINT PRIMARY KEY,
  status VARCHAR(32) NOT NULL,
  active_person_id BIGINT GENERATED ALWAYS AS (CASE WHEN status = 'ACTIVE' THEN id ELSE NULL END) STORED
);
EOF
git -C "$ddl_repo" add .
git -C "$ddl_repo" commit -qm base
printf '%s\n' '-- reviewed generated column' >>"$ddl_repo/sql/schema.sql"
ddl_output="$(run_review ddl-safe-info "$ddl_repo" '信息 sql/schema.sql:1-5 - 新增表缺少租户字段，可能导致跨租户数据混淆。
影响：可能跨租户读取数据。
修复建议：添加 tenant_id 字段。
验证方式：检查租户查询。

信息 sql/schema.sql:4 - `active_person_id` 列定义使用 `GENERATED ALWAYS AS (...) STORED`，这是 MySQL 合法且明确的存储方式，不构成语法错误或缺少 `STORED`/`VIRTUAL` 的问题。
影响：无。
修复建议：无。
验证方式：无。')"
if ! grep -Fx '未发现阻塞问题' "$ddl_output" >/dev/null || grep -Eq '^[[:space:]]*(P[0-3]|信息)[[:space:]:：]' "$ddl_output"; then
  printf 'FAIL ddl-safe-info: legal/generated-column information was not filtered to clean\n' >&2
  cat "$ddl_output" >&2
  filter_evidence_failures=$((filter_evidence_failures + 1))
fi

# Commented authorization annotations are a concrete P1, but a second
# information paragraph that only repeats the readability/maintenance angle
# must not leak into the final report.
permission_info_output="$(run_review permission-info "$permission_repo" '信息 src/main/java/example/JobInfoController.java:1-8 - 注释掉的权限注解会降低代码可读性，可能导致维护人员忽略权限要求。
影响：代码一致性下降。
修复建议：移除注释并保持代码一致性。
验证方式：检查代码风格规范。')"
if ! grep -F '权限拦截器重构后仍有同类任务/日志入口未执行' "$permission_info_output" >/dev/null ||
   grep -Eq '^[[:space:]]*信息[[:space:]:：]' "$permission_info_output"; then
  printf 'FAIL permission-info: non-actionable authorization information was not filtered\n' >&2
  cat "$permission_info_output" >&2
  filter_evidence_failures=$((filter_evidence_failures + 1))
fi

# A changed controller that comments out an authorization annotation must be
# covered by deterministic preflight. The model's duplicate wording and its
# maintenance-only information paragraph are both discarded.
authorization_repo="$(new_repo authorization-annotation)"
mkdir -p "$authorization_repo/src/main/java/example"
cat >"$authorization_repo/src/main/java/example/BrandController.java" <<'EOF'
package example;

class BrandController {
  @PreAuthorize("brand:read")
  void page() { }
}
EOF
git -C "$authorization_repo" add .
git -C "$authorization_repo" commit -qm base
sed -i.bak 's/^  @PreAuthorize/  \/\/\@PreAuthorize/' \
  "$authorization_repo/src/main/java/example/BrandController.java"
rm -f "$authorization_repo/src/main/java/example/BrandController.java.bak"
authorization_output="$(run_review authorization-annotation "$authorization_repo" 'P1 src/main/java/example/BrandController.java:4 - MODEL_AUTH_DUPLICATE：删除授权注解导致端点失去权限检查。
影响：普通用户可能调用该端点。
修复建议：恢复注解。
验证方式：用无权限用户调用接口。

信息 src/main/java/example/BrandController.java:4 - 注释掉的权限注解会降低代码可读性，可能导致维护人员忽略权限要求。
影响：代码一致性下降。
修复建议：移除注释。
验证方式：检查代码风格。')"
if ! grep -F '声明式权限注解被注释/删除' "$authorization_output" >/dev/null ||
   ! grep -F 'MODEL_AUTH_DUPLICATE' "$authorization_output" >/dev/null ||
   grep -Eq '^[[:space:]]*信息[[:space:]:：]' "$authorization_output"; then
  printf 'FAIL authorization-annotation: model and deterministic findings were not both preserved\n' >&2
  cat "$authorization_output" >&2
  filter_evidence_failures=$((filter_evidence_failures + 1))
fi

# A presigned-ticket fixture has a deterministic replay preflight. Repeated
# lifecycle variants from the model are duplicates, not independent findings;
# keep the deterministic P1 and discard the model's speculative paragraphs.
presigned_repo="$(new_repo presigned-replay)"
mkdir -p "$presigned_repo/src"
cp "$repo_root/evals/fixtures/java-presigned-replay/src/UploadSessionService.java" \
  "$presigned_repo/src/UploadSessionService.java"
git -C "$presigned_repo" add .
git -C "$presigned_repo" commit -qm base
printf '%s\n' '// changed objectKey lifecycle evidence' >>"$presigned_repo/src/UploadSessionService.java"
presigned_output="$(run_review presigned-replay "$presigned_repo" 'P1 src/UploadSessionService.java:25-27 - MODEL_PRESIGNED_DUPLICATE：取消后票据仍可重放，可能造成对象存储资源泄漏。
影响：取消后的预签名票据仍然有效。
修复建议：撤销票据。
验证方式：取消后再次上传应失败。

P1 src/UploadSessionService.java:18-21 - MODEL_PRESIGNED_DUPLICATE_2：缺少过期票据校验，可能接受无效票据。
影响：过期票据可能写入对象。
修复建议：校验过期时间。
验证方式：使用过期票据测试。')"
if ! grep -F '取消后仍可重放有效的预签名上传票据' "$presigned_output" >/dev/null ||
   ! grep -F 'MODEL_PRESIGNED_DUPLICATE' "$presigned_output" >/dev/null; then
  printf 'FAIL presigned-replay: model and deterministic findings were not both preserved\n' >&2
  cat "$presigned_output" >&2
  filter_evidence_failures=$((filter_evidence_failures + 1))
fi
export LOCAL_REVIEW_TEST_DONE_REASON=length
assert_truncated_response_recovers_deterministic_only presigned-replay-truncated "$presigned_repo" 'P1 src/UploadSessionService.java:25-27 - MODEL_PRESIGNED_DUPLICATE：取消后票据仍可重放，可能造成对象存储资源泄漏。
影响：取消后的预签名票据仍然有效。
修复建议：撤销票据。
验证方式：取消后再次上传应失败。

P1 src/UploadSessionService.java:18-21 - MODEL_PRESIGNED_DUPLICATE_2：缺少过期票据校验，可能接受无效票据。
影响：过期票据可能写入对象。
修复建议：校验过期时间。
验证方式：使用过期票据测试。' '取消后仍可重放有效的预签名上传票据'
export LOCAL_REVIEW_TEST_DONE_REASON=stop
export LOCAL_REVIEW_TEST_DONE_REASON=length
assert_truncated_independent_finding_fails presigned-replay-independent "$presigned_repo" 'P1 src/UploadSessionService.java:25-27 - MODEL_PRESIGNED_DUPLICATE：取消后票据仍可重放，可能造成对象存储资源泄漏。
影响：取消后的预签名票据仍然有效。
修复建议：撤销票据。
验证方式：取消后再次上传应失败。

P2 src/main/java/example/JobLogController.java:6 - MODEL_NPE_MARKER：executorBiz 可能为 null，调用 log 时触发 NullPointerException。
影响：请求路径可能返回 500 并中断日志查询。
修复建议：在调用前显式校验 executorBiz 或让工厂失败闭环。
验证方式：覆盖无效地址/客户端构造失败场景。'
export LOCAL_REVIEW_TEST_DONE_REASON=stop
export LOCAL_REVIEW_TEST_TRANSPORT_FAIL=1
presigned_transport_output="$(run_review presigned-replay-transport "$presigned_repo" '未使用的响应体')"
unset LOCAL_REVIEW_TEST_TRANSPORT_FAIL
if ! grep -F '取消后仍可重放有效的预签名上传票据' "$presigned_transport_output" >/dev/null ||
   grep -F '未使用的响应体' "$presigned_transport_output" >/dev/null; then
  printf 'FAIL presigned-replay-transport: deterministic singleton preflight was not recovered safely\n' >&2
  cat "$presigned_transport_output" >&2
  filter_evidence_failures=$((filter_evidence_failures + 1))
fi

# A controller must not pass a request-supplied executorAddress directly to
# the XXL-JOB RPC client. The narrow preflight needs all three pieces of
# evidence in the changed Java path: request mapping, String parameter, and
# the NetComClientProxy sink. A clean fake model response must still expose
# the deterministic P1.
ssrf_repo="$(new_repo direct-address-ssrf)"
mkdir -p "$ssrf_repo/src/main/java/example"
cat >"$ssrf_repo/src/main/java/example/JobLogController.java" <<'EOF'
package example;

class JobLogController {
  @RequestMapping("/logDetailCat")
  ReturnT<?> logDetailCat(String executorAddress, int logId) {
    return null;
  }
}
EOF
git -C "$ssrf_repo" add .
git -C "$ssrf_repo" commit -qm base
cat >"$ssrf_repo/src/main/java/example/JobLogController.java" <<'EOF'
package example;

class JobLogController {
  @RequestMapping("/logDetailCat")
  ReturnT<?> logDetailCat(String executorAddress, int logId) {
    ExecutorBiz executorBiz = (ExecutorBiz) new NetComClientProxy(ExecutorBiz.class, executorAddress).getObject();
    return executorBiz.log(logId);
  }
}
EOF
ssrf_output="$(run_review direct-address-ssrf "$ssrf_repo" '未发现阻塞问题')"
if ! grep -F '直接传入 NetComClientProxy' "$ssrf_output" >/dev/null ||
   ! grep -F 'Web 端点把请求参数 executorAddress' "$ssrf_output" >/dev/null; then
  printf 'FAIL direct-address-ssrf: deterministic request-address sink preflight missing\n' >&2
  cat "$ssrf_output" >&2
  filter_evidence_failures=$((filter_evidence_failures + 1))
fi
export LOCAL_REVIEW_TEST_DONE_REASON=length
assert_truncated_response_recovers_deterministic_only direct-address-ssrf-truncated "$ssrf_repo" 'P1 src/main/java/example/JobLogController.java:6 - MODEL_DIRECT_ADDRESS_DUPLICATE：请求参数 executorAddress 直接传入 NetComClientProxy，可能造成 SSRF。
影响：攻击者可能让服务端访问内网地址。
修复建议：只从日志记录加载执行器地址。
验证方式：拒绝 localhost 和 metadata 地址。

P1 src/main/java/example/JobLogController.java:6 - MODEL_DIRECT_ADDRESS_DUPLICATE_2：RPC sink 使用了外部 executorAddress。
影响：请求目标可被探测。
修复建议：校验目标地址。
验证方式：执行 SSRF 回归。' '直接传入 NetComClientProxy'
export LOCAL_REVIEW_TEST_DONE_REASON=stop
export LOCAL_REVIEW_TEST_DONE_REASON=length
assert_truncated_independent_finding_fails direct-address-ssrf-independent "$ssrf_repo" 'P1 src/main/java/example/JobLogController.java:6 - MODEL_DIRECT_ADDRESS_DUPLICATE：请求参数 executorAddress 直接传入 NetComClientProxy，可能造成 SSRF。
影响：攻击者可能让服务端访问内网地址。
修复建议：只从日志记录加载执行器地址。
验证方式：拒绝 localhost 和 metadata 地址。

P2 src/main/java/example/JobLogController.java:6 - MODEL_NPE_MARKER：executorBiz 可能为 null，调用 log 时触发 NullPointerException。
影响：请求路径可能返回 500 并中断日志查询。
修复建议：在调用前显式校验 executorBiz 或让工厂失败闭环。
验证方式：覆盖无效地址/客户端构造失败场景。'
export LOCAL_REVIEW_TEST_DONE_REASON=stop
safe_ssrf_repo="$(new_repo direct-address-ssrf-safe)"
mkdir -p "$safe_ssrf_repo/src/main/java/example"
cat >"$safe_ssrf_repo/src/main/java/example/JobLogController.java" <<'EOF'
package example;

class JobLogController {
  @RequestMapping("/logDetailCat")
  ReturnT<?> logDetailCat(String executorAddress, int logId) {
    XxlJobLog jobLog = dao.load(logId);
    return new NetComClientProxy(ExecutorBiz.class, jobLog.getExecutorAddress()).getObject();
  }
}
EOF
git -C "$safe_ssrf_repo" add .
git -C "$safe_ssrf_repo" commit -qm base
printf '%s\n' '// no direct request address sink' >>"$safe_ssrf_repo/src/main/java/example/JobLogController.java"
safe_ssrf_output="$(run_review direct-address-ssrf-safe "$safe_ssrf_repo" '未发现阻塞问题')"
if ! grep -Fx '未发现阻塞问题' "$safe_ssrf_output" >/dev/null ||
   grep -F '直接传入 NetComClientProxy' "$safe_ssrf_output" >/dev/null; then
  printf 'FAIL direct-address-ssrf-safe: trusted persisted address was over-reported\n' >&2
  cat "$safe_ssrf_output" >&2
  filter_evidence_failures=$((filter_evidence_failures + 1))
fi

# A raw MyBatis scalar assignment is a deterministic SQL-injection shape. The
# model duplicate must be removed while the authoritative preflight remains.
mybatis_raw_repo="$(new_repo mybatis-raw-substitution)"
mkdir -p "$mybatis_raw_repo/src/main/resources/mybatis-mapper"
cat >"$mybatis_raw_repo/src/main/resources/mybatis-mapper/JobMapper.xml" <<'EOF'
<mapper namespace="example.JobMapper">
  <update id="update">
    UPDATE jobs SET executor_timeout = #{executorTimeout} WHERE id = #{id}
  </update>
</mapper>
EOF
git -C "$mybatis_raw_repo" add .
git -C "$mybatis_raw_repo" commit -qm base
sed -i.bak 's/executor_timeout = #{executorTimeout}/executor_timeout = ${executorTimeout}/' \
  "$mybatis_raw_repo/src/main/resources/mybatis-mapper/JobMapper.xml"
rm -f "$mybatis_raw_repo/src/main/resources/mybatis-mapper/JobMapper.xml.bak"
mybatis_raw_output="$(run_review mybatis-raw-substitution "$mybatis_raw_repo" 'P1 src/main/resources/mybatis-mapper/JobMapper.xml:3 - MODEL_MYBATIS_RAW_DUPLICATE：${executorTimeout} 被直接拼入 UPDATE，存在 SQL 注入风险。
影响：攻击者可改变 SQL 赋值结构。
修复建议：改为 #{executorTimeout} 参数绑定。
验证方式：使用 SQL 片段输入执行 Mapper 集成测试。')"
if ! grep -F 'MyBatis Mapper 将表达式' "$mybatis_raw_output" >/dev/null ||
   ! grep -F 'MODEL_MYBATIS_RAW_DUPLICATE' "$mybatis_raw_output" >/dev/null; then
  printf 'FAIL mybatis-raw-substitution: model and deterministic findings were not both preserved\n' >&2
  cat "$mybatis_raw_output" >&2
  filter_evidence_failures=$((filter_evidence_failures + 1))
fi

# Untracked files are intentionally part of the review scope; their Git
# status is not an information-level code defect. Concrete findings must still
# survive, but a model request to `git add` the file must normalize to clean.
untracked_info_repo="$(new_repo untracked-info)"
mkdir -p "$untracked_info_repo/src/main/java/example"
cat >"$untracked_info_repo/src/main/java/example/LocalProperties.java" <<'EOF'
package example;

final class LocalProperties {
    String value() { return "safe"; }
}
EOF
untracked_info_output="$(run_review untracked-info "$untracked_info_repo" '信息 src/main/java/example/LocalProperties.java:1-5 - UNTRACKED_INFO_MARKER：代码新增但未提交到 Git 仓库，建议添加到 Git。
影响：如果不提交，构建可能缺少配置类。
修复建议：将该文件添加到 Git 仓库中，并检查 Git 状态。
验证方式：确认文件已被跟踪。')"
if ! grep -Fx '未发现阻塞问题' "$untracked_info_output" >/dev/null ||
   grep -F 'UNTRACKED_INFO_MARKER' "$untracked_info_output" >/dev/null; then
  printf 'FAIL untracked-info: Git status prose was not filtered\n' >&2
  cat "$untracked_info_output" >&2
  filter_evidence_failures=$((filter_evidence_failures + 1))
fi

untracked_clean_marker_output="$(run_review untracked-clean-marker "$untracked_info_repo" '信息 src/main/java/example/LocalProperties.java:1-5 - UNTRACKED_CLEAN_MARKER：代码新增但未提交到 Git；仅审查当前差异内容。
影响：无阻塞问题。
修复建议：无。
验证方式：无。')"
if ! grep -Fx '未发现阻塞问题' "$untracked_clean_marker_output" >/dev/null ||
   grep -F 'UNTRACKED_CLEAN_MARKER' "$untracked_clean_marker_output" >/dev/null; then
  printf 'FAIL untracked-clean-marker: clean Git-state prose was not filtered\n' >&2
  cat "$untracked_clean_marker_output" >&2
  filter_evidence_failures=$((filter_evidence_failures + 1))
fi

generic_clean_info_output="$(run_review generic-clean-info "$untracked_info_repo" '信息 src/main/java/example/LocalProperties.java:1-5 - GENERIC_CLEAN_INFO_MARKER：
影响：该类是一个新增的 Java 类，没有任何可修复问题。
修复建议：无。
验证方式：无。')"
if ! grep -Fx '未发现阻塞问题' "$generic_clean_info_output" >/dev/null ||
   grep -F 'GENERIC_CLEAN_INFO_MARKER' "$generic_clean_info_output" >/dev/null; then
  printf 'FAIL generic-clean-info: explicit no-finding information was not normalized\n' >&2
  cat "$generic_clean_info_output" >&2
  filter_evidence_failures=$((filter_evidence_failures + 1))
fi

doc_sync_info_output="$(run_review doc-sync-info "$untracked_info_repo" '信息 doc/README.md:1-5 - DOC_SYNC_INFO_MARKER：文档更新与代码实现一致，无需额外修复。
影响：无。
修复建议：无。
验证方式：无。')"
if ! grep -Fx '未发现阻塞问题' "$doc_sync_info_output" >/dev/null ||
   grep -F 'DOC_SYNC_INFO_MARKER' "$doc_sync_info_output" >/dev/null; then
  printf 'FAIL doc-sync-info: documentation synchronization summary was not filtered\n' >&2
  cat "$doc_sync_info_output" >&2
  filter_evidence_failures=$((filter_evidence_failures + 1))
fi

path_safe_repo="$(new_repo path-safe)"
mkdir -p "$path_safe_repo/src/main/java/example"
cat >"$path_safe_repo/src/main/java/example/PathReader.java" <<'EOF'
package example;

import java.nio.file.Files;
import java.nio.file.Path;

final class PathReader {
    String read(Path root, String filename) throws Exception {
        Path canonicalRoot = root.toAbsolutePath().normalize();
        Path target = canonicalRoot.resolve(filename).normalize();
        if (!target.startsWith(canonicalRoot)) throw new IllegalArgumentException("path escapes root");
        return Files.readString(target);
    }
}
EOF
path_safe_output="$(run_review path-safe "$path_safe_repo" '信息 src/main/java/example/PathReader.java:8-10 - PATH_SAFE_BOUNDARY_MARKER：可能存在路径遍历风险，startsWith 检查可能被绕过。
影响：攻击者可能读取根目录之外的文件。
修复建议：使用 normalize 后的绝对路径进行更严格检查。
验证方式：测试 ../etc/passwd。')"
if ! grep -Fx '未发现阻塞问题' "$path_safe_output" >/dev/null ||
   grep -F 'PATH_SAFE_BOUNDARY_MARKER' "$path_safe_output" >/dev/null; then
  printf 'FAIL path-safe: visible normalize/startsWith boundary was over-reported\n' >&2
  cat "$path_safe_output" >&2
  filter_evidence_failures=$((filter_evidence_failures + 1))
fi

# Visible Lombok annotations supply generated members.  A missing-dependency
# guess without compiler/build evidence is not an actionable finding; keep
# explicit build failures and dependency-removal claims reportable.
lombok_repo="$(new_repo lombok-safe)"
mkdir -p "$lombok_repo/src/main/java/example"
cat >"$lombok_repo/src/main/java/example/PlatformFileInternalClientProperties.java" <<'EOF'
package example;

import lombok.Data;

@Data
final class PlatformFileInternalClientProperties {
    private String baseUrl;
}
EOF
git -C "$lombok_repo" add .
git -C "$lombok_repo" commit -qm base
printf '%s\n' '// unchanged Lombok contract' >>"$lombok_repo/src/main/java/example/PlatformFileInternalClientProperties.java"
lombok_output="$(run_review lombok-safe "$lombok_repo" '信息 src/main/java/example/PlatformFileInternalClientProperties.java:1-16 - LOMBOK_DEPENDENCY_MARKER：缺少构建依赖。

影响：`@Data` 注解依赖 Lombok，但当前差异中没有显式依赖声明或构建配置证据。

修复建议：在构建文件（例如 `pom.xml` 或 `build.gradle`）中添加 Lombok 依赖。

验证方式：构建项目并确认 `@Data` 注解被正确处理。')"
if ! grep -Fx '未发现阻塞问题' "$lombok_output" >/dev/null ||
   grep -F 'LOMBOK_DEPENDENCY_MARKER' "$lombok_output" >/dev/null; then
  printf 'FAIL lombok-safe: Lombok dependency speculation was not filtered\n' >&2
  cat "$lombok_output" >&2
  filter_evidence_failures=$((filter_evidence_failures + 1))
fi

# A presign provider's interface return and a bare delete call do not, by
# themselves, prove nullability or rollback requirements.  The deterministic
# lifecycle preflight must remain visible while these speculative information
# paragraphs are removed.
presigned_repo="$(new_repo presigned-speculation)"
mkdir -p "$presigned_repo/src"
cat >"$presigned_repo/src/UploadSessionService.java" <<'EOF'
import java.time.Duration;
import java.time.Instant;

final class UploadSessionService {
    private static final Duration TICKET_TTL = Duration.ofMinutes(15);
    private final Store store;
    private final Sessions sessions;

    UploadSessionService(Store store, Sessions sessions) {
        this.store = store;
        this.sessions = sessions;
    }

    UploadTicket issueTicket(long id, String objectKey) {
        return store.presignPut(objectKey, TICKET_TTL);
    }

    void acceptUpload(long id, UploadTicket ticket) {
        if (ticket.expiresAt().isAfter(Instant.now())) {
            store.put(ticket, ticket.objectKey());
        }
    }

    void cancel(long id, String objectKey) {
        store.delete(objectKey);
        sessions.markCancelled(id);
    }

    void complete(long id) { sessions.markCompleted(id); }

    void cleanupExpired() {
        for (Session session : sessions.findActiveExpired()) store.delete(session.objectKey());
    }

    interface Store {
        UploadTicket presignPut(String objectKey, Duration ttl);
        void put(UploadTicket ticket, String objectKey);
        void delete(String objectKey);
    }
    interface Sessions {
        void markCancelled(long id);
        void markCompleted(long id);
        Iterable<Session> findActiveExpired();
    }
    interface Session { String objectKey(); }
    record UploadTicket(String objectKey, Instant expiresAt) {}
}
EOF
presigned_output="$(run_review presigned-speculation "$presigned_repo" 'P1 src/UploadSessionService.java:14 - PRESIGN_LIFECYCLE_DUPLICATE_MARKER：issueTicket 生成的预签名票据在取消后可能继续写入对象存储。

影响：票据生命周期风险已在当前差异中体现。

修复建议：增加票据撤销。

验证方式：执行取消后上传回归。

信息 src/UploadSessionService.java:14 - PRESIGN_NULL_SPECULATION_MARKER：缺少对 issueTicket 返回值的 null 检查。

影响：如果 store.presignPut 返回 null，可能导致后续 NPE。

修复建议：添加 null 检查，或确保 store.presignPut 不返回 null。

验证方式：模拟 store.presignPut 返回 null，确认异常被正确处理。

信息 src/UploadSessionService.java:24 - DELETE_EXCEPTION_SPECULATION_MARKER：cancel 方法没有处理 store.delete 可能抛出的异常。

影响：如果 store.delete 失败，会话状态可能与存储状态不一致。

修复建议：添加异常处理，确保会话状态与存储状态一致。

验证方式：模拟 store.delete 失败，确认会话状态被正确回滚。')"
if ! grep -F 'PRESIGN_LIFECYCLE_DUPLICATE_MARKER' "$presigned_output" >/dev/null ||
   grep -F 'PRESIGN_NULL_SPECULATION_MARKER' "$presigned_output" >/dev/null ||
   grep -F 'DELETE_EXCEPTION_SPECULATION_MARKER' "$presigned_output" >/dev/null ||
   ! grep -F '取消后仍可重放有效的预签名上传票据' "$presigned_output" >/dev/null; then
  printf 'FAIL presigned-speculation: concrete model finding or preflight finding was missing\n' >&2
  cat "$presigned_output" >&2
  filter_evidence_failures=$((filter_evidence_failures + 1))
fi

if (( filter_evidence_failures > 0 )); then
  printf 'filter evidence regression failed: %s cases\n' "$filter_evidence_failures" >&2
  exit 1
fi
printf 'filter evidence regression passed: 22 cases\n'
