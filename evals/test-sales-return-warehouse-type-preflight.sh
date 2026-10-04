#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-sales-return-warehouse-type.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
repo="$fixture_root/repo"
safe_repo="$fixture_root/safe-repo"
fake_bin="$fixture_root/bin"
mkdir -p "$repo/src/main/java/com/bit/erp/application/salesreturn" "$fake_bin"

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name sales-return-warehouse-type-preflight

cat >"$repo/src/main/java/com/bit/erp/application/salesreturn/SalesReturnApplication.java" <<'EOF'
package com.bit.erp.application.salesreturn;

final class SalesReturnApplication {
    private static final String WAREHOUSE_TYPE_AFTER_SALE_GOOD = "AFTER_SALE_GOOD";
}
EOF
cat >"$repo/src/main/java/com/bit/erp/application/salesreturn/SalesReturnInspectionApplication.java" <<'EOF'
package com.bit.erp.application.salesreturn;

final class SalesReturnInspectionApplication {
    String warehouseType() {
        return "AFTER_SALE_GOOD";
    }
}
EOF
git -C "$repo" add .
git -C "$repo" commit -qm base

sed -i '' 's/"AFTER_SALE_GOOD"/"AFTER_SALES_GOOD"/' \
  "$repo/src/main/java/com/bit/erp/application/salesreturn/SalesReturnApplication.java"

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
  "$repo_root/bin/local-review.sh" --repo "$1"
}

marker='退货默认仓库类型字典 code'
output="$(run_review "$repo")"
count="$(printf '%s\n' "$output" | grep -cF "$marker" || true)"
[[ "$count" == 1 ]] || {
  echo "sales return warehouse-type preflight expected one finding, got $count" >&2
  printf '%s\n' "$output" >&2
  exit 1
}
for field in '影响：' '修复建议：' '验证方式：'; do
  printf '%s\n' "$output" | grep -F "$field" >/dev/null || {
    echo "sales return warehouse-type preflight omitted $field" >&2
    exit 1
  }
done

cp -R "$repo" "$safe_repo"
sed -i '' 's/"AFTER_SALES_GOOD"/"AFTER_SALE_GOOD"/' \
  "$safe_repo/src/main/java/com/bit/erp/application/salesreturn/SalesReturnApplication.java"
safe_output="$(run_review "$safe_repo")"
if printf '%s\n' "$safe_output" | grep -F "$marker" >/dev/null; then
  echo 'sales return warehouse-type preflight reported safe fixture' >&2
  printf '%s\n' "$safe_output" >&2
  exit 1
fi

echo 'sales return warehouse-type preflight regression passed'
