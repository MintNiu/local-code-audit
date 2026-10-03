#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-system-application-secret.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
repo="$fixture_root/repo"
safe_repo="$fixture_root/safe-repo"
fake_bin="$fixture_root/bin"
mkdir -p "$repo/src/main/java/com/bit/system/controller" \
  "$repo/src/main/java/com/bit/system/application" \
  "$repo/src/main/java/com/bit/system/repository" \
  "$repo/src/main/java/com/bit/system/domain" "$fake_bin"

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name system-application-secret-preflight

cat >"$repo/src/main/java/com/bit/system/controller/ApplicationController.java" <<'EOF'
@RequestMapping("/api/v1/applications")
class ApplicationController {}
EOF
cat >"$repo/src/main/java/com/bit/system/application/ApplicationCenterApplication.java" <<'EOF'
class ApplicationCenterApplication {}
EOF
cat >"$repo/src/main/java/com/bit/system/repository/ApplicationRepository.java" <<'EOF'
class ApplicationRepository {}
EOF
cat >"$repo/src/main/java/com/bit/system/domain/SysApplication.java" <<'EOF'
class SysApplication {}
EOF
cat >"$repo/src/main/java/com/bit/system/domain/SysTenantApplication.java" <<'EOF'
class SysTenantApplication {}
EOF
git -C "$repo" add .
git -C "$repo" commit -qm base

cat >"$repo/src/main/java/com/bit/system/controller/ApplicationController.java" <<'EOF'
@RequestMapping("/api/v1/applications")
class ApplicationController {
    @PreAuthorize("@perm.has('sys:application:query')")
    @GetMapping("/{id:\\d+}")
    Result<SysApplication> detail(@PathVariable Long id) {
        return Result.ok(application.detail(id));
    }
}
EOF
cat >"$repo/src/main/java/com/bit/system/application/ApplicationCenterApplication.java" <<'EOF'
class ApplicationCenterApplication {
    public SysApplication detail(Long id) {
        return ensureExists(id);
    }
    private SysApplication ensureExists(Long id) {
        return applicationRepository.findById(id);
    }
}
EOF
cat >"$repo/src/main/java/com/bit/system/repository/ApplicationRepository.java" <<'EOF'
class ApplicationRepository {
    private final SysTenantApplicationMapper tenantApplicationMapper;
    public SysApplication findById(Long id) {
        return applicationMapper.selectById(id);
    }
    public List<Long> findTenantIds(Long id) {
        return tenantApplicationMapper.selectList(query);
    }
}
EOF
cat >"$repo/src/main/java/com/bit/system/domain/SysApplication.java" <<'EOF'
class SysApplication {
    private String clientSecret;
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
marker='应用详情接口把含 clientSecret 的 SysApplication 原样返回'
[[ "$(printf '%s\n' "$output" | grep -cF "$marker" || true)" == 1 ]] || {
  echo 'system application secret scope preflight did not emit exactly one finding' >&2
  printf '%s\n' "$output" >&2
  exit 1
}
printf '%s\n' "$output" | grep -F 'ApplicationController.java:' >/dev/null

cp -R "$repo" "$safe_repo"
python3 - "$safe_repo/src/main/java/com/bit/system/controller/ApplicationController.java" \
  "$safe_repo/src/main/java/com/bit/system/application/ApplicationCenterApplication.java" \
  "$safe_repo/src/main/java/com/bit/system/repository/ApplicationRepository.java" <<'PY'
from pathlib import Path
import sys
controller, application, repository = map(Path, sys.argv[1:])
controller.write_text(controller.read_text().replace('Result<SysApplication> detail', 'Result<ApplicationVO> detail').replace('application.detail(id)', 'application.detailVisible(id)'))
application.write_text(application.read_text().replace('public SysApplication detail(Long id)', 'public ApplicationVO detailVisible(Long id)').replace('return ensureExists(id);', 'return toVO(repository.findByIdForTenant(id));').replace('private SysApplication ensureExists', 'private SysApplication ensureExistsUnused'))
text = repository.read_text().replace('findById(Long id)', 'findByIdForTenant(Long id)').replace('return applicationMapper.selectById(id);', 'return tenantApplicationMapper.selectByTenantAndApplication(currentTenantId(), id);')
repository.write_text(text)
PY
safe_output="$(run_review "$safe_repo")"
if printf '%s\n' "$safe_output" | grep -F "$marker" >/dev/null; then
  echo 'system application secret scope preflight reported guarded safe fixture' >&2
  printf '%s\n' "$safe_output" >&2
  exit 1
fi

echo 'system application secret scope preflight regression passed'
