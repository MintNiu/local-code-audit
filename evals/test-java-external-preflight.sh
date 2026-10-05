#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-java-external.XXXXXX")"
fake_bin="$fixture_root/bin"
repo="$fixture_root/repo"
trap 'rm -rf "$fixture_root"' EXIT
mkdir -p "$fake_bin" "$repo"

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
git -C "$repo" config user.name java-external-preflight
git -C "$repo" commit --allow-empty -qm 基线

mkdir -p "$repo/src/test/java/testcases"
cat >"$repo/src/test/java/testcases/OpenRedirectFixture.java" <<'EOF'
package testcases;

import java.io.BufferedReader;
import javax.servlet.http.HttpServletResponse;

class OpenRedirectFixture extends AbstractTestCaseServlet {
    void bad(HttpServletResponse response, BufferedReader reader) throws Exception {
        String data = reader.readLine();
        response.sendRedirect(data);
    }
}
EOF

output="$(PATH="$fake_bin:$PATH" TMPDIR="$fixture_root" \
  OLLAMA_REVIEW_LOCK_DIR="$fixture_root/lock" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_NUM_CTX=65536 OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
printf '%s\n' "$output" | grep -F 'P1 src/test/java/testcases/OpenRedirectFixture.java:' >/dev/null
printf '%s\n' "$output" | grep -F '开放重定向' >/dev/null

rm "$repo/src/test/java/testcases/OpenRedirectFixture.java"
cat >"$repo/src/test/java/testcases/OpenRedirectFixture.java" <<'EOF'
package testcases;

import javax.servlet.http.HttpServletResponse;

class OpenRedirectFixture extends AbstractTestCaseServlet {
    void safe(HttpServletResponse response) throws Exception {
        String data = "fixed";
        response.sendRedirect(data);
    }
}
EOF

safe_output="$(PATH="$fake_bin:$PATH" TMPDIR="$fixture_root" \
  OLLAMA_REVIEW_LOCK_DIR="$fixture_root/lock-safe" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_NUM_CTX=65536 OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
if printf '%s\n' "$safe_output" | grep -F '开放重定向' >/dev/null; then
  echo 'fixed redirect was incorrectly reported by external preflight' >&2
  printf '%s\n' "$safe_output" >&2
  exit 1
fi

password_repo="$fixture_root/password-repo"
git -C "$fixture_root" init -q password-repo
git -C "$password_repo" config user.email test@example.invalid
git -C "$password_repo" config user.name java-password-preflight
git -C "$password_repo" commit --allow-empty -qm 基线
mkdir -p "$password_repo/src/main/java/testcases"
cat >"$password_repo/src/main/java/testcases/HardcodedPasswordFixture.java" <<'EOF'
package testcases;

import java.sql.DriverManager;

class HardcodedPasswordFixture {
    void bad() throws Exception {
        String data = "secret123";
        DriverManager.getConnection("jdbc:test", "root", data);
    }
}
EOF
password_output="$(PATH="$fake_bin:$PATH" TMPDIR="$fixture_root" \
  OLLAMA_REVIEW_LOCK_DIR="$fixture_root/lock-password" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_NUM_CTX=65536 OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$password_repo")"
printf '%s\n' "$password_output" | grep -F 'Java 数据库连接使用硬编码密码' >/dev/null
printf '%s\n' "$password_output" | grep -F 'HardcodedPasswordFixture.java:7,8' >/dev/null

rm "$password_repo/src/main/java/testcases/HardcodedPasswordFixture.java"
cat >"$password_repo/src/main/java/testcases/HardcodedPasswordFixture.java" <<'EOF'
package testcases;

import java.sql.DriverManager;

class HardcodedPasswordFixture {
    void safe() throws Exception {
        String data = System.getenv("DB_PASSWORD");
        DriverManager.getConnection("jdbc:test", "root", data);
    }
}
EOF
safe_password_output="$(PATH="$fake_bin:$PATH" TMPDIR="$fixture_root" \
  OLLAMA_REVIEW_LOCK_DIR="$fixture_root/lock-password-safe" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_NUM_CTX=65536 OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$password_repo")"
if printf '%s\n' "$safe_password_output" | grep -F 'Java 数据库连接使用硬编码密码' >/dev/null; then
  echo 'environment-injected database password was incorrectly reported' >&2
  printf '%s\n' "$safe_password_output" >&2
  exit 1
fi

echo 'Java external security preflight passed'
