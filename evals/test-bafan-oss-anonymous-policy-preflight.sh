#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-bafan-oss-policy.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
repo="$fixture_root/repo"
safe_repo="$fixture_root/safe-repo"
guarded_repo="$fixture_root/guarded-repo"
fake_bin="$fixture_root/bin"
mkdir -p "$repo/src/main/java/com/bofan/modules/common/controller" \
  "$repo/src/main/java/com/bofan/common/config" "$fake_bin"

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name bafan-oss-policy-preflight

cat >"$repo/src/main/java/com/bofan/common/config/WebMvcConfig.java" <<'EOF'
class WebMvcConfig {
    void addInterceptors(InterceptorRegistry registry) {
        registry.addInterceptor(appUserAuthInterceptor)
                .addPathPatterns("/api/**")
                .excludePathPatterns("/api/oss/**", "/api/upload/**");
    }
}
EOF
git -C "$repo" add .
git -C "$repo" commit -qm base

cat >"$repo/src/main/java/com/bofan/modules/common/controller/OssPolicyController.java" <<'EOF'
@RestController
@RequestMapping("/api/oss")
class OssPolicyController {
    @GetMapping("/policy")
    Result<Map<String, String>> getUploadPolicy() {
        String policyString = String.format(
                "{\"conditions\":[[\"starts-with\",\"$key\",\"\"],[\"content-length-range\",0,104857600]]}");
        String policy = Base64.getEncoder().encodeToString(policyString.getBytes(StandardCharsets.UTF_8));
        String signature = sign(policy, accessKeySecret);
        result.put("accessKeyId", accessKeyId);
        result.put("policy", policy);
        result.put("signature", signature);
        return Result.success(result);
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
marker='OSS Policy 接口被公开放行且签名条件允许任意对象 key'
[[ "$(printf '%s\n' "$output" | grep -cF "$marker" || true)" == 1 ]] || {
  echo 'Bafan OSS anonymous policy preflight did not emit exactly one finding' >&2
  printf '%s\n' "$output" >&2
  exit 1
}
printf '%s\n' "$output" | grep -F 'OssPolicyController.java:' >/dev/null
for field in '影响：' '修复建议：' '验证方式：' '证据行：'; do
  printf '%s\n' "$output" | grep -F "$field" >/dev/null || {
    echo "Bafan OSS anonymous policy preflight omitted $field" >&2
    exit 1
  }
done

cp -R "$repo" "$safe_repo"
python3 - "$safe_repo/src/main/java/com/bofan/common/config/WebMvcConfig.java" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text().replace('"/api/oss/**", "/api/upload/**"', '"/api/user/wx-login"')
path.write_text(text)
PY
safe_output="$(run_review "$safe_repo")"
if printf '%s\n' "$safe_output" | grep -F "$marker" >/dev/null; then
  echo 'Bafan OSS anonymous policy preflight reported the guarded route fixture' >&2
  printf '%s\n' "$safe_output" >&2
  exit 1
fi

cp -R "$repo" "$guarded_repo"
python3 - "$guarded_repo/src/main/java/com/bofan/modules/common/controller/OssPolicyController.java" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text().replace(
    '    @GetMapping("/policy")',
    '    @PreAuthorize("isAuthenticated()")\n    @GetMapping("/policy")',
)
path.write_text(text)
PY
guarded_output="$(run_review "$guarded_repo")"
if printf '%s\n' "$guarded_output" | grep -F "$marker" >/dev/null; then
  echo 'Bafan OSS anonymous policy preflight reported the method-guarded fixture' >&2
  printf '%s\n' "$guarded_output" >&2
  exit 1
fi

echo 'Bafan OSS anonymous policy preflight regression passed'
