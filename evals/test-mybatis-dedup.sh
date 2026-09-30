#!/usr/bin/env bash
set -euo pipefail

# Exercise only the MyBatis merge helper. This is a hermetic regression: it
# does not source the review entrypoint or call Ollama.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-mybatis-dedup.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
export TMPDIR="$fixture_root"
helper_source="$(awk '
  /^filter_mybatis_raw_substitution_preflight_duplicates\(\) \{$/ { in_helper = 1 }
  in_helper { print }
  in_helper && /^\}$/ { found = 1; exit }
  END { if (!found) exit 1 }
' "$repo_root/bin/local-review.sh")"
eval "$helper_source"
declare -F filter_mybatis_raw_substitution_preflight_duplicates >/dev/null

preflight='P1 src/main/resources/JobMapper.xml:3 - MyBatis Mapper 将表达式 `${executorTimeout}` 直接拼入 SQL 标量赋值，存在 SQL 注入风险。
影响：攻击者可控制 SQL 片段或改变更新条件。
修复建议：标量值使用 `#{executorTimeout}` 参数绑定。
验证方式：使用引号、注释和边界值测试确认无法改变 SQL 结构。'

run_case() {
  local name="$1" raw="$2" model="$3" expected="$4"
  local raw_file="$fixture_root/$name.preflight"
  local findings_file="$fixture_root/$name.findings"
  local expected_file="$fixture_root/$name.expected"
  printf '%s\n' "$raw" >"$raw_file"
  printf '%s\n' "$model" >"$findings_file"
  if [[ -n "$expected" ]]; then
    printf '%s\n' "$expected" >"$expected_file"
  else
    : >"$expected_file"
  fi
  filter_mybatis_raw_substitution_preflight_duplicates "$findings_file" "$raw_file"
  if cmp -s "$expected_file" "$findings_file"; then
    printf 'PASS %s\n' "$name"
  else
    printf 'FAIL %s\n' "$name" >&2
    diff -u "$expected_file" "$findings_file" >&2 || true
    return 1
  fi
}

same_root='P1 src/main/resources/JobMapper.xml:3 - 模型复述 MyBatis `${executorTimeout}` 原始替换导致 SQL 注入。
影响：攻击者可能改变 SQL 结构。
修复建议：使用参数绑定。
验证方式：执行注入边界测试。'
run_case same-file-same-line "$preflight" "$same_root" ''

different_file='P1 src/main/resources/OtherMapper.xml:3 - MyBatis `${name}` 原始替换导致 SQL 注入。
影响：攻击者可改变查询结构。
修复建议：使用参数绑定。
验证方式：执行注入测试。'
run_case different-file "$preflight" "$different_file" "$different_file"

different_line='P1 src/main/resources/JobMapper.xml:9 - MyBatis `${name}` 原始替换导致 SQL 注入。
影响：攻击者可改变查询结构。
修复建议：使用参数绑定。
验证方式：执行注入测试。'
run_case different-line "$preflight" "$different_line" "$different_line"

independent_root='P1 src/main/resources/JobMapper.xml:3 - MyBatis 查询同时遗漏租户条件，导致跨租户越权。
影响：用户可读取其他租户数据。
修复建议：加入 tenant_id 约束。
验证方式：使用两个租户的同一 ID 验证隔离。'
run_case independent-root "$preflight" "$independent_root" "$independent_root"

raw_other_file='P1 src/main/resources/FirstMapper.xml:3 - MyBatis Mapper 将表达式 `${first}` 直接拼入 SQL 标量赋值，存在 SQL 注入风险.'
model_without_matching_raw='P1 src/main/resources/OtherMapper.xml:3 - MyBatis 查询使用字符串拼接，存在 SQL 注入风险。
影响：攻击者可改变 SQL 结构。
修复建议：使用参数绑定。
验证方式：执行注入测试。'
run_case no-global-cross-file-drop "$raw_other_file" "$model_without_matching_raw" "$model_without_matching_raw"

printf 'MyBatis dedup regression: 5 cases passed (no model calls)\n'
