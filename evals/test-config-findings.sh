#!/usr/bin/env bash
set -euo pipefail

# Test report retention, not model accuracy. Fake responses keep this suite
# independent of Ollama, private examples, and the large preflight fixture.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-config-findings.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
repo="$fixture_root/repo"
fake_bin="$fixture_root/bin"
mkdir -p "$repo" "$fake_bin"

export LOCAL_REVIEW_EXAMPLES_FILE=/dev/null
export OLLAMA_REVIEW_MODEL=config-retention-fixture
export OLLAMA_REVIEW_MAX_DIFF_BYTES=60000
export OLLAMA_REVIEW_NUM_CTX=65536
export OLLAMA_REVIEW_RETRY_ATTEMPTS=0
export LOCAL_REVIEW_TEST_RESPONSE="$fixture_root/response.txt"

cat >"$fake_bin/ollama" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
exec jq -n --rawfile response "$LOCAL_REVIEW_TEST_RESPONSE" \
  '{response: $response, done: true, done_reason: "stop"}'
EOF
chmod +x "$fake_bin/ollama" "$fake_bin/curl"
export PATH="$fake_bin:$PATH"

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name config-findings-test
cat >"$repo/application.yml" <<'EOF'
# The listener accepts ports from 1 to 65535 inclusive.
port: 8080
timeout-seconds: 30
EOF
cat >"$repo/Listener.java" <<'EOF'
final class Listener {
    static void validatePort(int port) {
        if (port < 1 || port > 65535) {
            throw new IllegalArgumentException("port out of range");
        }
    }
}
EOF
printf '%s\n' 'legacy placeholder' >"$repo/legacy.txt"
git -C "$repo" add application.yml Listener.java legacy.txt
git -C "$repo" commit -qm base
cat >"$repo/application.yml" <<'EOF'
# The listener accepts ports from 1 to 65535 inclusive.
port: 70000
timeout-seconds: 0
EOF
cat >"$repo/new-settings.yml" <<'EOF'
# The listener accepts ports from 1 to 65535 inclusive.
port: 70000
EOF

failures=0
cases=0
run_case() {
  local name="$1" expected="$2" status=0
  local output="$fixture_root/$name.out" error="$fixture_root/$name.err"
  cases=$((cases + 1))
  cat >"$LOCAL_REVIEW_TEST_RESPONSE"
  "$repo_root/bin/local-review.sh" --repo "$repo" >"$output" 2>"$error" || status=$?
  if [[ "$expected" == "retain" ]]; then
    if [[ "$status" != 0 ]] || ! cmp -s "$LOCAL_REVIEW_TEST_RESPONSE" "$output"; then
      printf 'FAIL %s: finding changed or hidden (exit=%s)\n' "$name" "$status" >&2
      cat "$output" "$error" >&2
      failures=$((failures + 1))
    fi
  elif [[ "$status" == 0 ]]; then
    printf 'FAIL %s: invalid finding was accepted as complete\n' "$name" >&2
    cat "$output" >&2
    failures=$((failures + 1))
  elif ! grep -F '本地代码审查失败' "$error" >/dev/null; then
    printf 'FAIL %s: missing explicit failure diagnostic\n' "$name" >&2
    cat "$error" >&2
    failures=$((failures + 1))
  fi
}

# "可能" describes the consequence, not whether the illegal value is real.
# No bypass word such as "明确契约" should be required to retain the finding.
run_case changed-port retain <<'EOF'
P1 application.yml:2 - 端口由 8080 改为 70000，超过 Listener.java 接受的 1..65535 范围。
影响：监听器校验会拒绝该值，服务可能启动失败。
修复建议：使用合法范围内的端口。
验证方式：将配置值传给 Listener.validatePort，检查边界与非法输入。
EOF
run_case new-port retain <<'EOF'
P1 new-settings.yml:2 - 端口配置为 70000，超过 Listener.java 接受的 1..65535 范围。
影响：监听器校验会拒绝该值，服务可能启动失败。
修复建议：使用合法范围内的端口。
验证方式：将配置值传给 Listener.validatePort，检查边界与非法输入。
EOF
run_case explicit-contract retain <<'EOF'
P1 application.yml:2 - 端口配置与项目明确契约不一致。
影响：该值可能导致监听器启动失败。
修复建议：将端口改为 1..65535 范围内的值。
验证方式：执行配置加载和端口校验测试。
EOF
# Wording alone cannot establish truth. Preserve structurally valid
# candidates for independent verification, even if they may be false positives.
run_case speculative-candidate retain <<'EOF'
P2 application.yml:3 - 超时默认值改变，如果部署环境依赖旧值可能导致请求失败。
影响：是否影响请求仍需确认部署参数。
修复建议：先核对调用方的等待策略。
验证方式：在目标环境验证配置与请求超时行为。
EOF
run_case unknown-path reject <<'EOF'
P1 missing.yml:2 - 端口默认值可能导致启动失败。
影响：如果部署使用该值，服务无法启动。
修复建议：核对配置。
验证方式：执行启动测试。
EOF
run_case out-of-range reject <<'EOF'
P1 application.yml:999 - 端口默认值可能导致启动失败。
影响：如果部署使用该值，服务无法启动。
修复建议：核对配置。
验证方式：执行启动测试。
EOF
run_case incomplete-fields reject <<'EOF'
P1 application.yml:2 - 端口默认值可能导致启动失败。
EOF
git -C "$repo" rm -q legacy.txt
run_case deleted-file-without-current-line retain <<'EOF'
信息 legacy.txt - 删除了历史占位文件，需确认部署或脚本仍不依赖该路径。
影响：如果外部流程仍读取该文件，删除后可能导致发布或初始化失败。
修复建议：确认所有消费者已迁移到替代文件或明确记录删除契约。
验证方式：在全新检出和升级路径分别执行部署脚本，确认没有读取该文件的步骤。
EOF

[[ "$failures" == 0 ]] || {
  printf 'configuration finding regression failed: %s/%s\n' "$failures" "$cases" >&2
  exit 1
}
printf 'configuration finding regression passed: %s cases\n' "$cases"
