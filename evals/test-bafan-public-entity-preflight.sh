#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-bafan-public-entity.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
repo="$fixture_root/repo"
safe_repo="$fixture_root/safe-repo"
guarded_repo="$fixture_root/guarded-repo"
fake_bin="$fixture_root/bin"
mkdir -p "$repo/src/main/java/com/bofan/modules/merchant/controller" \
  "$repo/src/main/java/com/bofan/modules/merchant/entity" \
  "$repo/src/main/java/com/bofan/common/config" "$fake_bin"

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name bafan-public-entity-preflight

cat >"$repo/src/main/java/com/bofan/common/config/WebMvcConfig.java" <<'EOF'
class WebMvcConfig {
    void addInterceptors(InterceptorRegistry registry) {
        registry.addInterceptor(appUserAuthInterceptor)
                .addPathPatterns("/api/**")
                .excludePathPatterns("/api/merchant/list", "/api/merchant/hot");
    }
}
EOF
cat >"$repo/src/main/java/com/bofan/modules/merchant/entity/AppMerchant.java" <<'EOF'
@TableName("app_merchant")
class AppMerchant {
    private Long finderId;
    private LocalDateTime editExpireTime;
    private Integer status;
    private Integer deleted;
}
EOF
cat >"$repo/src/main/java/com/bofan/modules/merchant/controller/AppMerchantController.java" <<'EOF'
@RestController
@RequestMapping("/api/merchant")
class AppMerchantController {
    @GetMapping("/list")
    Result<PageResult<PublicMerchantVO>> getMerchantList() {
        return null;
    }
}
EOF
git -C "$repo" add .
git -C "$repo" commit -qm base
python3 - "$repo/src/main/java/com/bofan/modules/merchant/controller/AppMerchantController.java" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text().replace('Result<PageResult<PublicMerchantVO>>', 'Result<PageResult<AppMerchant>>')
path.write_text(text)
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
marker='匿名商户读取接口直接返回持久化 AppMerchant 实体'
[[ "$(printf '%s\n' "$output" | grep -cF "$marker" || true)" == 1 ]] || {
  echo 'Bafan public entity preflight did not emit exactly one finding' >&2
  printf '%s\n' "$output" >&2
  exit 1
}
for field in '影响：' '修复建议：' '验证方式：' '证据行：'; do
  printf '%s\n' "$output" | grep -F "$field" >/dev/null || {
    echo "Bafan public entity preflight omitted $field" >&2
    exit 1
  }
done

cp -R "$repo" "$safe_repo"
python3 - "$safe_repo/src/main/java/com/bofan/modules/merchant/controller/AppMerchantController.java" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text().replace('Result<PageResult<AppMerchant>>', 'Result<PageResult<PublicMerchantVO>>')
path.write_text(text)
PY
safe_output="$(run_review "$safe_repo")"
if printf '%s\n' "$safe_output" | grep -F "$marker" >/dev/null; then
  echo 'Bafan public entity preflight reported DTO fixture' >&2
  printf '%s\n' "$safe_output" >&2
  exit 1
fi

cp -R "$repo" "$guarded_repo"
python3 - "$guarded_repo/src/main/java/com/bofan/common/config/WebMvcConfig.java" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text().replace('"/api/merchant/list", "/api/merchant/hot"', '"/api/user/wx-login"')
path.write_text(text)
PY
guarded_output="$(run_review "$guarded_repo")"
if printf '%s\n' "$guarded_output" | grep -F "$marker" >/dev/null; then
  echo 'Bafan public entity preflight reported authenticated fixture' >&2
  printf '%s\n' "$guarded_output" >&2
  exit 1
fi

echo 'Bafan public entity preflight regression passed'
