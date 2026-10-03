#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-system-dept-tenant.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
repo="$fixture_root/repo"
safe_repo="$fixture_root/safe-repo"
fake_bin="$fixture_root/bin"
mkdir -p "$repo/src/main/java/com/bit/system/controller" \
  "$repo/src/main/java/com/bit/system/service/impl" \
  "$repo/src/main/java/com/bit/system/domain" "$fake_bin"

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name system-dept-tenant-preflight

cat >"$repo/src/main/java/com/bit/system/controller/DeptController.java" <<'EOF'
@RequestMapping("/api/v1/depts")
class DeptController {}
EOF
cat >"$repo/src/main/java/com/bit/system/service/impl/DeptServiceImpl.java" <<'EOF'
class DeptServiceImpl {}
EOF
cat >"$repo/src/main/java/com/bit/system/domain/SysDept.java" <<'EOF'
class SysDept {
    private Long tenantId;
}
EOF
git -C "$repo" add .
git -C "$repo" commit -qm base

cat >"$repo/src/main/java/com/bit/system/controller/DeptController.java" <<'EOF'
@RequestMapping("/api/v1/depts")
class DeptController {
    @PostMapping
    Result<Void> create(@RequestBody Map<String, Object> body) {
        deptService.createDept(buildDept(body));
        return Result.ok();
    }
    @PutMapping("/{id}")
    Result<Void> update(@PathVariable Long id, @RequestBody Map<String, Object> body) {
        deptService.updateDept(buildDept(body));
        return Result.ok();
    }
    private SysDept buildDept(Map<String, Object> body) {
        SysDept dept = new SysDept();
        if (body.get("tenantId") != null) dept.setTenantId(toLong(body.get("tenantId")));
        return dept;
    }
}
EOF
cat >"$repo/src/main/java/com/bit/system/service/impl/DeptServiceImpl.java" <<'EOF'
class DeptServiceImpl {
    boolean createDept(SysDept dept) {
        Long tenantId = dept.getTenantId() != null ? dept.getTenantId() : TenantContextHolder.getTenantId();
        dept.setTenantId(tenantId);
        fillTreePath(dept);
        return sysDeptMapper.insert(dept) > 0;
    }
    boolean updateDept(SysDept dept) {
        SysDept old = sysDeptMapper.selectById(dept.getId());
        dept.setTenantId(dept.getTenantId() != null ? dept.getTenantId() : old.getTenantId());
        fillTreePath(dept);
        return sysDeptMapper.updateById(dept) > 0;
    }
}
EOF

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
marker='部门写接口接受请求体 tenantId，并在服务层直接用于 insert/updateById'
[[ "$(printf '%s\n' "$output" | grep -cF "$marker" || true)" == 1 ]] || {
  echo 'system dept tenant write preflight did not emit exactly one finding' >&2
  printf '%s\n' "$output" >&2
  exit 1
}
printf '%s\n' "$output" | grep -F 'DeptController.java:' >/dev/null

cp -R "$repo" "$safe_repo"
python3 - "$safe_repo/src/main/java/com/bit/system/service/impl/DeptServiceImpl.java" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
text = text.replace(
    'Long tenantId = dept.getTenantId() != null ? dept.getTenantId() : TenantContextHolder.getTenantId();',
    'TenantOperationGuard guard = new TenantOperationGuard();\n'
    '        Long tenantId = guard.resolveTenantId(dept.getTenantId());\n'
    '        guard.assertCurrentTenant(tenantId);',
)
text = text.replace(
    'dept.setTenantId(dept.getTenantId() != null ? dept.getTenantId() : old.getTenantId());',
    'TenantOperationGuard guard = new TenantOperationGuard();\n'
    '        guard.assertCurrentTenant(old.getTenantId());\n'
    '        guard.assertCurrentTenant(dept.getTenantId());\n'
    '        dept.setTenantId(old.getTenantId());',
)
path.write_text(text)
PY
safe_output="$(run_review "$safe_repo")"
if printf '%s\n' "$safe_output" | grep -F "$marker" >/dev/null; then
  echo 'system dept tenant write preflight reported the guarded safe fixture' >&2
  printf '%s\n' "$safe_output" >&2
  exit 1
fi

echo 'system dept tenant write preflight regression passed'
