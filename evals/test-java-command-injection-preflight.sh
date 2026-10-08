#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-java-command.XXXXXX")"
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
git -C "$repo" config user.name java-command-injection-preflight
git -C "$repo" commit --allow-empty -qm 基线

cat >"$repo/src/main/java/testcases/CommandFixture.java" <<'EOF'
package testcases;

class CommandFixture {
    void bad(javax.servlet.http.HttpServletRequest request) throws Exception {
        String command = request.getParameter("command");
        Runtime.getRuntime().exec(command);
    }

    void safeConstant() throws Exception {
        new ProcessBuilder("git", "status").start();
    }

    void safeConfiguration() throws Exception {
        String command = System.getenv("FIXED_COMMAND");
        new ProcessBuilder(command).start();
    }
}
EOF


output="$(PATH="$fake_bin:$PATH" TMPDIR="$fixture_root" \
  OLLAMA_REVIEW_LOCK_DIR="$fixture_root/lock" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_NUM_CTX=65536 OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
printf '%s\n' "$output" | grep -F '不可信请求输入进入 Runtime.exec/ProcessBuilder 动态命令' >/dev/null
printf '%s\n' "$output" | grep -F 'CommandFixture.java:6' >/dev/null
[[ "$(printf '%s\n' "$output" | grep -c '不可信请求输入进入 Runtime.exec/ProcessBuilder 动态命令' || true)" -eq 1 ]]
for field in '影响：' '修复建议：' '验证方式：'; do
  [[ "$(printf '%s\n' "$output" | grep -cF "$field" || true)" -eq 1 ]]
done
if printf '%s\n' "$output" | grep -F 'CommandFixture.java:10' >/dev/null || \
   printf '%s\n' "$output" | grep -F 'CommandFixture.java:15' >/dev/null; then
  echo 'safe command variants were incorrectly reported' >&2
  printf '%s\n' "$output" >&2
  exit 1
fi

echo 'Java command-injection preflight regression passed'
