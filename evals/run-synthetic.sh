#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runs="${SYNTHETIC_REVIEW_RUNS:-5}"
timeout_seconds="${OLLAMA_REVIEW_TIMEOUT_SECONDS:-180}"
model="${OLLAMA_REVIEW_MODEL:-devstral-small-2-review-tuned}"
require_stable_hash="${SYNTHETIC_REQUIRE_STABLE_HASH:-1}"
review_script="${SYNTHETIC_REVIEW_SCRIPT:-$repo_root/bin/local-review-local.sh}"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-synthetic.XXXXXX")"
output_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-synthetic-results.XXXXXX")"
trap 'rm -rf "$fixture_root" "$output_root"' EXIT

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
      -e 's#${OSS_ACCESS_KEY_ID}#AKID_EXAMPLE#' \
      -e 's#${OSS_ACCESS_KEY_SECRET}#SECRET_EXAMPLE#' \
      "$target_dir/application.yml"
  fi
}

run_review() {
  local name="$1"
  local expected_findings="$2"
  local output_dir="$output_root/$name"

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
      if grep -Eq '^[[:space:]]*P[0-3] [^[:space:]]+:[0-9]+(-[0-9]+)? -' "$output_file"; then
        echo "$name run $run reported a finding for the clean fixture: $output_file" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
    fi

    output_hash="$(shasum -a 256 "$output_file" | awk '{print $1}')"
    baseline_hash_file="$output_dir/baseline.sha256"
    if [[ "$run" -eq 1 ]]; then
      printf '%s\n' "$output_hash" >"$baseline_hash_file"
    elif [[ "$require_stable_hash" == "1" ]]; then
      baseline_hash="$(<"$baseline_hash_file")"
      if [[ "$output_hash" != "$baseline_hash" ]]; then
        echo "$name run $run output is not stable: expected sha256=$baseline_hash, got sha256=$output_hash" >&2
        sed -n '1,160p' "$output_file" >&2
        return 1
      fi
    fi

    printf '%s run=%s exit=%s elapsed=%ss sha256=%s\n' \
      "$name" "$run" "$exit_code" "$((end - start))" "$output_hash"
  done
}

run_review java-divide 2
run_review java-safe 0
run_review java-token-url url
run_review java-token-query query
run_review java-token-header 0
run_review java-tenant-leak tenant
run_review java-tenant-safe 0
run_review java-maintenance-safe 0
run_review java-migration-delete migration
run_review java-secret-config secret
run_review java-presigned-replay presigned

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

echo "synthetic evaluation passed: divide=$runs, security_url=$runs, security_query=$runs, tenant=$runs, clean=$((runs * 4)), migration=$runs, secret=$runs, presigned=$runs, truncation=explicit-failure"
