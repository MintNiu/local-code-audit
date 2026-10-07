#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-report-quantity.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
repo="$fixture_root/repo"
fake_bin="$fixture_root/bin"
mkdir -p "$repo/src/main/java/com/example/reportquantity" "$repo/src/main/java/com/example/reportquantity/query" "$repo/sql" "$fake_bin"

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name report-quantity-preflight

cat >"$repo/README.md" <<'EOF'
已有数据库必须通过 sql/migration 版本化迁移升级，初始化快照不会修改既有表。
EOF
cat >"$repo/src/main/java/com/example/reportquantity/ReportQuantityApplication.java" <<'EOF'
final class ReportQuantityApplication {
    public Object baseline() { return null; }
}
EOF
cat >"$repo/src/main/java/com/example/reportquantity/ReportQuantityRepository.java" <<'EOF'
final class ReportQuantityRepository {
    Object baseline() { return null; }
}
EOF
cat >"$repo/src/main/java/com/example/reportquantity/ReportSalesController.java" <<'EOF'
final class ReportSalesController {
    Object baseline() { return null; }
}
EOF
cat >"$repo/src/main/java/com/example/reportquantity/query/ReportSalesQuery.java" <<'EOF'
final class ReportSalesQuery {}
EOF
cat >"$repo/sql/platform_erp.sql" <<'EOF'
CREATE TABLE IF NOT EXISTS `unrelated_table` (`id` BIGINT PRIMARY KEY);
EOF
git -C "$repo" add .
git -C "$repo" commit -qm base

cat >"$repo/src/main/java/com/example/reportquantity/ReportQuantityApplication.java" <<'EOF'
final class ReportQuantityApplication {
    public Page<ReportSalesVO> salesPage(ReportSalesQuery query) {
        var orders = repository.salesOrders(query, tenantId());
        var lines = repository.salesLines(tenantId(), orders.stream().map(Object::hashCode).toList(), null, null);
        for (var serial : repository.serialsByOrderLineIds(tenantId(), lines.stream().map(Object::hashCode).toList())) {
            serial.toString();
        }
        var records = new java.util.ArrayList<>(lines);
        records.sort(java.util.Comparator.comparing(Object::toString));
        return new Page<>(query.getPageNum(), query.getPageSize(), records.subList(0, Math.min(records.size(), query.getPageSize())));
    }

    public ReportQuantityVO voidOrder(Long id) {
        var order = repository.lockOrder(tenantId(), id);
        order.setOrderStatus(VOIDED);
        return order;
    }

    void validateSerials(Long serialId, Long relationId) {
        repository.countSaleSerial(tenantId(), serialId);
        repository.countReturnSerial(tenantId(), relationId);
    }

    Long tenantId() { return 1L; }
}
EOF
cat >"$repo/src/main/java/com/example/reportquantity/ReportQuantityRepository.java" <<'EOF'
final class ReportQuantityRepository {
    java.util.List<ReportQuantityOrder> salesOrders(ReportSalesQuery query, Long tenantId) {
        return orderMapper.selectList(query, tenantId);
    }

    java.util.List<ReportQuantityLine> salesLines(Long tenantId, java.util.List<Long> orderIds, Long skuId, String salesType) {
        return lineMapper.selectList(tenantId, orderIds);
    }

    java.util.List<ReportQuantitySerial> serialsByOrderLineIds(Long tenantId, java.util.List<Long> lineIds) {
        return serialMapper.selectList(tenantId, lineIds);
    }

    public long countSaleSerial(Long tenantId, Long serialId) {
        return serialMapper.selectCount(tenantId, serialId, "SALE");
    }

    public long countReturnSerial(Long tenantId, Long relationId) {
        return serialMapper.selectCount(tenantId, relationId, "RETURN");
    }
}
EOF
cat >"$repo/src/main/java/com/example/reportquantity/ReportSalesController.java" <<'EOF'
final class ReportSalesController {
    Object page(ReportSalesQuery query) {
        return application.salesPage(query);
    }
    @GetMapping("/report-sales")
    Object route(ReportSalesQuery query) { return page(query); }
}
EOF
cat >"$repo/src/main/java/com/example/reportquantity/query/ReportSalesQuery.java" <<'EOF'
final class ReportSalesQuery extends PageQuery {
    Integer pageNum;
    Integer pageSize;
}
EOF
cat >"$repo/sql/platform_erp.sql" <<'EOF'
CREATE TABLE IF NOT EXISTS `unrelated_table` (`id` BIGINT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS `erp_report_quantity_order` (`id` BIGINT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS `erp_report_quantity_order_line` (`id` BIGINT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS `erp_report_quantity_serial` (`id` BIGINT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS `erp_report_quantity_validation_error` (`id` BIGINT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS `erp_report_quantity_operation_log` (`id` BIGINT PRIMARY KEY);
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
  OLLAMA_REVIEW_NUM_CTX=65536 \
  OLLAMA_REVIEW_TOTAL_TIMEOUT_SECONDS=120 \
  "$repo_root/bin/local-review.sh" --repo "$1"
}

output="$(run_review "$repo")"
void_marker='报量单作废后，串码占用统计仍只按串码关系和 SALE/RETURN 事件计数'
migration_marker='报量/销量新增持久化表只出现在全量初始化 schema'
pagination_marker='销量分页先加载整租户报量/明细/串码结果到内存'
for marker in "$void_marker" "$migration_marker" "$pagination_marker"; do
  [[ "$(printf '%s\n' "$output" | grep -cF "$marker" || true)" == 1 ]] || {
    echo "report quantity preflight did not emit exactly one finding: $marker" >&2
    printf '%s\n' "$output" >&2
    exit 1
  }
done
for field in '影响：' '修复建议：' '验证方式：' '证据行：'; do
  printf '%s\n' "$output" | grep -F "$field" >/dev/null || {
    echo "report quantity preflight omitted $field" >&2
    exit 1
  }
done

safe_void="$fixture_root/safe-void"
cp -R "$repo" "$safe_void"
python3 - "$safe_void/src/main/java/com/example/reportquantity/ReportQuantityApplication.java" <<'PY'
from pathlib import Path
import sys
file = Path(sys.argv[1])
text = file.read_text()
text = text.replace('order.setOrderStatus(VOIDED);', 'repository.deleteSerialRelations(order.getId());\n        order.setOrderStatus(VOIDED);')
file.write_text(text)
PY
safe_output="$(run_review "$safe_void")"
if printf '%s\n' "$safe_output" | grep -F "$void_marker" >/dev/null; then
  echo 'report quantity void preflight reported cleanup-safe fixture' >&2
  exit 1
fi

safe_migration="$fixture_root/safe-migration"
cp -R "$repo" "$safe_migration"
mkdir -p "$safe_migration/sql/migration"
cat >"$safe_migration/sql/migration/V20261007__report_quantity.sql" <<'EOF'
CREATE TABLE IF NOT EXISTS `erp_report_quantity_order` (`id` BIGINT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS `erp_report_quantity_order_line` (`id` BIGINT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS `erp_report_quantity_serial` (`id` BIGINT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS `erp_report_quantity_validation_error` (`id` BIGINT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS `erp_report_quantity_operation_log` (`id` BIGINT PRIMARY KEY);
EOF
safe_output="$(run_review "$safe_migration")"
if printf '%s\n' "$safe_output" | grep -F "$migration_marker" >/dev/null; then
  echo 'report quantity migration preflight reported versioned migration fixture' >&2
  exit 1
fi

safe_pagination="$fixture_root/safe-pagination"
cp -R "$repo" "$safe_pagination"
python3 - "$safe_pagination/src/main/java/com/example/reportquantity/ReportQuantityRepository.java" <<'PY'
from pathlib import Path
import sys
file = Path(sys.argv[1])
text = file.read_text().replace('return orderMapper.selectList(query, tenantId);', 'return orderMapper.selectPage(query, tenantId);')
file.write_text(text)
PY
safe_output="$(run_review "$safe_pagination")"
if printf '%s\n' "$safe_output" | grep -F "$pagination_marker" >/dev/null; then
  echo 'report quantity pagination preflight reported database-paged fixture' >&2
  exit 1
fi

echo 'report quantity preflight regression passed'
