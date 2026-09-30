#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runs="${SYNTHETIC_REVIEW_RUNS:-5}"
timeout_seconds="${OLLAMA_REVIEW_TIMEOUT_SECONDS:-180}"
model="${OLLAMA_REVIEW_MODEL:-devstral-small-2-review-tuned}"
require_stable_hash="${SYNTHETIC_REQUIRE_STABLE_HASH:-1}"
keep_results="${SYNTHETIC_KEEP_RESULTS:-0}"
only_case="${SYNTHETIC_ONLY_CASE:-}"
review_script="${SYNTHETIC_REVIEW_SCRIPT:-$repo_root/bin/local-review-local.sh}"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-synthetic.XXXXXX")"
output_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-synthetic-results.XXXXXX")"
if [[ "$keep_results" == "1" ]]; then
  trap 'printf "synthetic results kept: %s\n" "$output_root" >&2; printf "synthetic fixtures kept: %s\n" "$fixture_root" >&2' EXIT
else
  trap 'rm -rf "$fixture_root" "$output_root"' EXIT
fi

if [[ ! "$runs" =~ ^[1-9][0-9]*$ ]]; then
  echo "SYNTHETIC_REVIEW_RUNS 必须是正整数。" >&2
  exit 2
fi

if [[ "$require_stable_hash" != "0" && "$require_stable_hash" != "1" ]]; then
  echo "SYNTHETIC_REQUIRE_STABLE_HASH 必须是 0 或 1。" >&2
  exit 2
fi

if [[ ! "$timeout_seconds" =~ ^[0-9]+$ ]] || (( timeout_seconds < 30 )); then
  echo "OLLAMA_REVIEW_TIMEOUT_SECONDS 必须是至少 30 秒的整数。" >&2
  exit 2
fi

# The model gate cannot prove that deterministic wrapper rules still run. Run
# the hermetic no-model preflight regression first so a broken known-pattern
# detector fails the same synthetic command instead of silently lowering recall.
if ! "$repo_root/evals/test-preflight.sh" >/dev/null; then
  echo "确定性预检回归失败；未发送模型请求。" >&2
  exit 1
fi

prepare_fixture() {
  local name="$1"
  local source_dir="$repo_root/evals/fixtures/$name"
  local target_dir="$fixture_root/$name"

  mkdir -p "$target_dir"
  cp -R "$source_dir/." "$target_dir/"
  git -C "$target_dir" init -q
  if [[ "$name" == "java-migration-delete" ]]; then
    git -C "$target_dir" add .
    git -C "$target_dir" commit -qm base
    rm -f "$target_dir/sql/migration/V20260725__upload.sql"
  elif [[ "$name" == "java-secret-config" ]]; then
    git -C "$target_dir" add .
    git -C "$target_dir" commit -qm base
    sed -i '' \
      -e 's#${OSS_ACCESS_KEY_ID}#AKID_EXAMPLE_9f8e7d6c5b4a3210#' \
      -e 's#${OSS_ACCESS_KEY_SECRET}#SECRET_EXAMPLE_9f8e7d6c5b4a3210#' \
      "$target_dir/application.yml"
  elif [[ "$name" == "java-sql-injection" ]]; then
    sed -i '' \
      -e 's|SET display_name = ${displayName}|SET display_name = #{displayName}|' \
      "$target_dir/src/main/resources/mappers/AccountMapper.xml"
    git -C "$target_dir" add .
    git -C "$target_dir" commit -qm base
    sed -i '' \
      -e 's|SET display_name = #{displayName}|SET display_name = ${displayName}|' \
      "$target_dir/src/main/resources/mappers/AccountMapper.xml"
  fi
}

run_review() {
  local name="$1"
  local expected_findings="$2"
  local output_dir="$output_root/$name"

  if [[ -n "$only_case" && "$only_case" != "$name" ]]; then
    return 0
  fi

  mkdir -p "$output_dir"
  prepare_fixture "$name"

  for run in $(seq 1 "$runs"); do
    local output_file="$output_dir/run-$run.txt"
    local start
    local end
    local exit_code=0

    start="$(date +%s)"
    if [[ "$expected_findings" == "presigned" ]]; then
      OLLAMA_REVIEW_MODEL="$model" \
      OLLAMA_REVIEW_TIMEOUT_SECONDS="$timeout_seconds" \
      OLLAMA_REVIEW_TOP_K="${PRESIGNED_REVIEW_TOP_K:-1}" \
      OLLAMA_REVIEW_TOP_P="${PRESIGNED_REVIEW_TOP_P:-1}" \
        "$review_script" --repo "$fixture_root/$name" >"$output_file" 2>&1 || exit_code=$?
    elif [[ "$name" == "java-sql-injection-safe" || "$name" == "java-xxe-safe" || "$name" == "java-idor-safe" || "$name" == "java-open-redirect-safe" || "$name" == "java-cors-safe" || "$name" == "java-weak-password-hash-safe" || "$name" == "java-fail-open-safe" || "$name" == "java-check-then-act-safe" || "$name" == "java-partial-side-effect-safe" || "$name" == "java-mybatis-raw-substitution-safe" || "$name" == "java-url-prefix-whitelist-safe" || "$name" == "java-authorization-annotation-safe" ]]; then
      # These new clean security boundaries need only the canonical marker.
      # Limit optional prose so a local model cannot spend the whole timeout
      # repeating non-actionable parser/query commentary; done=true and the
      # normal truncation gate still remain mandatory.
      OLLAMA_REVIEW_MODEL="$model" \
      OLLAMA_REVIEW_TIMEOUT_SECONDS="$timeout_seconds" \
      OLLAMA_REVIEW_NUM_PREDICT="${SYNTHETIC_SECURITY_CLEAN_NUM_PREDICT:-512}" \
      OLLAMA_REVIEW_TOP_K="${SYNTHETIC_SECURITY_CLEAN_TOP_K:-1}" \
      OLLAMA_REVIEW_TOP_P="${SYNTHETIC_SECURITY_CLEAN_TOP_P:-1}" \
        "$review_script" --repo "$fixture_root/$name" >"$output_file" 2>&1 || exit_code=$?
    else
      OLLAMA_REVIEW_MODEL="$model" \
      OLLAMA_REVIEW_TIMEOUT_SECONDS="$timeout_seconds" \
      "$review_script" --repo "$fixture_root/$name" >"$output_file" 2>&1 || exit_code=$?
    fi
    end="$(date +%s)"

    if [[ "$exit_code" -ne 0 ]]; then
      echo "$name run $run failed with exit $exit_code: $output_file" >&2
      sed -n '1,160p' "$output_file" >&2
      return 1
    fi

    if [[ "$expected_findings" == "2" ]]; then
      if ! grep -Eq 'Integer|null|空' "$output_file" || ! grep -Eq '除|ArithmeticException|除数' "$output_file"; then
        echo "$name run $run missed one of the expected risk families: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
      finding_count="$(grep -E '^[[:space:]]*P[0-3] [^[:space:]]+:[0-9]+(-[0-9]+)? -' "$output_file" | wc -l | tr -d ' ')"
      if [[ "$finding_count" -ne 2 ]] || grep -q '未发现阻塞问题' "$output_file"; then
        echo "$name run $run returned $finding_count findings instead of exactly 2: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
    elif [[ "$expected_findings" == "url" || "$expected_findings" == "query" ]]; then
      if [[ "$expected_findings" == "url" ]]; then
        if ! grep -Fq '凭据值被拼接到 URL 查询参数或路径中' "$output_file" || \
           grep -Fq '认证令牌从 URL 查询参数读取' "$output_file"; then
          echo "$name run $run did not return exactly the URL-concatenation risk family: $output_file" >&2
          sed -n '1,160p' "$output_file" >&2
          return 1
        fi
      else
        if ! grep -Fq '认证令牌从 URL 查询参数读取' "$output_file" || \
           grep -Fq '凭据值被拼接到 URL 查询参数或路径中' "$output_file"; then
          echo "$name run $run did not return exactly the query-token risk family: $output_file" >&2
          sed -n '1,160p' "$output_file" >&2
          return 1
        fi
      fi
      finding_count="$(grep -E '^[[:space:]]*P[0-3] [^[:space:]]+:[0-9]+(-[0-9]+)? -' "$output_file" | wc -l | tr -d ' ')"
      if [[ "$finding_count" -ne 1 ]] || grep -q '未发现阻塞问题' "$output_file"; then
        echo "$name run $run returned $finding_count findings instead of exactly 1: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
    elif [[ "$expected_findings" == "tenant" ]]; then
      if ! grep -Eiq 'tenant|租户|跨租户|tenantId' "$output_file"; then
        echo "$name run $run missed the expected tenant-isolation risk: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
      finding_count="$(grep -E '^[[:space:]]*P[0-3] [^[:space:]]+:[0-9]+(-[0-9]+)? -' "$output_file" | wc -l | tr -d ' ')"
      if [[ "$finding_count" -ne 1 ]] || grep -q '未发现阻塞问题' "$output_file"; then
        echo "$name run $run returned $finding_count findings instead of exactly 1: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
    elif [[ "$expected_findings" == "ssrf" ]]; then
      if ! grep -Eiq 'SSRF|服务端请求伪造|不可信 URL|内网|metadata' "$output_file"; then
        echo "$name run $run missed the expected SSRF risk: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
      finding_count="$(grep -E '^[[:space:]]*P[01] [^[:space:]]+:[0-9]+(-[0-9]+)? -' "$output_file" | wc -l | tr -d ' ')"
      if [[ "$finding_count" -ne 1 ]] || grep -q '未发现阻塞问题' "$output_file"; then
        echo "$name run $run returned $finding_count findings instead of exactly 1: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
    elif [[ "$expected_findings" == "path" ]]; then
      if ! grep -Eiq '路径遍历|目录逃逸|不可信文件名|根目录边界' "$output_file"; then
        echo "$name run $run missed the expected path-traversal risk: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
      finding_count="$(grep -E '^[[:space:]]*P[01] [^[:space:]]+:[0-9]+(-[0-9]+)? -' "$output_file" | wc -l | tr -d ' ')"
      if [[ "$finding_count" -ne 1 ]] || grep -q '未发现阻塞问题' "$output_file"; then
        echo "$name run $run returned $finding_count findings instead of exactly 1: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
    elif [[ "$expected_findings" == "command" ]]; then
      if ! grep -Eiq '命令注入|command injection|shell injection|不可信命令|命令执行' "$output_file"; then
        echo "$name run $run missed the expected command-injection risk: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
    elif [[ "$expected_findings" == "deserialization" ]]; then
      if ! grep -Eiq '反序列化|deserialization|ObjectInputStream|readObject|不可信对象' "$output_file"; then
        echo "$name run $run missed the expected unsafe-deserialization risk: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
      finding_count="$(grep -E '^[[:space:]]*P[01] [^[:space:]]+:[0-9]+(-[0-9]+)? -' "$output_file" | wc -l | tr -d ' ')"
      if [[ "$finding_count" -ne 1 ]] || grep -q '未发现阻塞问题' "$output_file"; then
        echo "$name run $run returned $finding_count findings instead of exactly 1: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
    elif [[ "$expected_findings" == "sql" ]]; then
      if ! grep -Eiq 'SQL[[:space:]]*注入|MyBatis|原始替换|\$\{[^}]+\}' "$output_file"; then
        echo "$name run $run missed the expected SQL-injection risk: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
      finding_count="$(grep -E '^[[:space:]]*P[01] [^[:space:]]+:[0-9]+(-[0-9]+)? -' "$output_file" | wc -l | tr -d ' ')"
      if [[ "$finding_count" -ne 1 ]] || grep -q '未发现阻塞问题' "$output_file"; then
        echo "$name run $run returned $finding_count findings instead of exactly 1: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
    elif [[ "$expected_findings" == "xxe" ]]; then
      if ! grep -Eiq 'XXE|XML[[:space:]]*外部实体|外部实体|实体解析|DOCTYPE|external-general-entities' "$output_file"; then
        echo "$name run $run missed the expected XXE risk: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
      finding_count="$(grep -E '^[[:space:]]*P[01] [^[:space:]]+:[0-9]+(-[0-9]+)? -' "$output_file" | wc -l | tr -d ' ')"
      if [[ "$finding_count" -lt 1 ]] || grep -q '未发现阻塞问题' "$output_file"; then
        echo "$name run $run did not return a P0/P1 XXE finding: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
    elif [[ "$expected_findings" == "idor" ]]; then
      if ! grep -Eiq 'IDOR|对象级|越权|授权|权限|跨租户|未授权' "$output_file"; then
        echo "$name run $run missed the expected object-authorization risk: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
      finding_count="$(grep -E '^[[:space:]]*P[01] [^[:space:]]+:[0-9]+(-[0-9]+)? -' "$output_file" | wc -l | tr -d ' ')"
      if [[ "$finding_count" -lt 1 ]] || grep -q '未发现阻塞问题' "$output_file"; then
        echo "$name run $run did not return a P0/P1 object-authorization finding: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
    elif [[ "$expected_findings" == "redirect" ]]; then
      if ! grep -Eiq '开放重定向|open redirect|任意跳转|不可信.*重定向|redirect' "$output_file"; then
        echo "$name run $run missed the expected open-redirect risk: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
      finding_count="$(grep -E '^[[:space:]]*P[01] [^[:space:]]+:[0-9]+(-[0-9]+)? -' "$output_file" | wc -l | tr -d ' ')"
      if [[ "$finding_count" -lt 1 ]] || grep -q '未发现阻塞问题' "$output_file"; then
        echo "$name run $run did not return a P0/P1 open-redirect finding: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
    elif [[ "$expected_findings" == "cors" ]]; then
      if ! grep -Eiq 'CORS|跨域|allowedOrigin|allowCredentials|任意来源|Origin' "$output_file"; then
        echo "$name run $run missed the expected CORS risk: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
      finding_count="$(grep -E '^[[:space:]]*P[01] [^[:space:]]+:[0-9]+(-[0-9]+)? -' "$output_file" | wc -l | tr -d ' ')"
      if [[ "$finding_count" -lt 1 ]] || grep -q '未发现阻塞问题' "$output_file"; then
        echo "$name run $run did not return a P0/P1 CORS finding: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
    elif [[ "$expected_findings" == "password-hash" ]]; then
      if ! grep -Eiq 'MD5|SHA-?1|弱哈希|密码.*哈希|password.*hash|bcrypt|PBKDF2|Argon2' "$output_file"; then
        echo "$name run $run missed the expected weak-password-hash risk: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
      finding_count="$(grep -E '^[[:space:]]*P[01] [^[:space:]]+:[0-9]+(-[0-9]+)? -' "$output_file" | wc -l | tr -d ' ')"
      if [[ "$finding_count" -lt 1 ]] || grep -q '未发现阻塞问题' "$output_file"; then
        echo "$name run $run did not return a P0/P1 weak-password-hash finding: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
    elif [[ "$expected_findings" == "fail-open" ]]; then
      if ! grep -Eiq 'fail.?open|放行|默认允许|异常.*(放过|通过)|授权.*异常|权限.*异常|catch.*true|错误.*允许' "$output_file"; then
        echo "$name run $run missed the expected fail-open authorization risk: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
      finding_count="$(grep -E '^[[:space:]]*P[01] [^[:space:]]+:[0-9]+(-[0-9]+)? -' "$output_file" | wc -l | tr -d ' ')"
      if [[ "$finding_count" -lt 1 ]] || grep -q '未发现阻塞问题' "$output_file"; then
        echo "$name run $run did not return a P0/P1 fail-open finding: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
    elif [[ "$expected_findings" == "race" ]]; then
      if ! grep -Eiq '竞态|并发|check.?then.?act|原子|线程安全|共享状态|AtomicBoolean|compareAndSet|claimed' "$output_file"; then
        echo "$name run $run missed the expected check-then-act concurrency risk: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
      finding_count="$(grep -E '^[[:space:]]*P[01] [^[:space:]]+:[0-9]+(-[0-9]+)? -' "$output_file" | wc -l | tr -d ' ')"
      if [[ "$finding_count" -lt 1 ]] || grep -q '未发现阻塞问题' "$output_file"; then
        echo "$name run $run did not return a P0/P1 race finding: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
    elif [[ "$expected_findings" == "partial" ]]; then
      if ! grep -Eiq '事务|transaction|外部副作用|支付|部分成功|回滚|一致性|outbox|幂等|数据库.*外部' "$output_file"; then
        echo "$name run $run missed the expected partial-side-effect risk: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
      finding_count="$(grep -E '^[[:space:]]*P[01] [^[:space:]]+:[0-9]+(-[0-9]+)? -' "$output_file" | wc -l | tr -d ' ')"
      if [[ "$finding_count" -lt 1 ]] || grep -q '未发现阻塞问题' "$output_file"; then
        echo "$name run $run did not return a P0/P1 partial-side-effect finding: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
    elif [[ "$expected_findings" == "mybatis" ]]; then
      if ! grep -Eiq 'MyBatis|原始替换|SQL[[:space:]]*注入|\$\{[^}]+\}' "$output_file"; then
        echo "$name run $run missed the expected MyBatis raw-substitution risk: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
      finding_count="$(grep -E '^[[:space:]]*P[01] [^[:space:]]+:[0-9]+(-[0-9]+)? -' "$output_file" | wc -l | tr -d ' ')"
      if [[ "$finding_count" -ne 2 ]] || grep -q '未发现阻塞问题' "$output_file"; then
        echo "$name run $run returned $finding_count MyBatis findings instead of exactly 2: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
    elif [[ "$expected_findings" == "url-prefix" ]]; then
      if ! grep -Eiq 'startsWith|前缀匹配|SSRF|服务端请求伪造|白名单' "$output_file"; then
        echo "$name run $run missed the expected URL-prefix allowlist risk: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
      finding_count="$(grep -E '^[[:space:]]*P[01] [^[:space:]]+:[0-9]+(-[0-9]+)? -' "$output_file" | wc -l | tr -d ' ')"
      if [[ "$finding_count" -ne 1 ]] || grep -q '未发现阻塞问题' "$output_file"; then
        echo "$name run $run returned $finding_count URL-prefix findings instead of exactly 1: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
    elif [[ "$expected_findings" == "auth-annotation" ]]; then
      if ! grep -Eiq '权限注解|授权校验|PreAuthorize|RequiresPermissions|端点.*权限|未授权' "$output_file"; then
        echo "$name run $run missed the expected authorization-annotation risk: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
      finding_count="$(grep -E '^[[:space:]]*P[01] [^[:space:]]+:[0-9]+(-[0-9]+)? -' "$output_file" | wc -l | tr -d ' ')"
      if [[ "$finding_count" -ne 1 ]] || grep -q '未发现阻塞问题' "$output_file"; then
        echo "$name run $run returned $finding_count authorization-annotation findings instead of exactly 1: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
    elif [[ "$expected_findings" == "migration" ]]; then
      if ! grep -Eiq 'migration|迁移|已有库|升级路径|数据库' "$output_file"; then
        echo "$name run $run missed the expected migration-upgrade risk: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
    elif [[ "$expected_findings" == "secret" ]]; then
      if ! grep -Eiq 'secret|credential|凭据|密钥|AccessKey|Access Key|硬编码|字面量' "$output_file"; then
        echo "$name run $run missed the expected literal-credential risk: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
      finding_count="$(grep -E '^[[:space:]]*P[0-3] [^[:space:]]+:[0-9]+(-[0-9]+)? -' "$output_file" | wc -l | tr -d ' ')"
      if [[ "$finding_count" -lt 1 ]] || grep -q '未发现阻塞问题' "$output_file"; then
        echo "$name run $run did not return a credential finding: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
    elif [[ "$expected_findings" == "presigned" ]]; then
      if ! grep -Eiq 'presign|预签名|ticket|票据|replay|重放|孤儿|竞态' "$output_file"; then
        echo "$name run $run missed the expected presigned-ticket risk: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
      finding_count="$(grep -E '^[[:space:]]*P[01] [^[:space:]]+:[0-9]+(-[0-9]+)? -' "$output_file" | wc -l | tr -d ' ')"
      if [[ "$finding_count" -lt 1 ]] || grep -q '未发现阻塞问题' "$output_file"; then
        echo "$name run $run did not return a P0/P1 presigned-ticket finding: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
    else
      if ! grep -q '未发现阻塞问题' "$output_file"; then
        echo "$name run $run did not return the clean marker: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
      if grep -Eq '^[[:space:]]*(P[0-3]|信息)([[:space:]:：]+)' "$output_file"; then
        echo "$name run $run reported a finding or information block for the clean fixture: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
    fi

    # Stability is about the review result, not transport diagnostics or
    # incidental blank-line formatting.  A timed-out model request may still
    # return the same complete deterministic preflight finding; hashing the
    # raw stderr would turn that semantically stable result into a false
    # nondeterminism failure.  Keep all finding/body lines and the clean marker
    # while excluding only known wrapper diagnostics.
    stable_output_hash="$({
      sed -E \
        -e '/^(curl:|本地代码审查失败|本地代码审查未完成|本地代码审查：|请提高 OLLAMA|以下是截断|确定性预检回归失败)/d' \
        -e '/^[[:space:]]*$/d' \
        "$output_file"
    } | shasum -a 256 | awk '{print $1}')"
    baseline_hash_file="$output_dir/baseline.sha256"
    if [[ "$run" -eq 1 ]]; then
      printf '%s\n' "$stable_output_hash" >"$baseline_hash_file"
    elif [[ "$require_stable_hash" == "1" ]]; then
      baseline_hash="$(<"$baseline_hash_file")"
      if [[ "$stable_output_hash" != "$baseline_hash" ]]; then
        echo "$name run $run output is not stable: expected sha256=$baseline_hash, got sha256=$stable_output_hash" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
    fi

    printf '%s run=%s exit=%s elapsed=%ss sha256=%s\n' \
      "$name" "$run" "$exit_code" "$((end - start))" "$stable_output_hash"
  done
}

run_review java-divide 2
run_review java-safe 0
run_review java-token-url url
run_review java-token-query query
run_review java-token-header 0
run_review java-tenant-leak tenant
run_review java-tenant-safe 0
run_review java-ssrf ssrf
run_review java-ssrf-safe 0
run_review java-path-traversal path
run_review java-path-safe 0
run_review java-command-injection command
run_review java-command-safe 0
run_review java-deserialization deserialization
run_review java-deserialization-safe 0
run_review java-sql-injection sql
run_review java-sql-injection-safe 0
run_review java-xxe xxe
run_review java-xxe-safe 0
run_review java-idor idor
run_review java-idor-safe 0
run_review java-open-redirect redirect
run_review java-open-redirect-safe 0
run_review java-cors cors
run_review java-cors-safe 0
run_review java-weak-password-hash password-hash
run_review java-weak-password-hash-safe 0
run_review java-fail-open fail-open
run_review java-fail-open-safe 0
run_review java-check-then-act race
run_review java-check-then-act-safe 0
run_review java-partial-side-effect partial
run_review java-partial-side-effect-safe 0
run_review java-mybatis-raw-substitution mybatis
run_review java-mybatis-raw-substitution-safe 0
run_review java-url-prefix-whitelist url-prefix
run_review java-url-prefix-whitelist-safe 0
run_review java-authorization-annotation auth-annotation
run_review java-authorization-annotation-safe 0
run_review java-maintenance-safe 0
run_review java-lombok-properties-safe 0
run_review java-generated-column-safe 0
run_review java-migration-delete migration
run_review java-secret-config secret
run_review java-presigned-replay presigned

if [[ -n "$only_case" ]]; then
  printf 'synthetic single-case evaluation passed: case=%s, runs=%s\n' "$only_case" "$runs"
  exit 0
fi

truncation_output="$output_root/truncation.txt"
truncation_exit=0
OLLAMA_REVIEW_MODEL="$model" \
OLLAMA_REVIEW_TIMEOUT_SECONDS="$timeout_seconds" \
OLLAMA_REVIEW_NUM_PREDICT=1 \
  "$review_script" --repo "$fixture_root/java-divide" >"$truncation_output" 2>&1 || truncation_exit=$?

if [[ "$truncation_exit" -eq 0 ]] || ! grep -q '截断' "$truncation_output"; then
  echo "截断故障路径未按预期失败：$truncation_output" >&2
  sed -n '1,160p' "$truncation_output" >&2
  exit 1
fi

echo "synthetic evaluation passed: positives=$((runs * 23)), divide=$runs, security_url=$runs, security_query=$runs, tenant=$runs, security_ssrf=$runs, path_traversal=$runs, command_injection=$runs, unsafe_deserialization=$runs, sql_injection=$runs, xxe=$runs, idor=$runs, open_redirect=$runs, cors=$runs, weak_password_hash=$runs, fail_open=$runs, check_then_act=$runs, partial_side_effect=$runs, mybatis_raw_substitution=$runs, url_prefix_whitelist=$runs, authorization_annotation=$runs, clean=$((runs * 22)), migration=$runs, secret=$runs, presigned=$runs, truncation=explicit-failure"
