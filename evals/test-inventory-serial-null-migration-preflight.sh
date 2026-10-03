#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-inventory-null-migration.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
repo="$fixture_root/repo"
safe_repo="$fixture_root/safe-repo"
fake_bin="$fixture_root/bin"
mkdir -p "$repo/src/main/java/com/bit/erp/repository/warehouse" \
  "$repo/src/main/java/com/bit/erp/application/warehouse" "$repo/sql/migration" "$fake_bin"

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name inventory-null-migration-preflight

cat >"$repo/README.md" <<'EOF'
已有数据库必须通过 sql/migration 版本化迁移升级，初始化快照不会修改既有表。
EOF
cat >"$repo/src/main/java/com/bit/erp/repository/warehouse/LogicalWarehouseSkuRepository.java" <<'EOF'
class LogicalWarehouseSkuRepository {
    Object findNoSerial() {
        return query
            .and(w -> w.isNull(ErpLogicalWarehouseSku::getSerialNo)
                .or()
                .eq(ErpLogicalWarehouseSku::getSerialNo, ""));
    }
}
EOF
cat >"$repo/src/main/java/com/bit/erp/application/warehouse/OutboundOrderApplication.java" <<'EOF'
class OutboundOrderApplication {
    void read() { repository.listNoSerialByLogicalWarehouseIdAndSkuId(1L, 2L); }
}
EOF
cat >"$repo/src/main/java/com/bit/erp/application/warehouse/NonPhysicalTransferApplication.java" <<'EOF'
class NonPhysicalTransferApplication {
    void read() { repository.listNoSerialByLogicalWarehouseIdAndSkuId(1L, 2L); }
}
EOF
cat >"$repo/sql/platform_erp.sql" <<'EOF'
CREATE TABLE IF NOT EXISTS `erp_logical_warehouse_sku` (
    `serial_no` VARCHAR(128) DEFAULT NULL,
    PRIMARY KEY (`id`)
);
EOF
git -C "$repo" add .
git -C "$repo" commit -qm base

python3 - "$repo" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
repo = root / "src/main/java/com/bit/erp/repository/warehouse/LogicalWarehouseSkuRepository.java"
repo.write_text('''class LogicalWarehouseSkuRepository {\n    Object findNoSerial() {\n        return query\n            .eq(ErpLogicalWarehouseSku::getSerialNo, "");\n    }\n}\n''')
schema = root / "sql/platform_erp.sql"
schema.write_text('''CREATE TABLE IF NOT EXISTS `erp_logical_warehouse_sku` (\n    `serial_no` VARCHAR(128) NOT NULL DEFAULT '',\n    PRIMARY KEY (`id`),\n    UNIQUE KEY `uk_logical_warehouse_sku_serial` (`serial_no`)\n);\n''')
PY

cat >"$fake_bin/ollama" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
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
marker='无串码库存查询从 NULL/空字符串兼容改为只匹配空字符串'
[[ "$(printf '%s\n' "$output" | grep -cF "$marker" || true)" == 1 ]] || {
  echo 'inventory serial NULL migration preflight did not emit exactly one finding' >&2
  printf '%s\n' "$output" >&2
  exit 1
}
for field in '影响：' '修复建议：' '验证方式：' '证据行：'; do
  printf '%s\n' "$output" | grep -F "$field" >/dev/null || {
    echo "inventory serial NULL migration preflight omitted $field" >&2
    exit 1
  }
done

cp -R "$repo" "$safe_repo"
python3 - "$safe_repo" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
repo = root / "src/main/java/com/bit/erp/repository/warehouse/LogicalWarehouseSkuRepository.java"
repo.write_text('''class LogicalWarehouseSkuRepository {\n    Object findNoSerial() {\n        return query\n            .and(w -> w.isNull(ErpLogicalWarehouseSku::getSerialNo)\n                .or()\n                .eq(ErpLogicalWarehouseSku::getSerialNo, ""));\n    }\n}\n''')
PY
safe_output="$(run_review "$safe_repo")"
if printf '%s\n' "$safe_output" | grep -F "$marker" >/dev/null; then
  echo 'inventory serial NULL migration preflight reported NULL-compatible fixture' >&2
  printf '%s\n' "$safe_output" >&2
  exit 1
fi

echo 'inventory serial NULL migration preflight regression passed'
