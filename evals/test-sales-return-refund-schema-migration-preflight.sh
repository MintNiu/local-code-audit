#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-sales-return-refund-schema.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
repo="$fixture_root/repo"
safe_repo="$fixture_root/safe-repo"
fake_bin="$fixture_root/bin"
mkdir -p "$repo/src/main/java/com/bit/erp/application/salesreturn" "$repo/sql" "$fake_bin"

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name sales-return-refund-schema-preflight

cat >"$repo/README.md" <<'EOF'
已有数据库必须通过 sql/migration 版本化迁移升级，初始化快照不会修改既有表。
EOF
cat >"$repo/src/main/java/com/bit/erp/application/salesreturn/SalesReturnRefundApplication.java" <<'EOF'
final class SalesReturnRefundApplication {
    void baseline() {}
}
EOF
cat >"$repo/sql/platform_erp.sql" <<'EOF'
CREATE TABLE IF NOT EXISTS `erp_sales_return_inspection` (
    `id` BIGINT PRIMARY KEY
);
EOF
git -C "$repo" add .
git -C "$repo" commit -qm base

cat >"$repo/src/main/java/com/bit/erp/application/salesreturn/SalesReturnRefundApplication.java" <<'EOF'
final class SalesReturnRefundApplication {
    public Object createDraft(Long inspectionId) {
        return refundRepository.save(new Object());
    }
}
EOF
cat >"$repo/sql/platform_erp.sql" <<'EOF'
CREATE TABLE IF NOT EXISTS `erp_sales_return_inspection` (
    `id` BIGINT PRIMARY KEY
);
CREATE TABLE IF NOT EXISTS `erp_sales_return_refund` (
    `id` BIGINT PRIMARY KEY,
    `refund_no` VARCHAR(64) NOT NULL,
    UNIQUE KEY `uk_sales_return_refund_no` (`refund_no`)
);
CREATE TABLE IF NOT EXISTS `erp_sales_return_refund_line` (
    `id` BIGINT PRIMARY KEY,
    `refund_id` BIGINT NOT NULL
);
EOF

cat >"$fake_bin/ollama" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"response":"未发现阻塞问题","done":true,"done_reason":"stop"}'
EOF
chmod +x "$fake_bin/ollama" "$fake_bin/curl"

run_review() {
  PATH="$fake_bin:$PATH" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  OLLAMA_REVIEW_TOTAL_TIMEOUT_SECONDS=120 \
  "$repo_root/bin/local-review.sh" --repo "$1"
}

output="$(run_review "$repo")"
marker='销售退货退款新增表只写入初始化 schema'
[[ "$(printf '%s\n' "$output" | grep -cF "$marker" || true)" == 1 ]] || {
  echo 'sales return refund schema migration preflight did not emit exactly one finding' >&2
  printf '%s\n' "$output" >&2
  exit 1
}
for field in '影响：' '修复建议：' '验证方式：' '证据行：'; do
  printf '%s\n' "$output" | grep -F "$field" >/dev/null || {
    echo "sales return refund schema migration preflight omitted $field" >&2
    exit 1
  }
done

cp -R "$repo" "$safe_repo"
mkdir -p "$safe_repo/sql/migration"
cat >"$safe_repo/sql/migration/V20261004__sales_return_refund.sql" <<'EOF'
CREATE TABLE IF NOT EXISTS `erp_sales_return_refund` (`id` BIGINT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS `erp_sales_return_refund_line` (`id` BIGINT PRIMARY KEY);
EOF
safe_output="$(run_review "$safe_repo")"
if printf '%s\n' "$safe_output" | grep -F "$marker" >/dev/null; then
  echo 'sales return refund schema migration preflight reported versioned migration fixture' >&2
  printf '%s\n' "$safe_output" >&2
  exit 1
fi

echo 'sales return refund schema migration preflight regression passed'
