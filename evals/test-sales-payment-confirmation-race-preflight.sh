#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-sales-payment-confirmation.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
repo="$fixture_root/repo"
safe_repo="$fixture_root/safe-repo"
fake_bin="$fixture_root/bin"
mkdir -p "$repo/src/main/java/com/bit/erp/application/salesorder" \
  "$repo/src/main/java/com/bit/erp/application/fund" "$repo/sql" "$fake_bin"

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name sales-payment-confirmation-preflight

cat >"$repo/src/main/java/com/bit/erp/application/salesorder/SalesOrderApplication.java" <<'EOF'
final class SalesOrderApplication {
    void baseline() {}
}
EOF
cat >"$repo/src/main/java/com/bit/erp/application/fund/SalesFundTransactionService.java" <<'EOF'
final class SalesFundTransactionService {
    void baseline() {}
}
EOF
cat >"$repo/sql/platform_erp.sql" <<'EOF'
CREATE TABLE erp_fund_freeze_record (source_order_no VARCHAR(64));
EOF
git -C "$repo" add .
git -C "$repo" commit -qm base

cat >"$repo/src/main/java/com/bit/erp/application/salesorder/SalesOrderApplication.java" <<'EOF'
final class SalesOrderApplication {
    public SalesOrderVO confirmPaymentVoucher(Long id, Long voucherId) {
        ErpSalesOrder entity = ensureExists(id);
        ErpSalesPaymentVoucher voucher = ensureVoucher(id, voucherId);
        rechargeAndFreezeSalesOrder(entity, voucher);
        voucher.setConfirmStatus("CONFIRMED");
        entity.setStatus("WAIT_FULFILLMENT");
        return detail(id);
    }

    public SalesOrderVO rejectPaymentVoucher(Long id, Long voucherId) {
        ErpSalesOrder entity = ensureExists(id);
        ErpSalesPaymentVoucher voucher = ensureVoucher(id, voucherId);
        voucher.setConfirmStatus("REJECTED");
        entity.setStatus("DRAFT");
        return detail(id);
    }

    private ErpSalesOrder ensureExists(Long id) { return null; }
    private ErpSalesPaymentVoucher ensureVoucher(Long id, Long voucherId) { return null; }
    private void rechargeAndFreezeSalesOrder(ErpSalesOrder order, ErpSalesPaymentVoucher voucher) {}
    private SalesOrderVO detail(Long id) { return null; }
}
EOF
cat >"$repo/src/main/java/com/bit/erp/application/fund/SalesFundTransactionService.java" <<'EOF'
final class SalesFundTransactionService {
    void rechargeAndFreezeSalesOrder() {
        if (fundFreezeRecordRepository.countActiveBySourceOrderNo(1L, "SO" ) > 0) return;
        fundAccountRepository.rechargeAndFreezeIfEnabled(1L);
        fundFreezeRecordRepository.save(new Object());
    }
    Object fundFreezeRecordRepository;
    Object fundAccountRepository;
}
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
marker='销售订单支付凭证确认/驳回使用非锁定订单与凭证读取'
[[ "$(printf '%s\n' "$output" | grep -cF "$marker" || true)" == 1 ]] || {
  echo 'sales payment confirmation race preflight did not emit exactly one finding' >&2
  printf '%s\n' "$output" >&2
  exit 1
}
for field in '影响：' '修复建议：' '验证方式：'; do
  printf '%s\n' "$output" | grep -F "$field" >/dev/null || {
    echo "sales payment confirmation race preflight omitted $field" >&2
    exit 1
  }
done

cp -R "$repo" "$safe_repo"
python3 - "$safe_repo/src/main/java/com/bit/erp/application/salesorder/SalesOrderApplication.java" "$safe_repo/src/main/java/com/bit/erp/application/fund/SalesFundTransactionService.java" <<'PY'
from pathlib import Path
import sys
app = Path(sys.argv[1])
fund = Path(sys.argv[2])
app.write_text('''final class SalesOrderApplication {\n    public SalesOrderVO confirmPaymentVoucher(Long id, Long voucherId) {\n        ErpSalesOrder entity = salesOrderRepository.findByIdForUpdate(id);\n        ErpSalesPaymentVoucher voucher = salesPaymentVoucherRepository.findByIdForUpdate(voucherId);\n        return detail(id);\n    }\n    public SalesOrderVO rejectPaymentVoucher(Long id, Long voucherId) {\n        ErpSalesOrder entity = salesOrderRepository.findByIdForUpdate(id);\n        ErpSalesPaymentVoucher voucher = salesPaymentVoucherRepository.findByIdForUpdate(voucherId);\n        return detail(id);\n    }\n    private SalesOrderVO detail(Long id) { return null; }\n}\n''')
fund.write_text('''final class SalesFundTransactionService {\n    void rechargeAndFreezeSalesOrder() {\n        fundFreezeRecordRepository.findBySourceOrderNoForUpdate();\n        fundAccountRepository.rechargeAndFreezeIfEnabled(1L);\n    }\n    Object fundFreezeRecordRepository;\n    Object fundAccountRepository;\n}\n''')
PY
safe_output="$(run_review "$safe_repo")"
if printf '%s\n' "$safe_output" | grep -F "$marker" >/dev/null; then
  echo 'sales payment confirmation race preflight reported locked fixture' >&2
  printf '%s\n' "$safe_output" >&2
  exit 1
fi

echo 'sales payment confirmation race preflight regression passed'
