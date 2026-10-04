#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-actuator-metrics.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
repo="$fixture_root/repo"
safe_repo="$fixture_root/safe-repo"
fake_bin="$fixture_root/bin"
mkdir -p "$repo/src/main/java/example/config" "$repo/src/main/resources" "$fake_bin"

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name public-actuator-metrics-preflight

cat >"$repo/src/main/resources/application.yml" <<'EOF'
management:
  endpoints:
    web:
      exposure:
        include: health,info
EOF
cat >"$repo/src/main/java/example/config/WebMvcConfig.java" <<'EOF'
final class WebMvcConfig {
    void addInterceptors(Registry registry) {
        registry.addInterceptor(apiAuth).addPathPatterns("/api/**");
        registry.addInterceptor(adminAuth).addPathPatterns("/admin/**");
    }
}
EOF
cat >"$repo/pom.xml" <<'EOF'
<project><dependency><artifactId>spring-boot-starter-actuator</artifactId></dependency></project>
EOF
git -C "$repo" add .
git -C "$repo" commit -qm base

cat >"$repo/src/main/resources/application.yml" <<'EOF'
management:
  endpoints:
    web:
      exposure:
        include: health,info,metrics # metrics 仅用于受控运维访问
EOF
cat >"$repo/src/main/java/example/config/ThreadPoolConfig.java" <<'EOF'
final class ThreadPoolConfig {
    Object executorMetricsBinder() {
        return Gauge.builder("bafan.executor.queue.size", pool, value -> value.queueSize());
    }
}
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
  OLLAMA_REVIEW_TOTAL_TIMEOUT_SECONDS=120 \
  "$repo_root/bin/local-review.sh" --repo "$1"
}

output="$(run_review "$repo")"
marker='Actuator metrics 被暴露在业务应用端口'
[[ "$(printf '%s\n' "$output" | grep -cF "$marker" || true)" == 1 ]] || {
  echo 'public actuator metrics preflight did not emit exactly one finding' >&2
  printf '%s\n' "$output" >&2
  exit 1
}
for field in '影响：' '修复建议：' '验证方式：' '证据行：'; do
  printf '%s\n' "$output" | grep -F "$field" >/dev/null || {
    echo "public actuator metrics preflight omitted $field" >&2
    exit 1
  }
done

cp -R "$repo" "$safe_repo"
printf '%s\n' 'management.server.port: 9001' >>"$safe_repo/src/main/resources/application.yml"
safe_output="$(run_review "$safe_repo")"
if printf '%s\n' "$safe_output" | grep -F "$marker" >/dev/null; then
  echo 'public actuator metrics preflight reported separate management-port fixture' >&2
  printf '%s\n' "$safe_output" >&2
  exit 1
fi

echo 'public actuator metrics preflight regression passed'
