#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-finding-signature.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

cat >"$fixture_root/first.txt" <<'EOF'
P1 src/OrderService.java:12-14 -
影响：跨租户数据泄漏。方法 `load` 只使用 `orderId` 查询，忽略了 `tenantId` 参数。
修复建议：同时约束 `tenantId` 和 `orderId`。
验证方式：覆盖两个租户的同一资源 ID。
EOF
cat >"$fixture_root/second.txt" <<'EOF'
P1 src/OrderService.java:12-14 - 租户隔离违规
影响：跨租户数据泄漏。证据是 `repository.findById(orderId)` 缺少租户谓词。
修复建议：改为 `findByTenantIdAndId(tenantId, orderId)`。
验证方式：覆盖两个租户的同一资源 ID。
EOF

first_signature="$($repo_root/evals/finding-signature.sh "$fixture_root/first.txt")"
second_signature="$($repo_root/evals/finding-signature.sh "$fixture_root/second.txt")"
[[ "$first_signature" == "$second_signature" ]] || {
  printf 'FAIL semantic finding signature differs\nfirst=%s\nsecond=%s\n' "$first_signature" "$second_signature" >&2
  exit 1
}

cat >"$fixture_root/independent.txt" <<'EOF'
P1 src/JobMapper.xml:3 - SQL 注入
影响：MyBatis 原始替换 `${timeout}`。
修复建议：使用参数绑定。
验证方式：执行边界测试。

P1 src/JobMapper.xml:3 - 租户隔离
影响：跨租户权限绕过。
修复建议：增加 tenantId 条件。
验证方式：执行跨租户测试。
EOF
independent_signature="$($repo_root/evals/finding-signature.sh "$fixture_root/independent.txt")"
[[ "$(printf '%s\n' "$independent_signature" | wc -l | tr -d ' ')" == 2 ]] || {
  printf 'FAIL independent findings were collapsed\n%s\n' "$independent_signature" >&2
  exit 1
}

printf 'finding signature regression passed\n'
