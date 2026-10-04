#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-sales-order-sample-warehouse.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
repo="$fixture_root/repo"
safe_repo="$fixture_root/safe-repo"
fake_bin="$fixture_root/bin"
context="$fixture_root/platform-system.sql"
mkdir -p "$repo/src/main/java/com/bit/erp/application/salesorder" "$fake_bin"

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name sales-order-sample-warehouse-preflight

cat >"$repo/src/main/java/com/bit/erp/application/salesorder/SalesOrderApplication.java" <<'EOF'
package com.bit.erp.application.salesorder;

final class SalesOrderApplication {
    private static final String WAREHOUSE_TYPE_SAMPLE = "OLD";

    String resolveWarehouseType() {
        return warehouse.getWarehouseType();
    }

    void failWhenMissing() {
        throw new IllegalStateException("无可用样机仓");
    }

    private final Warehouse warehouse = new Warehouse();
    private static final class Warehouse {
        String getWarehouseType() { return "样机"; }
    }
}
EOF
git -C "$repo" add .
git -C "$repo" commit -qm base

sed -i '' 's/WAREHOUSE_TYPE_SAMPLE = "OLD"/WAREHOUSE_TYPE_SAMPLE = "SAMPLE"/' \
  "$repo/src/main/java/com/bit/erp/application/salesorder/SalesOrderApplication.java"

cat >"$context" <<'EOF'
-- canonical platform-system dictionary seed
INSERT INTO sys_dict_data (dict_type, value, label, sort, status)
VALUES ('erp_warehouse_type', '样机', '样机', 3, 1);
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
  OLLAMA_REVIEW_MAX_DIFF_BYTES=12000 \
  OLLAMA_REVIEW_TOTAL_TIMEOUT_SECONDS=120 \
  "$repo_root/bin/local-review.sh" --repo "$1" --context "$context"
}

marker='样机订单默认仓逻辑使用 warehouseType=SAMPLE'
output="$(run_review "$repo")"
count="$(printf '%s\n' "$output" | grep -cF "$marker" || true)"
[[ "$count" == 1 ]] || {
  echo "sales order sample warehouse preflight expected one finding, got $count" >&2
  printf '%s\n' "$output" >&2
  exit 1
}
for field in '影响：' '修复建议：' '验证方式：'; do
  printf '%s\n' "$output" | grep -F "$field" >/dev/null || {
    echo "sales order sample warehouse preflight omitted $field" >&2
    exit 1
  }
done

cp -R "$repo" "$safe_repo"
sed -i '' 's/WAREHOUSE_TYPE_SAMPLE = "SAMPLE"/WAREHOUSE_TYPE_SAMPLE = "样机"/' \
  "$safe_repo/src/main/java/com/bit/erp/application/salesorder/SalesOrderApplication.java"
safe_output="$(run_review "$safe_repo")"
if printf '%s\n' "$safe_output" | grep -F "$marker" >/dev/null; then
  echo 'sales order sample warehouse preflight reported safe fixture' >&2
  printf '%s\n' "$safe_output" >&2
  exit 1
fi

echo 'sales order sample warehouse preflight regression passed'
