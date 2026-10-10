#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-java-login-code.XXXXXX")"
fake_bin="$fixture_root/bin"
repo="$fixture_root/repo"
trap 'rm -rf "$fixture_root"' EXIT
mkdir -p "$fake_bin" "$repo/src/main/java/testcases"

cat >"$fake_bin/ollama" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"未发现阻塞问题","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/ollama" "$fake_bin/curl"

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name java-login-code-preflight
git -C "$repo" commit --allow-empty -qm 基线

cat >"$repo/src/main/java/testcases/BadLoginController.java" <<'EOF'
package testcases;

class BadLoginController {
    @PostMapping("/login")
    Token login(LoginRequest loginDTO) {
        String code = loginDTO.getCode();
        String openId = code;
        return jwtService.createToken(openId);
    }
}
EOF
cat >"$repo/src/main/java/testcases/SafeLoginController.java" <<'EOF'
package testcases;

class SafeLoginController {
    @PostMapping("/login")
    Token login(LoginRequest loginDTO) {
        String openId = wechatClient.code2Session(loginDTO.getCode()).getOpenId();
        return jwtService.createToken(openId);
    }
}
EOF
cat >"$repo/src/main/java/testcases/BusinessCodeLoginController.java" <<'EOF'
package testcases;

class BusinessCodeLoginController {
    @PostMapping("/login-by-invite")
    Token login(LoginRequest loginDTO) {
        String userId = userDirectory.findUserIdByInviteCode(loginDTO.getCode());
        return jwtService.createToken(userId);
    }
}
EOF

output="$(PATH="$fake_bin:$PATH" TMPDIR="$fixture_root" \
  OLLAMA_REVIEW_LOCK_DIR="$fixture_root/lock" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_NUM_CTX=65536 OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
printf '%s\n' "$output" | grep -F '登录流程把客户端提交的 code 直接当作' >/dev/null
printf '%s\n' "$output" | grep -F 'BadLoginController.java:' >/dev/null
[[ "$(printf '%s\n' "$output" | grep -c '登录流程把客户端提交的 code 直接当作' || true)" -eq 1 ]]
for field in '影响：' '修复建议：' '验证方式：'; do
  [[ "$(printf '%s\n' "$output" | grep -cF "$field" || true)" -eq 1 ]]
done
if printf '%s\n' "$output" | grep -E 'SafeLoginController.java:|BusinessCodeLoginController.java:' >/dev/null; then
  echo 'server-side identity exchange or business-code lookup was incorrectly reported' >&2
  printf '%s\n' "$output" >&2
  exit 1
fi

echo 'Java external login-code preflight regression passed'
