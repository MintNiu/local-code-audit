#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-bafan-role-menu-authz.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
repo="$fixture_root/repo"
safe_repo="$fixture_root/safe-repo"
fake_bin="$fixture_root/bin"
mkdir -p "$repo/src/main/java/com/bofan/modules/admin/controller" \
  "$repo/src/main/java/com/bofan/common/config" \
  "$repo/src/main/java/com/bofan/modules/admin/interceptor" "$fake_bin"

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name bafan-role-menu-authz-preflight

cat >"$repo/src/main/java/com/bofan/modules/admin/controller/AdminRoleController.java" <<'EOF'
@RequestMapping("/admin/role")
class AdminRoleController {}
EOF
cat >"$repo/src/main/java/com/bofan/common/config/WebMvcConfig.java" <<'EOF'
class WebMvcConfig {
    void addInterceptors(InterceptorRegistry registry) {
        registry.addInterceptor(adminAuthInterceptor).addPathPatterns("/admin/**");
    }
}
EOF
cat >"$repo/src/main/java/com/bofan/modules/admin/interceptor/AdminAuthInterceptor.java" <<'EOF'
class AdminAuthInterceptor {
    void authenticate() { AdminContext.setRole(role); }
}
EOF
git -C "$repo" add .
git -C "$repo" commit -qm base

cat >"$repo/src/main/java/com/bofan/modules/admin/controller/AdminRoleController.java" <<'EOF'
@RequestMapping("/admin/role")
class AdminRoleController {
    @PutMapping("/{roleId}/menus")
    Result<Void> updateRoleMenus(@PathVariable Long roleId, @RequestBody List<Long> menuIds) {
        roleService.saveRoleMenus(roleId, menuIds);
        return Result.success();
    }
    @PostMapping("/init-role-menus")
    Result<Void> initRoleMenus() {
        roleService.initBasicRoleMenus();
        return Result.success();
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
marker='角色菜单写接口只有 JWT 认证，缺少角色/权限授权校验'
[[ "$(printf '%s\n' "$output" | grep -cF "$marker" || true)" == 1 ]] || {
  echo 'Bafan admin role-menu authorization preflight did not emit exactly one finding' >&2
  printf '%s\n' "$output" >&2
  exit 1
}
printf '%s\n' "$output" | grep -F 'AdminRoleController.java:' >/dev/null

cp -R "$repo" "$safe_repo"
python3 - "$safe_repo/src/main/java/com/bofan/modules/admin/controller/AdminRoleController.java" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace('@PutMapping("/{roleId}/menus")',
                    '@PreAuthorize("hasAuthority(\'role:assign\')")\n    @PutMapping("/{roleId}/menus")')
text = text.replace('@PostMapping("/init-role-menus")',
                    '@PreAuthorize("hasRole(\'SUPER_ADMIN\')")\n    @PostMapping("/init-role-menus")')
path.write_text(text)
PY
safe_output="$(run_review "$safe_repo")"
if printf '%s\n' "$safe_output" | grep -F "$marker" >/dev/null; then
  echo 'Bafan admin role-menu authorization preflight reported guarded safe fixture' >&2
  printf '%s\n' "$safe_output" >&2
  exit 1
fi

echo 'Bafan admin role-menu authorization preflight regression passed'
