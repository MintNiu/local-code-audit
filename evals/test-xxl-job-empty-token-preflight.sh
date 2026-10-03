#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-xxl-empty-token.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
repo="$fixture_root/repo"
safe_repo="$fixture_root/safe-repo"
fake_bin="$fixture_root/bin"
mkdir -p "$repo/xxl-job-admin/src/main/java/com/xxl/job/admin/scheduler/openapi" \
  "$repo/xxl-job-admin/src/main/java/com/bit/job/config" \
  "$repo/xxl-job-admin/src/main/resources" "$repo/xxl-job-admin/nacos-config" "$fake_bin"

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name xxl-empty-token-preflight

cat >"$repo/xxl-job-admin/src/main/java/com/xxl/job/admin/scheduler/openapi/OpenApiController.java" <<'EOF'
package com.xxl.job.admin.scheduler.openapi;

import com.xxl.job.admin.scheduler.config.XxlJobAdminBootstrap;
import com.xxl.job.core.constant.Const;
import com.xxl.tool.core.StringTool;
import org.springframework.stereotype.Controller;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;

@Controller
final class OpenApiController {
    @RequestMapping("/api/{uri}")
    @XxlSso(login = false)
    Object api(@RequestHeader(Const.XXL_JOB_ACCESS_TOKEN) String accesstoken) {
        if (StringTool.isNotBlank(XxlJobAdminBootstrap.getInstance().getAccessToken())
                && !XxlJobAdminBootstrap.getInstance().getAccessToken().equals(accesstoken)) {
            return "denied";
        }
        return "dispatch";
    }
}
EOF
cat >"$repo/xxl-job-admin/src/main/java/com/bit/job/config/PlatformJobSecurityConfig.java" <<'EOF'
package com.bit.job.config;

final class PlatformJobSecurityConfig {
    void configure() {
        http.authorizeHttpRequests(auth -> auth
                .requestMatchers("/api/**", "/actuator/health").permitAll());
    }
}
EOF
cat >"$repo/xxl-job-admin/src/main/resources/application.yml" <<'EOF'
xxl:
  job:
    accessToken: ${XXL_JOB_ACCESS_TOKEN:old-token}
EOF
cat >"$repo/xxl-job-admin/nacos-config/platform-job.yml" <<'EOF'
xxl:
  job:
    accessToken: ${XXL_JOB_ACCESS_TOKEN:old-token}
EOF
cat >"$repo/xxl-job-admin/nacos-config/platform-job-dev.yml" <<'EOF'
xxl:
  job:
    accessToken: ${XXL_JOB_ACCESS_TOKEN:old-token}
EOF
git -C "$repo" add .
git -C "$repo" commit -qm base

cat >"$repo/xxl-job-admin/src/main/resources/application.yml" <<'EOF'
xxl:
  job:
    accessToken: ${XXL_JOB_ACCESS_TOKEN:}
EOF
cat >"$repo/xxl-job-admin/nacos-config/platform-job.yml" <<'EOF'
xxl:
  job:
    accessToken: ${XXL_JOB_ACCESS_TOKEN:${GATEWAY_INTERNAL_TOKEN:}}
EOF
cat >"$repo/xxl-job-admin/nacos-config/platform-job-dev.yml" <<'EOF'
xxl:
  job:
    accessToken: ${XXL_JOB_ACCESS_TOKEN:configured-dev-token}
EOF

cat >"$fake_bin/ollama" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
previous=""
for argument in "$@"; do
  if [[ "$previous" == "--data-binary" && "$argument" == @* ]]; then
    test -s "${argument#@}"
  fi
  previous="$argument"
done
printf '%s\n' '{"response":"未发现阻塞问题","done":true,"done_reason":"stop"}'
EOF
chmod +x "$fake_bin/ollama" "$fake_bin/curl"

output="$(
  PATH="$fake_bin:$PATH" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  OLLAMA_REVIEW_NUM_CTX=65536 \
  OLLAMA_REVIEW_TOTAL_TIMEOUT_SECONDS=120 \
  "$repo_root/bin/local-review.sh" --repo "$repo"
)"
marker='XXL-JOB OpenAPI 令牌允许空默认值'
[[ "$(printf '%s\n' "$output" | grep -cF "$marker" || true)" == 1 ]] || {
  echo 'empty-token preflight did not emit exactly one finding' >&2
  printf '%s\n' "$output" >&2
  exit 1
}
printf '%s\n' "$output" | grep -F 'src/main/resources/application.yml:' >/dev/null
printf '%s\n' "$output" | grep -F 'nacos-config/platform-job.yml:' >/dev/null
if printf '%s\n' "$output" | grep -F 'platform-job-dev.yml' >/dev/null; then
  echo 'empty-token preflight incorrectly included non-empty dev fallback' >&2
  printf '%s\n' "$output" >&2
  exit 1
fi

cp -R "$repo" "$safe_repo"
cat >"$safe_repo/xxl-job-admin/src/main/resources/application.yml" <<'EOF'
xxl:
  job:
    accessToken: ${XXL_JOB_ACCESS_TOKEN:configured-token}
EOF
cat >"$safe_repo/xxl-job-admin/nacos-config/platform-job.yml" <<'EOF'
xxl:
  job:
    accessToken: ${XXL_JOB_ACCESS_TOKEN:${GATEWAY_INTERNAL_TOKEN:configured-token}}
EOF
safe_output="$(
  PATH="$fake_bin:$PATH" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  OLLAMA_REVIEW_NUM_CTX=65536 \
  OLLAMA_REVIEW_TOTAL_TIMEOUT_SECONDS=120 \
  "$repo_root/bin/local-review.sh" --repo "$safe_repo"
)"
if printf '%s\n' "$safe_output" | grep -F "$marker" >/dev/null; then
  echo 'empty-token preflight reported non-empty safe fallback' >&2
  printf '%s\n' "$safe_output" >&2
  exit 1
fi

echo 'XXL-JOB empty-token preflight regression passed'
