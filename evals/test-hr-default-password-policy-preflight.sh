#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-hr-default-password-policy.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
repo="$fixture_root/repo"
safe_repo="$fixture_root/safe-repo"
fake_bin="$fixture_root/bin"
mkdir -p "$repo/src/main/java/com/bit/system/application" "$fake_bin"

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name hr-default-password-policy-preflight

cat >"$repo/src/main/java/com/bit/system/application/HrAccountProjectionApplication.java" <<'EOF'
package com.bit.system.application;

final class HrAccountProjectionApplication {
    void project() {
        // existing projection path
    }
}
EOF
cat >"$repo/README.md" <<'EOF'
# HR projection

当前账号模型没有首次登录强制改密标记。
EOF
git -C "$repo" add .
git -C "$repo" commit -qm base

sed -i '' '/final class HrAccountProjectionApplication {/a\
    private static final String DEFAULT_PASSWORD_HASH_KEY = "platform.hr-projection.default-password-hash";
' "$repo/src/main/java/com/bit/system/application/HrAccountProjectionApplication.java"

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
  OLLAMA_REVIEW_MAX_DIFF_BYTES=12000 \
  OLLAMA_REVIEW_TOTAL_TIMEOUT_SECONDS=120 \
  "$repo_root/bin/local-review.sh" --repo "$1"
}

marker='HR 投影账号使用共享初始密码哈希'
output="$(run_review "$repo")"
count="$(printf '%s\n' "$output" | grep -cF "$marker" || true)"
[[ "$count" == 1 ]] || {
  echo "HR default-password preflight expected one finding, got $count" >&2
  printf '%s\n' "$output" >&2
  exit 1
}
printf '%s\n' "$output" | grep -F 'P1（有条件）' >/dev/null
for field in '影响：' '修复建议：' '验证方式：'; do
  printf '%s\n' "$output" | grep -F "$field" >/dev/null || {
    echo "HR default-password preflight omitted $field" >&2
    exit 1
  }
done

cp -R "$repo" "$safe_repo"
sed -i '' 's/没有首次登录强制改密标记/已有首次登录强制改密标记/' \
  "$safe_repo/README.md"
safe_output="$(run_review "$safe_repo")"
if printf '%s\n' "$safe_output" | grep -F "$marker" >/dev/null; then
  echo 'HR default-password preflight reported safe forced-change fixture' >&2
  printf '%s\n' "$safe_output" >&2
  exit 1
fi

echo 'HR default-password policy preflight regression passed'
