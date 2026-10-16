#!/usr/bin/env bash
set -euo pipefail
umask 077

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-xxl-empty-token.XXXXXX")"
fixture_root="$(cd "$fixture_root" && pwd -P)"
cleanup() {
  local status=$?
  if [[ "$status" != 0 || "${XXL_PREFLIGHT_KEEP_ARTIFACTS:-0}" == 1 ]]; then
    printf 'XXL-JOB regression artifacts: %s\n' "$fixture_root" >&2
  else
    rm -rf "$fixture_root"
  fi
}
trap cleanup EXIT
# Never let inherited Git routing/configuration target a repository outside
# these freshly created fixtures. HOME and CODEX_HOME remain untouched.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR \
  GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_GRAFT_FILE \
  GIT_NAMESPACE GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS \
  GIT_TEMPLATE_DIR GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM \
  GIT_IMPLICIT_WORK_TREE GIT_PREFIX GIT_INTERNAL_SUPER_PREFIX \
  GIT_SHALLOW_FILE GIT_REPLACE_REF_BASE GIT_QUARANTINE_PATH
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
repo="$fixture_root/repo"
safe_repo="$fixture_root/safe-repo"
fake_bin="$fixture_root/bin"
results_dir="$fixture_root/results"
mkdir -p "$results_dir"
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
git -C "$repo" -c core.hooksPath=/dev/null -c commit.gpgSign=false commit -qm 'test：建立空令牌预检基线'

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
set -euo pipefail
printf 'ollama\t%s\n' "$*" >>"$FAKE_CALL_LOG"
[[ "${1:-}" == show ]] || { echo 'unexpected fake ollama command' >&2; exit 97; }
EOF
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
previous=""
url=""
request=""
for argument in "$@"; do
  if [[ "$previous" == "--data-binary" && "$argument" == @* ]]; then
    test -s "${argument#@}"
    request="${argument#@}"
  fi
  [[ "$argument" != http* ]] || url="$argument"
  previous="$argument"
done
printf 'curl\t%s\n' "$url" >>"$FAKE_CALL_LOG"
[[ "$url" == http://127.0.0.1:11434/api/generate && -n "$request" ]] || {
  echo 'unexpected fake curl request; no network transport exists in this stub' >&2
  exit 97
}
jq -e '.stream == false and (.prompt | type == "string")' "$request" >/dev/null
printf '%s\n' '{"response":"未发现阻塞问题","done":true,"done_reason":"stop"}'
EOF
chmod +x "$fake_bin/ollama" "$fake_bin/curl"

marker='XXL-JOB OpenAPI 令牌允许空默认值'
failed_cases=0
case_count=0
printf 'case\texpected\texit_code\tfindings\tfake_curl_calls\tfake_ollama_calls\tresult\n' >"$results_dir/summary.tsv"

run_case() {
  local name="$1" case_repo="$2" expected="$3"
  local case_dir="$results_dir/$name" status=0 count curl_calls ollama_calls result=PASS
  mkdir -p "$case_dir"
  : >"$case_dir/calls.tsv"
  env -u OLLAMA_REVIEW_THINK \
    PATH="$fake_bin:$PATH" \
    FAKE_CALL_LOG="$case_dir/calls.tsv" \
    LOCAL_REVIEW_REPORT_DIR="$case_dir/reports" \
    LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
    OLLAMA_HOST=http://127.0.0.1:11434 \
    OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
    OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
    OLLAMA_REVIEW_NUM_CTX=65536 \
    OLLAMA_REVIEW_NUM_PREDICT=4096 \
    OLLAMA_REVIEW_TOTAL_TIMEOUT_SECONDS=120 \
    OLLAMA_REVIEW_LOCK_DIR="$fixture_root/review.lock" \
    OLLAMA_REVIEW_TRACE_FILE="$case_dir/trace.tsv" \
    OLLAMA_REVIEW_RESOLVED_CHUNK_BYTES_FILE="$case_dir/budget.tsv" \
    OLLAMA_REVIEW_SPECIALIST_CHANNEL= \
    OLLAMA_REVIEW_JAVA_METHOD_SIDECAR=false \
    OLLAMA_REVIEW_RETRY_ATTEMPTS=0 \
    "$repo_root/bin/local-review.sh" --repo "$case_repo" \
    >"$case_dir/stdout.txt" 2>"$case_dir/stderr.txt" || status=$?
  printf '%s\n' "$status" >"$case_dir/exit-code.txt"
  count="$(grep -cF "$marker" "$case_dir/stdout.txt" || true)"
  curl_calls="$(awk -F '\t' '$1 == "curl" {count++} END {print count+0}' "$case_dir/calls.tsv")"
  ollama_calls="$(awk -F '\t' '$1 == "ollama" {count++} END {print count+0}' "$case_dir/calls.tsv")"
  [[ "$status" == 0 && "$curl_calls" == 1 && "$ollama_calls" == 1 ]] || result=FAIL
  if [[ "$expected" == finding ]]; then
    [[ "$count" == 1 ]] || result=FAIL
    grep -F 'src/main/resources/application.yml:' "$case_dir/stdout.txt" >/dev/null || result=FAIL
    grep -F 'nacos-config/platform-job.yml:' "$case_dir/stdout.txt" >/dev/null || result=FAIL
    if grep -F 'platform-job-dev.yml' "$case_dir/stdout.txt" >/dev/null; then result=FAIL; fi
  else
    [[ "$count" == 0 && "$(cat "$case_dir/stdout.txt")" == '未发现阻塞问题' ]] || result=FAIL
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$name" "$expected" "$status" "$count" "$curl_calls" "$ollama_calls" "$result" >>"$results_dir/summary.tsv"
  printf '%s %s (exit=%s findings=%s fake-curl=%s fake-ollama=%s)\n' \
    "$result" "$name" "$status" "$count" "$curl_calls" "$ollama_calls"
  if [[ "$result" == FAIL ]]; then
    failed_cases=$((failed_cases + 1))
    printf 'Full stdout/stderr for %s: %s\n' "$name" "$case_dir" >&2
    cat "$case_dir/stdout.txt" >&2
    cat "$case_dir/stderr.txt" >&2
  fi
  case_count=$((case_count + 1))
}

run_case empty-fallback "$repo" finding

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
run_case nonempty-fallback "$safe_repo" clean

# permitAll on health does not authorize the separate /api matcher. Exercise
# both authenticated and denyAll, without asking the fake model to find bugs.
for api_policy in authenticated denyAll; do
  case_repo="$fixture_root/api-$api_policy"
  cp -R "$repo" "$case_repo"
  cat >"$case_repo/xxl-job-admin/src/main/java/com/bit/job/config/PlatformJobSecurityConfig.java" <<EOF
package com.bit.job.config;

final class PlatformJobSecurityConfig {
    void configure() {
        http.authorizeHttpRequests(auth -> auth
                .requestMatchers("/api/**").$api_policy()
                .requestMatchers("/actuator/health").permitAll());
    }
}
EOF
  run_case "api-$api_policy-health-permit" "$case_repo" clean
done

# Spring Security uses the first matching rule, not any later permitAll.
case_repo="$fixture_root/prior-wildcard-auth"
cp -R "$repo" "$case_repo"
cat >"$case_repo/xxl-job-admin/src/main/java/com/bit/job/config/PlatformJobSecurityConfig.java" <<'EOF'
package com.bit.job.config;

final class PlatformJobSecurityConfig {
    void configure() {
        http.authorizeHttpRequests(auth -> auth
                .requestMatchers("/**").authenticated()
                .requestMatchers("/api/**").permitAll());
    }
}
EOF
run_case prior-wildcard-auth "$case_repo" clean

# Preserve the original isNotBlank comparison, but reject blank configuration
# first. A comment containing the same words must not create a real guard.
for guard_kind in actual conditional comment; do
  case_repo="$fixture_root/blank-guard-$guard_kind"
  cp -R "$repo" "$case_repo"
  controller="$case_repo/xxl-job-admin/src/main/java/com/xxl/job/admin/scheduler/openapi/OpenApiController.java"
  awk -v kind="$guard_kind" '
    /if \(StringTool.isNotBlank/ {
      if (kind == "conditional") print "        if (\"strict\".equals(accesstoken)) {"
      prefix = (kind == "comment" ? "        // " : "        ")
      print prefix "if (StringTool.isBlank(XxlJobAdminBootstrap.getInstance().getAccessToken())) {"
      print prefix "    return Response.ofFail(\"denied\");"
      print prefix "}"
      if (kind == "conditional") print "        }"
    }
    { print }
  ' "$controller" >"$case_repo/controller.tmp"
  mv "$case_repo/controller.tmp" "$controller"
  if [[ "$guard_kind" == actual ]]; then
    run_case blank-guard-rejects "$case_repo" clean
  elif [[ "$guard_kind" == conditional ]]; then
    run_case conditional-guard-still-open "$case_repo" finding
  else
    run_case commented-guard-still-open "$case_repo" finding
  fi
done

# The blank-token guard need not be the method's first statement. Existing
# request validation rejects bad POST/URI/body inputs before reaching it.
case_repo="$fixture_root/blank-guard-after-request-validation"
cp -R "$repo" "$case_repo"
cat >"$case_repo/xxl-job-admin/src/main/java/com/xxl/job/admin/scheduler/openapi/OpenApiController.java" <<'EOF'
package com.xxl.job.admin.scheduler.openapi;

import com.xxl.job.admin.scheduler.config.XxlJobAdminBootstrap;
import com.xxl.job.core.constant.Const;
import com.xxl.tool.core.StringTool;
import com.xxl.tool.response.Response;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.stereotype.Controller;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;

@Controller
final class OpenApiController {
    @RequestMapping("/api/{uri}")
    @XxlSso(login = false)
    Object api(HttpServletRequest request, String uri, String requestBody,
            @RequestHeader(Const.XXL_JOB_ACCESS_TOKEN) String accesstoken) {
        if (!"POST".equalsIgnoreCase(request.getMethod())) {
            return Response.ofFail("invalid request method");
        }
        if (StringTool.isBlank(uri)) {
            return Response.ofFail("invalid request uri");
        }
        if (StringTool.isBlank(requestBody)) {
            return Response.ofFail("invalid request body");
        }
        if (StringTool.isBlank(XxlJobAdminBootstrap.getInstance().getAccessToken())) {
            return Response.ofFail("denied");
        }
        if (StringTool.isNotBlank(XxlJobAdminBootstrap.getInstance().getAccessToken())
                && !XxlJobAdminBootstrap.getInstance().getAccessToken().equals(accesstoken)) {
            return "denied";
        }
        return "dispatch";
    }
}
EOF
run_case blank-guard-after-request-validation "$case_repo" clean

# An adjacent method's annotations cannot establish the current API contract.
case_repo="$fixture_root/adjacent-method-annotations"
cp -R "$repo" "$case_repo"
cat >"$case_repo/xxl-job-admin/src/main/java/com/xxl/job/admin/scheduler/openapi/OpenApiController.java" <<'EOF'
package com.xxl.job.admin.scheduler.openapi;

import com.xxl.job.admin.scheduler.config.XxlJobAdminBootstrap;
import com.xxl.job.core.constant.Const;
import com.xxl.tool.core.StringTool;
import org.springframework.stereotype.Controller;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;

@Controller
final class OpenApiController {
    @XxlSso(login = false) Object unrelated(@RequestHeader(Const.XXL_JOB_ACCESS_TOKEN) String value) { return value; }
    @RequestMapping("/api/{uri}")
    Object api(String accesstoken) {
        if (StringTool.isNotBlank(XxlJobAdminBootstrap.getInstance().getAccessToken())
                && !XxlJobAdminBootstrap.getInstance().getAccessToken().equals(accesstoken)) {
            return "denied";
        }
        return "dispatch";
    }
}
EOF
run_case adjacent-method-annotations "$case_repo" clean

# Annotation order on the same method does not remove its real evidence.
case_repo="$fixture_root/sso-before-request-mapping"
cp -R "$repo" "$case_repo"
controller="$case_repo/xxl-job-admin/src/main/java/com/xxl/job/admin/scheduler/openapi/OpenApiController.java"
awk '
  /@RequestMapping\("\/api\/\{uri\}"\)/ { print "    @XxlSso(login = false)" }
  /@XxlSso\(login = false\)/ { next }
  { print }
' "$controller" >"$case_repo/controller.tmp"
mv "$case_repo/controller.tmp" "$controller"
run_case sso-before-request-mapping "$case_repo" finding

printf 'XXL-JOB empty-token preflight: %s cases, %s failures\n' "$case_count" "$failed_cases"
[[ "$failed_cases" == 0 ]]
