#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-system-api-resource-sync.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
repo="$fixture_root/repo"
safe_repo="$fixture_root/safe-repo"
fake_bin="$fixture_root/bin"
mkdir -p "$repo/src/main/java/com/bit/system/controller" \
  "$repo/src/main/java/com/bit/system/application" "$repo/src/main/java/com/bit/system/domain" "$fake_bin"

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name system-api-resource-sync-preflight

cat >"$repo/README.md" <<'EOF'
内部同步接口必须携带与 gateway.auth.internal-token 一致的 X-Gateway-Token。
EOF
cat >"$repo/src/main/java/com/bit/system/controller/ApiResourceSyncController.java" <<'EOF'
@RequestMapping("/api/v1/internal/api-resources")
class ApiResourceSyncController {}
EOF
cat >"$repo/src/main/java/com/bit/system/application/ApiResourceSyncApplication.java" <<'EOF'
class ApiResourceSyncApplication {}
EOF
git -C "$repo" add .
git -C "$repo" commit -qm base

cat >"$repo/src/main/java/com/bit/system/controller/ApiResourceSyncController.java" <<'EOF'
@RequestMapping("/api/v1/internal/api-resources")
class ApiResourceSyncController {
    @PostMapping("/sync")
    Result<ApiResourceSyncResult> synchronize(@RequestBody ApiResourceSyncRequest request) {
        return Result.ok(apiResourceSyncApplication.synchronize(request));
    }
}
EOF
cat >"$repo/src/main/java/com/bit/system/application/ApiResourceSyncApplication.java" <<'EOF'
class ApiResourceSyncApplication {
    public ApiResourceSyncResult synchronize(ApiResourceSyncRequest request) {
        SysApplication application = applicationMapper.selectOne(
                query.eq(SysApplication::getCode, request.applicationCode()));
        apiResourceMapper.insert(build(application.getId(), request));
        apiResourceMapper.updateById(existing);
        return result();
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
marker='内部 API 资源同步接口使用共享网关令牌但未把调用方绑定到 applicationCode'
[[ "$(printf '%s\n' "$output" | grep -cF "$marker" || true)" == 1 ]] || {
  echo 'system api resource sync scope preflight did not emit exactly one finding' >&2
  printf '%s\n' "$output" >&2
  exit 1
}
printf '%s\n' "$output" | grep -F 'ApiResourceSyncController.java:' >/dev/null

cp -R "$repo" "$safe_repo"
python3 - "$safe_repo/src/main/java/com/bit/system/controller/ApiResourceSyncController.java" \
  "$safe_repo/src/main/java/com/bit/system/application/ApiResourceSyncApplication.java" <<'PY'
from pathlib import Path
import sys

controller, application = map(Path, sys.argv[1:])
controller.write_text(controller.read_text().replace(
    'Result<ApiResourceSyncResult> synchronize(@RequestBody ApiResourceSyncRequest request)',
    '@InternalService("platform-erp-service")\n    Result<ApiResourceSyncResult> synchronize(@RequestHeader("X-Gateway-Token") String token, @RequestBody ApiResourceSyncRequest request)'))
application.write_text(application.read_text().replace(
    'public ApiResourceSyncResult synchronize(ApiResourceSyncRequest request)',
    'public ApiResourceSyncResult synchronize(ApiResourceSyncRequest request, String callerService)')
    .replace('SysApplication application = applicationMapper.selectOne(',
             'assertServiceBoundToApplication(callerService, request.applicationCode());\n        SysApplication application = applicationMapper.selectOne(')
    .replace('apiResourceMapper.insert(build(application.getId(), request));',
             'apiResourceMapper.insert(build(application.getId(), request));'))
PY
safe_output="$(run_review "$safe_repo")"
if printf '%s\n' "$safe_output" | grep -F "$marker" >/dev/null; then
  echo 'system api resource sync scope preflight reported guarded safe fixture' >&2
  printf '%s\n' "$safe_output" >&2
  exit 1
fi

echo 'system api resource sync scope preflight regression passed'
