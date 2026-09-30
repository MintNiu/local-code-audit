#!/usr/bin/env bash
set -euo pipefail

# Exercise only the URL allowlist merge helper. Do not source the review
# entrypoint: its top-level setup may probe Ollama or start a real review.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-url-prefix-dedup.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
export TMPDIR="$fixture_root"
helper_source="$(awk '
  /^filter_url_prefix_whitelist_preflight_duplicates\(\) \{$/ { in_helper = 1 }
  in_helper { print }
  in_helper && /^\}$/ { found = 1; exit }
  END { if (!found) exit 1 }
' "$repo_root/bin/local-review.sh")"
eval "$helper_source"
declare -F filter_url_prefix_whitelist_preflight_duplicates >/dev/null

failures=0
checks=0
preflight='P1 src/main/java/example/UrlFetcher.java:11 - URL 白名单使用 startsWith 前缀匹配，无法证明目标 host 被严格限制，存在 SSRF 绕过风险。
影响：攻击者可构造允许前缀后追加其他主机、用户信息或恶意后缀的 URL，使服务端访问非预期外部地址、内网服务或云 metadata。
修复建议：先解析 URI/URL，再严格比较 scheme、host、port 和规范化后的目标；不要用字符串前缀代替主机白名单。
验证方式：使用允许域名后缀、userinfo、重定向和内网/metadata 地址构造测试，确认所有非精确 host 均在出站连接前被拒绝。'

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
  checks=$((checks + 1))
  filter_url_prefix_whitelist_preflight_duplicates "$findings_file" "$raw_file"
  if cmp -s "$expected_file" "$findings_file"; then
    printf 'PASS %s\n' "$name"
  else
    printf 'FAIL %s: expected removed duplicates and unchanged independent findings\n' "$name" >&2
    diff -u "$expected_file" "$findings_file" >&2 || true
    failures=$((failures + 1))
  fi
}

# Models often add the concrete consequence "请求凭据" while restating this
# deterministic SSRF root. That consequence must not make a same-root block
# look independent merely because the helper's keyword list contains 凭据.
exact_model='P1 src/main/java/example/UrlFetcher.java:11 - URL 白名单使用 startsWith 前缀匹配，无法证明目标 host 被严格限制，存在 SSRF 绕过风险。
影响：攻击者可构造允许前缀后追加其他主机、用户信息或恶意后缀的 URL，使服务端访问非预期外部地址、内网服务或云 metadata，请求凭据。
修复建议：先解析 URI/URL，再严格比较 scheme、host、port 和规范化后的目标；不要用字符串前缀代替主机白名单。
验证方式：使用允许域名后缀、userinfo、重定向和内网/metadata 地址构造测试，确认所有非精确 host 均在出站连接前被拒绝。'
run_case exact-duplicate "$preflight" "$exact_model" ''

run_case empty-title-duplicate "$preflight" \
  'P1 src/main/java/example/UrlFetcher.java:11-17 -
影响：攻击者可构造允许前缀后追加其他主机、用户信息或恶意后缀的 URL，使服务端访问非预期外部地址、内网服务或云 metadata。
修复建议：先解析 URI/URL，再严格比较 scheme、host、port 和规范化后的目标；不要用字符串前缀代替主机白名单。
验证方式：使用允许域名后缀、userinfo、重定向和内网/metadata 地址构造测试，确认所有非精确 host 均在出站连接前被拒绝。' ''

run_case range-duplicate "$preflight" \
  'P1 src/main/java/example/UrlFetcher.java:9-13 - URL 白名单使用 startsWith 前缀匹配，无法证明目标 host 被严格限制，存在 SSRF 绕过风险。' ''

run_case prefixed-path-duplicate "$preflight" \
  'P1 b/src/main/java/example/UrlFetcher.java:11 - URL 白名单使用 startsWith 前缀匹配，无法证明目标 host 被严格限制，存在 SSRF 绕过风险。' ''

other_file='P1 src/main/java/example/OtherFetcher.java:11 - URL 白名单使用 startsWith 前缀匹配，无法证明目标 host 被严格限制，存在 SSRF 绕过风险。'
run_case distinct-file "$preflight" "$other_file" "$other_file"

other_line='P1 src/main/java/example/UrlFetcher.java:21-24 - URL 白名单使用 startsWith 前缀匹配，无法证明目标 host 被严格限制，存在 SSRF 绕过风险。'
run_case distinct-line "$preflight" "$other_line" "$other_line"

independent_root='P1 src/main/java/example/UrlFetcher.java:11 - URL 白名单校验后的日志语句拼接用户参数，造成 SQL 注入。
影响：独立的数据库执行路径可以读取或修改记录。
修复建议：数据库语句使用绑定参数。'
run_case independent-root-same-line "$preflight" "$independent_root" "$independent_root"

if (( failures > 0 )); then
  printf 'URL prefix dedup regression: %s/%s cases failed\n' "$failures" "$checks" >&2
  exit 1
fi
printf 'URL prefix dedup regression: %s cases passed (no model calls)\n' "$checks"
