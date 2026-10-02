#!/usr/bin/env bash
set -euo pipefail

# The user-visible review contract keeps concrete model findings. Deterministic
# preflight findings are additive and carry an explicit source marker; they do
# not replace, filter, or semantically deduplicate the model response.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-output-visibility.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
export TMPDIR="$fixture_root"

extract_helper() {
  local helper="$1"
  awk -v helper="$helper" '
    $0 == helper "() {" { in_helper = 1 }
    in_helper { print }
    in_helper && /^}$/ { found = 1; exit }
    END { if (!found) exit 1 }
  ' "$repo_root/bin/local-review.sh"
}

eval "$(extract_helper sort_findings_by_severity)"
eval "$(extract_helper annotate_preflight_blocks)"
eval "$(extract_helper merge_preflight_findings)"
eval "$(extract_helper dedup_exact_findings)"

model_file="$fixture_root/model.txt"
preflight_file="$fixture_root/preflight.txt"
deterministic_file="$fixture_root/lock.txt"
output_file="$fixture_root/output.txt"
kind_file="$fixture_root/kind.txt"

cat >"$model_file" <<'EOF'
P1 src/main/java/example/Example.java:10 - MODEL_UNIQUE_MARKER：模型发现了一个与预检不同的并发根因。
影响：该独立路径可能导致状态竞争。
修复建议：使用原子状态转换并补充并发测试。
验证方式：并发执行相同请求并检查最终状态。
EOF
cat >"$preflight_file" <<'EOF'
P1 src/main/java/example/Example.java:12 - PREFLIGHT_UNIQUE_MARKER：代码证据显示另一处输入未经过边界校验。
影响：异常输入可能触发错误处理路径。
修复建议：增加显式边界校验。
验证方式：覆盖空值、边界值和非法值测试。
EOF
: >"$deterministic_file"
printf 'findings\n' >"$kind_file"
cp "$model_file" "$output_file"

merge_preflight_findings "$output_file" "$kind_file" "$preflight_file" "$deterministic_file"

grep -F 'MODEL_UNIQUE_MARKER' "$output_file" >/dev/null || {
  echo 'model finding was hidden' >&2
  cat "$output_file" >&2
  exit 1
}
grep -F 'PREFLIGHT_UNIQUE_MARKER' "$output_file" >/dev/null || {
  echo 'preflight finding was not appended' >&2
  cat "$output_file" >&2
  exit 1
}
grep -F '来源：确定性预检（代码证据，非模型原文）' "$output_file" >/dev/null || {
  echo 'preflight source marker was missing' >&2
  cat "$output_file" >&2
  exit 1
}
[[ "$(cat "$kind_file")" == findings ]] || {
  echo 'visible findings were not marked as findings' >&2
  exit 1
}

# A model block and a code-proven block can share the same location and risk
# family while still carrying different evidence. The final shard dedup must
# never hide either one under the all-findings contract.
same_location_file="$fixture_root/same-location.txt"
cat >"$same_location_file" <<'EOF'
P1 src/main/java/example/Example.java:10 - MODEL_SAME_LOCATION：模型发现认证令牌暴露，且还存在独立的租户边界风险。
影响：凭据和租户数据可能被泄露。
修复建议：脱敏令牌并校验当前租户。
验证方式：执行跨租户和凭据暴露回归。

P1 src/main/java/example/Example.java:10 - PREFLIGHT_SAME_LOCATION：代码证据确认认证令牌从 URL 查询参数读取。
来源：确定性预检（代码证据，非模型原文）
影响：令牌可能进入访问日志。
修复建议：改用受保护的请求头。
验证方式：检查代理日志。
EOF
same_location_output="$(dedup_exact_findings <"$same_location_file")"
grep -F 'MODEL_SAME_LOCATION' <<<"$same_location_output" >/dev/null || {
  echo 'same-location model finding was hidden by dedup' >&2
  exit 1
}
grep -F 'PREFLIGHT_SAME_LOCATION' <<<"$same_location_output" >/dev/null || {
  echo 'same-location preflight finding was hidden by dedup' >&2
  exit 1
}

printf 'output visibility regression passed\n'
