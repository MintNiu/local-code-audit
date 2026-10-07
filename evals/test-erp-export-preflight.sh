#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-erp-export.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
repo="$fixture_root/repo"
fake_bin="$fixture_root/bin"
mkdir -p "$repo/src/main/java/com/example/exporttask" "$repo/src/main/java/com/example/retailer" "$repo/sql" "$fake_bin"

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name erp-export-preflight

cat >"$repo/README.md" <<'EOF'
已有数据库必须通过 sql/migration 版本化迁移升级，初始化快照不会修改既有表。
EOF
for file in ExportTaskApplication ExportTaskRepository ExportTaskStatus ErpExportTask; do
  printf 'final class %s {}\n' "$file" >"$repo/src/main/java/com/example/exporttask/$file.java"
done
for file in RetailerExportHandler RetailerRepository RetailerApplication; do
  printf 'final class %s {}\n' "$file" >"$repo/src/main/java/com/example/retailer/$file.java"
done
cat >"$repo/sql/platform_erp.sql" <<'EOF'
CREATE TABLE IF NOT EXISTS `unrelated_table` (`id` BIGINT PRIMARY KEY);
EOF
git -C "$repo" add .
git -C "$repo" commit -qm base

cat >"$repo/src/main/java/com/example/exporttask/ExportTaskApplication.java" <<'EOF'
final class ExportTaskApplication {
    void executeTask(Long taskId) throws Exception {
        var task = repository.findById(taskId);
        repository.markRunning(taskId);
        task = repository.findById(taskId);
        try {
            exportFile(task);
        } catch (Exception exception) {
            repository.markFailed(taskId, exception.getMessage());
            throw exception;
        }
    }
    void cleanup() { repository.listExpiredSuccess(); }
    void exportFile(Object task) {}
    ExportTaskRepository repository;
}
EOF
cat >"$repo/src/main/java/com/example/exporttask/ExportTaskRepository.java" <<'EOF'
final class ExportTaskRepository {
    boolean markRunning(Long taskId) {
        heartbeat();
        return update(taskId, ExportTaskStatus.PENDING.name(), ExportTaskStatus.RUNNING.name());
    }
    void updateProgress(Long taskId) { heartbeat(); }
    java.util.List<Object> listExpiredSuccess() { return select("SUCCESS"); }
    void markFailed(Long taskId, String message) {}
    void heartbeat() {}
    boolean update(Long id, String from, String to) { return true; }
    java.util.List<Object> select(String status) { return java.util.List.of(); }
}
EOF
cat >"$repo/src/main/java/com/example/exporttask/ExportTaskStatus.java" <<'EOF'
final class ExportTaskStatus {
    static java.util.List<String> activeValues() { return java.util.List.of("PENDING", "RUNNING"); }
}
EOF
cat >"$repo/src/main/java/com/example/exporttask/ErpExportTask.java" <<'EOF'
final class ErpExportTask {}
EOF
cat >"$repo/src/main/java/com/example/retailer/RetailerExportHandler.java" <<'EOF'
final class RetailerExportHandler {
    long writeAsync() throws Exception {
        long exportedCount = 0L;
        Integer lastStatus = null;
        Long lastId = null;
        try (ExcelWriter writer = EasyExcel.write(targetFile).build()) {
            WriteSheet sheet = EasyExcel.writerSheet("零售商列表").build();
            while (true) {
                var batch = repository.listExportBatch(lastStatus, lastId, 100);
                if (batch.isEmpty()) {
                    break;
                }
                writer.write(toRows(batch), sheet);
                exportedCount += batch.size();
                lastStatus = batch.get(batch.size() - 1).getStatus();
                lastId = batch.get(batch.size() - 1).getId();
            }
        }
        return exportedCount;
    }
    Object targetFile;
    RetailerRepository repository;
    Object toRows(Object rows) { return rows; }
}
EOF
cat >"$repo/src/main/java/com/example/retailer/RetailerRepository.java" <<'EOF'
final class RetailerRepository {
    java.util.List<Retailer> listExportBatch(Integer lastStatus, Long lastId, int batchSize) {
        var wrapper = buildQueryWrapper();
        if (lastStatus != null && lastId != null) {
            wrapper.and(w -> w.gt(Retailer::getStatus, lastStatus)
                    .or().eq(Retailer::getStatus, lastStatus).lt(Retailer::getId, lastId));
        }
        return mapper.selectList(wrapper.last("LIMIT " + batchSize));
    }
    QueryWrapper buildQueryWrapper() { return new QueryWrapper().orderByAsc(Retailer::getStatus).orderByDesc(Retailer::getId); }
    RetailerMapper mapper;
}
EOF
cat >"$repo/src/main/java/com/example/retailer/RetailerApplication.java" <<'EOF'
final class RetailerApplication {
    void disable(Long id) {
        var entity = repository.findById(id);
        entity.setStatus(0);
        repository.update(entity);
    }
    void enable(Long id) {
        var entity = repository.findById(id);
        entity.setStatus(1);
        repository.update(entity);
    }
    RetailerRepository repository;
}
EOF
cat >"$repo/sql/platform_erp.sql" <<'EOF'
CREATE TABLE IF NOT EXISTS `unrelated_table` (`id` BIGINT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS `erp_export_task` (`id` BIGINT PRIMARY KEY, `status` VARCHAR(32));
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
for marker in \
  '异步导出任务表只出现在全量初始化 schema' \
  '异步导出任务置为 RUNNING 后没有超时租约回收路径' \
  '异步导出在首批查询为空时直接结束' \
  '大数据导出使用可变 status+id 游标'; do
  [[ "$(printf '%s\n' "$output" | grep -cF "$marker" || true)" == 1 ]] || {
    echo "ERP export preflight did not emit exactly one finding: $marker" >&2
    printf '%s\n' "$output" >&2
    exit 1
  }
done
for field in '影响：' '修复建议：' '验证方式：' '证据行：'; do
  printf '%s\n' "$output" | grep -F "$field" >/dev/null || {
    echo "ERP export preflight omitted $field" >&2
    exit 1
  }
done

safe_migration="$fixture_root/safe-migration"
cp -R "$repo" "$safe_migration"
mkdir -p "$safe_migration/sql/migration"
printf '%s\n' 'CREATE TABLE IF NOT EXISTS `erp_export_task` (`id` BIGINT PRIMARY KEY);' >"$safe_migration/sql/migration/V20261007__erp_export_task.sql"
safe_output="$(run_review "$safe_migration")"
if printf '%s\n' "$safe_output" | grep -F '异步导出任务表只出现在全量初始化 schema' >/dev/null; then
  echo 'ERP export migration preflight reported versioned migration fixture' >&2
  exit 1
fi

safe_lease="$fixture_root/safe-lease"
cp -R "$repo" "$safe_lease"
cat >>"$safe_lease/src/main/java/com/example/exporttask/ExportTaskRepository.java" <<'EOF'
    void recoverStaleRunning() { reclaimLease(); }
    void reclaimLease() {}
EOF
safe_output="$(run_review "$safe_lease")"
if printf '%s\n' "$safe_output" | grep -F '异步导出任务置为 RUNNING 后没有超时租约回收路径' >/dev/null; then
  echo 'ERP export lease preflight reported recovery-safe fixture' >&2
  exit 1
fi

safe_empty="$fixture_root/safe-empty"
cp -R "$repo" "$safe_empty"
python3 - "$safe_empty/src/main/java/com/example/retailer/RetailerExportHandler.java" <<'PY'
from pathlib import Path
import sys
file = Path(sys.argv[1])
text = file.read_text().replace('WriteSheet sheet = EasyExcel.writerSheet("零售商列表").build();', 'WriteSheet sheet = EasyExcel.writerSheet("零售商列表").build();\n            writer.write(java.util.Collections.emptyList(), sheet);')
file.write_text(text)
PY
safe_output="$(run_review "$safe_empty")"
if printf '%s\n' "$safe_output" | grep -F '异步导出在首批查询为空时直接结束' >/dev/null; then
  echo 'ERP export empty workbook preflight reported explicit empty write fixture' >&2
  exit 1
fi

safe_cursor="$fixture_root/safe-cursor"
cp -R "$repo" "$safe_cursor"
python3 - "$safe_cursor/src/main/java/com/example/retailer/RetailerRepository.java" <<'PY'
from pathlib import Path
import sys
file = Path(sys.argv[1])
text = file.read_text()
text = text.replace('Integer lastStatus, Long lastId', 'Long lastId')
text = text.replace('if (lastStatus != null && lastId != null) {\n            wrapper.and(w -> w.gt(Retailer::getStatus, lastStatus)\n                    .or().eq(Retailer::getStatus, lastStatus).lt(Retailer::getId, lastId));\n        }', 'if (lastId != null) {\n            wrapper.lt(Retailer::getId, lastId);\n        }')
text = text.replace('.orderByAsc(Retailer::getStatus).orderByDesc(Retailer::getId)', '.orderByDesc(Retailer::getId)')
file.write_text(text)
PY
safe_output="$(run_review "$safe_cursor")"
if printf '%s\n' "$safe_output" | grep -F '大数据导出使用可变 status+id 游标' >/dev/null; then
  echo 'ERP export cursor preflight reported immutable-id fixture' >&2
  exit 1
fi

echo 'ERP export preflight regression passed'
