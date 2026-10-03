#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-system-role-resource-scope.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
repo="$fixture_root/repo"
safe_repo="$fixture_root/safe-repo"
fake_bin="$fixture_root/bin"
mkdir -p "$repo/src/main/java/com/bit/system/controller" \
  "$repo/src/main/java/com/bit/system/application" \
  "$repo/src/main/java/com/bit/system/service/impl" "$fake_bin"

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name system-role-resource-scope-preflight

cat >"$repo/src/main/java/com/bit/system/controller/RoleController.java" <<'EOF'
class RoleController {}
EOF
cat >"$repo/src/main/java/com/bit/system/application/RolePermissionApplication.java" <<'EOF'
class RolePermissionApplication {}
EOF
git -C "$repo" add .
git -C "$repo" commit -qm base

cat >"$repo/src/main/java/com/bit/system/controller/RoleController.java" <<'EOF'
class RoleController {
    @PutMapping("/{id}/permissions")
    Result<RolePermissionAssignResultVO> assignPermissions(@PathVariable Long id, @RequestBody Map<String, Object> body) {
        return Result.ok(rolePermissionApplication.assignPermissions(id, menuIds, apiIds, deptIds, true));
    }
    @PutMapping("/{id}/menus")
    Result<Void> menus(@PathVariable Long id, @RequestBody List<Long> menuIds) {
        roleService.assignRoleMenus(id, tenantId, menuIds);
        return Result.ok();
    }
    @PutMapping("/{id}/depts")
    Result<Void> depts(@PathVariable Long id, @RequestBody List<Long> deptIds) {
        roleService.assignRoleDepts(id, tenantId, deptIds);
        return Result.ok();
    }
}
EOF
cat >"$repo/src/main/java/com/bit/system/application/RolePermissionApplication.java" <<'EOF'
class RolePermissionApplication {
    public RolePermissionAssignResultVO assignPermissions(Long roleId, List<Long> menuIds, List<Long> apiIds,
                                                           List<Long> deptIds, boolean assignDept) {
        replaceRoleMenus(roleId, tenantId, menuIds);
        replaceRoleDepts(roleId, tenantId, deptIds);
        return result();
    }
    private void replaceRoleMenus(Long roleId, Long tenantId, List<Long> menuIds) {
        TenantContextHolder.runWithIgnoreTenant(() -> roleMenuMapper.deleteByRoleId(roleId));
        List<SysRoleMenu> list = menuIds.stream().map(menuId -> new SysRoleMenu(menuId, tenantId)).toList();
        TenantContextHolder.runWithIgnoreTenant(() -> roleMenuMapper.batchInsert(list));
    }
    private void replaceRoleDepts(Long roleId, Long tenantId, List<Long> deptIds) {
        TenantContextHolder.runWithIgnoreTenant(() -> roleDeptMapper.deleteByRoleId(roleId));
        List<SysRoleDept> list = deptIds.stream().map(deptId -> new SysRoleDept(deptId, tenantId)).toList();
        TenantContextHolder.runWithIgnoreTenant(() -> roleDeptMapper.batchInsert(list));
    }
}
EOF
cat >"$repo/src/main/java/com/bit/system/service/impl/RoleServiceImpl.java" <<'EOF'
class RoleServiceImpl {
    public void assignRoleMenus(Long roleId, Long tenantId, List<Long> menuIds) {
        saveRoleMenus(roleId, tenantId, menuIds);
    }
    public void assignRoleDepts(Long roleId, Long tenantId, List<Long> deptIds) {
        saveRoleDepts(roleId, tenantId, deptIds);
    }
    private void saveRoleMenus(Long roleId, Long tenantId, List<Long> menuIds) {
        TenantContextHolder.runWithIgnoreTenant(() -> roleMenuMapper.batchInsert(menuIds.stream()
            .map(menuId -> new SysRoleMenu(roleId, menuId, tenantId)).toList()));
    }
    private void saveRoleDepts(Long roleId, Long tenantId, List<Long> deptIds) {
        TenantContextHolder.runWithIgnoreTenant(() -> roleDeptMapper.batchInsert(deptIds.stream()
            .map(deptId -> new SysRoleDept(roleId, deptId, tenantId)).toList()));
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
marker='角色权限写接口直接信任请求中的菜单/部门 ID'
[[ "$(printf '%s\n' "$output" | grep -cF "$marker" || true)" == 1 ]] || {
  echo 'system role permission resource scope preflight did not emit exactly one finding' >&2
  printf '%s\n' "$output" >&2
  exit 1
}
printf '%s\n' "$output" | grep -F 'RoleController.java:' >/dev/null

cp -R "$repo" "$safe_repo"
python3 - "$safe_repo/src/main/java/com/bit/system/application/RolePermissionApplication.java" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace(
    'replaceRoleMenus(roleId, tenantId, menuIds);',
    'long menuCount = sysTenantMenuMapper.selectCount(new QueryWrapper<SysTenantMenu>().eq("tenant_id", tenantId).in("menu_id", menuIds));\n'
    '        if (menuCount != menuIds.size()) throw new IllegalArgumentException();\n'
    '        replaceRoleMenus(roleId, tenantId, menuIds);')
text = text.replace(
    'replaceRoleDepts(roleId, tenantId, deptIds);',
    'long deptCount = sysDeptMapper.selectCount(new QueryWrapper<SysDept>().eq("tenant_id", tenantId).in("id", deptIds).eq("is_deleted", 0));\n'
    '        if (deptCount != deptIds.size()) throw new IllegalArgumentException();\n'
    '        replaceRoleDepts(roleId, tenantId, deptIds);')
path.write_text(text)
PY
python3 - "$safe_repo/src/main/java/com/bit/system/service/impl/RoleServiceImpl.java" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace(
    'saveRoleMenus(roleId, tenantId, menuIds);',
    'long menuCount = sysTenantMenuMapper.selectCount(new QueryWrapper<SysTenantMenu>().eq("tenant_id", tenantId).in("menu_id", menuIds));\n'
    '        if (menuCount != menuIds.size()) throw new IllegalArgumentException();\n'
    '        saveRoleMenus(roleId, tenantId, menuIds);')
text = text.replace(
    'saveRoleDepts(roleId, tenantId, deptIds);',
    'long deptCount = sysDeptMapper.selectCount(new QueryWrapper<SysDept>().eq("tenant_id", tenantId).in("id", deptIds).eq("is_deleted", 0));\n'
    '        if (deptCount != deptIds.size()) throw new IllegalArgumentException();\n'
    '        saveRoleDepts(roleId, tenantId, deptIds);')
text = text.replace(
    'long menuCount = sysTenantMenuMapper.selectCount(new QueryWrapper<SysTenantMenu>().eq("tenant_id", tenantId).in("menu_id", menuIds));\n'
    '        if (menuCount != menuIds.size()) throw new IllegalArgumentException();\n',
    'ensureTenantMenus(menuIds, tenantId);\n')
text = text.replace(
    'long deptCount = sysDeptMapper.selectCount(new QueryWrapper<SysDept>().eq("tenant_id", tenantId).in("id", deptIds).eq("is_deleted", 0));\n'
    '        if (deptCount != deptIds.size()) throw new IllegalArgumentException();\n',
    'checkAssignableDepts(deptIds, tenantId);\n')
text = text.replace(
    '    private void saveRoleMenus(Long roleId, Long tenantId, List<Long> menuIds) {',
    '    private void ensureTenantMenus(List<Long> menuIds, Long tenantId) {\n'
    '        sysTenantMenuMapper.selectCount(new QueryWrapper<SysTenantMenu>().eq("tenant_id", tenantId).in("menu_id", menuIds));\n'
    '    }\n'
    '    private void checkAssignableDepts(List<Long> deptIds, Long tenantId) {\n'
    '        sysDeptMapper.selectCount(new QueryWrapper<SysDept>().eq("tenant_id", tenantId).in("id", deptIds).eq("is_deleted", 0));\n'
    '    }\n'
    '    private void saveRoleMenus(Long roleId, Long tenantId, List<Long> menuIds) {')
path.write_text(text)
PY
safe_output="$(run_review "$safe_repo")"
if printf '%s\n' "$safe_output" | grep -F "$marker" >/dev/null; then
  echo 'system role permission resource scope preflight reported guarded safe fixture' >&2
  printf '%s\n' "$safe_output" >&2
  exit 1
fi

name_only_repo="$fixture_root/name-only-repo"
cp -R "$repo" "$name_only_repo"
python3 - "$name_only_repo/src/main/java/com/bit/system/application/RolePermissionApplication.java" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace(
    'replaceRoleMenus(roleId, tenantId, menuIds);',
    'validateAssignableMenus(menuIds, tenantId);\n        replaceRoleMenus(roleId, tenantId, menuIds);')
text = text.replace(
    'replaceRoleDepts(roleId, tenantId, deptIds);',
    'validateAssignableDepts(deptIds, tenantId);\n        replaceRoleDepts(roleId, tenantId, deptIds);')
path.write_text(text)
PY
name_only_output="$(run_review "$name_only_repo")"
printf '%s\n' "$name_only_output" | grep -F "$marker" >/dev/null || {
  echo 'system role permission resource scope preflight was suppressed by helper names without evidence' >&2
  printf '%s\n' "$name_only_output" >&2
  exit 1
}

echo 'system role permission resource scope preflight regression passed'
