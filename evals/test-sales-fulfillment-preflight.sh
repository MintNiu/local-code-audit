#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-sales-fulfillment.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
repo="$fixture_root/repo"
fake_bin="$fixture_root/bin"
mkdir -p "$repo/src/main/java/com/example/sales" "$fake_bin"

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name sales-fulfillment-preflight

cat >"$repo/src/main/java/com/example/sales/SalesFulfillmentApplication.java" <<'EOF'
final class SalesFulfillmentApplication {
    public void dispatch(Long orderId, java.util.List<DispatchLine> input) {
        var order = salesOrderRepository.findById(orderId);
        var lines = salesOrderRepository.listLines(orderId);
        var normalized = normalizeDispatchLines(input);
        for (DispatchLine dispatchLine : normalized) {
            inventoryService.increaseLineDispatched(dispatchLine);
        }
        updateOrderDispatchStatus(order);
    }

    private java.util.List<DispatchLine> normalizeDispatchLines(java.util.List<DispatchLine> input) {
        java.util.List<DispatchLine> result = new java.util.ArrayList<>();
        for (DispatchLine line : input) {
            result.add(line);
        }
        return result;
    }

    private void updateOrderDispatchStatus(SalesOrder order) {
        var currentLines = salesOrderRepository.listLines(order.getId());
        order.setDispatchStatus(calculateStatus(currentLines));
        salesOrderRepository.update(order);
    }

    Object calculateStatus(Object lines) { return lines; }
    SalesOrderRepository salesOrderRepository;
    InventoryService inventoryService;
}
EOF
cat >"$repo/src/main/java/com/example/sales/SalesOrderRepository.java" <<'EOF'
final class SalesOrderRepository {
    Object findById(Long orderId) { return orderId; }
    java.util.List<Object> listLines(Long orderId) { return java.util.List.of(); }
    void update(Object order) {}
}
EOF
cat >"$repo/src/main/java/com/example/sales/DispatchLine.java" <<'EOF'
final class DispatchLine {}
EOF
cat >"$repo/src/main/java/com/example/sales/SalesOrder.java" <<'EOF'
final class SalesOrder {
    Long getId() { return 1L; }
    void setDispatchStatus(Object status) {}
}
EOF
cat >"$repo/src/main/java/com/example/sales/InventoryService.java" <<'EOF'
final class InventoryService {
    void increaseLineDispatched(DispatchLine line) {}
}
EOF
git -C "$repo" add .
git -C "$repo" commit -qm base
# Keep the risky implementation in the post-base working tree so the review
# runner sees the two changed Java paths while the fixture remains self-contained.
cat >>"$repo/src/main/java/com/example/sales/SalesFulfillmentApplication.java" <<'EOF'
    Object changedDispatchMarker(Long orderId) {
        return normalizeDispatchLines(java.util.List.of());
    }
EOF
cat >>"$repo/src/main/java/com/example/sales/SalesOrderRepository.java" <<'EOF'
    Object changedRepositoryMarker(Long orderId) { return listLines(orderId); }
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
  OLLAMA_REVIEW_LOCK_DIR="$fixture_root/ollama.lock" \
  "$repo_root/bin/local-review.sh" --repo "$1"
}

output="$(run_review "$repo")"
for marker in \
  '履约派单按普通查询读取订单/明细后，在事务末尾整行回写旧订单聚合' \
  '履约派单按客户端明细顺序逐行更新/加锁'; do
  [[ "$(printf '%s\n' "$output" | grep -cF "$marker" || true)" == 1 ]] || {
    echo "sales fulfillment preflight did not emit exactly one finding: $marker" >&2
    printf '%s\n' "$output" >&2
    exit 1
  }
done
for field in '影响：' '修复建议：' '验证方式：' '证据行：'; do
  printf '%s\n' "$output" | grep -F "$field" >/dev/null || {
    echo "sales fulfillment preflight omitted $field" >&2
    exit 1
  }
done

safe_stale="$fixture_root/safe-stale"
cp -R "$repo" "$safe_stale"
python3 - "$safe_stale/src/main/java/com/example/sales/SalesFulfillmentApplication.java" <<'PY'
from pathlib import Path
import sys
file = Path(sys.argv[1])
text = file.read_text()
text = text.replace('var lines = salesOrderRepository.listLines(orderId);', 'var lines = salesOrderRepository.listLinesForUpdate(orderId);\n        lockOrder(orderId);')
text = text.replace('var currentLines = salesOrderRepository.listLines(order.getId());', 'var currentLines = salesOrderRepository.listLinesForUpdate(order.getId());\n        order.setVersion(expectedVersion);')
text = text.replace('    Object calculateStatus(Object lines) { return lines; }', '    void lockOrder(Long orderId) {}\n    Long expectedVersion;\n    Object calculateStatus(Object lines) { return lines; }')
file.write_text(text)
PY
safe_output="$(run_review "$safe_stale")"
if printf '%s\n' "$safe_output" | grep -F '履约派单按普通查询读取订单/明细后，在事务末尾整行回写旧订单聚合' >/dev/null; then
  echo 'sales fulfillment stale-order preflight reported lock/version-safe fixture' >&2
  exit 1
fi

safe_order="$fixture_root/safe-order"
cp -R "$repo" "$safe_order"
python3 - "$safe_order/src/main/java/com/example/sales/SalesFulfillmentApplication.java" <<'PY'
from pathlib import Path
import sys
file = Path(sys.argv[1])
text = file.read_text().replace(
    'java.util.List<DispatchLine> result = new java.util.ArrayList<>();',
    'java.util.List<DispatchLine> result = new java.util.ArrayList<>(input);\n        result.sort(java.util.Comparator.comparing(DispatchLine::toString));\n        result = new java.util.ArrayList<>();',
)
file.write_text(text)
PY
safe_output="$(run_review "$safe_order")"
if printf '%s\n' "$safe_output" | grep -F '履约派单按客户端明细顺序逐行更新/加锁' >/dev/null; then
  echo 'sales fulfillment lock-order preflight reported sorted fixture' >&2
  exit 1
fi

echo 'sales fulfillment preflight regression passed'
