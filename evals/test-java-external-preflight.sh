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

key_repo="$fixture_root/key-repo"
git -C "$fixture_root" init -q key-repo
git -C "$key_repo" config user.email test@example.invalid
git -C "$key_repo" config user.name java-hardcoded-key-preflight
git -C "$key_repo" commit --allow-empty -qm 基线
mkdir -p "$key_repo/src/main/java/testcases"
cat >"$key_repo/src/main/java/testcases/HardcodedKeyFixture.java" <<'EOF'
package testcases;

import javax.crypto.spec.SecretKeySpec;

class HardcodedKeyFixture {
    void bad() {
        String key = "0123456789abcdef";
        SecretKeySpec spec = new SecretKeySpec(key.getBytes(), "AES");
    }
}
EOF
key_output="$(PATH="$fake_bin:$PATH" TMPDIR="$fixture_root" \
  OLLAMA_REVIEW_LOCK_DIR="$fixture_root/lock-key" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_NUM_CTX=65536 OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$key_repo")"
printf '%s\n' "$key_output" | grep -F '加密密钥由源码中的非空字面量提供' >/dev/null

rm "$key_repo/src/main/java/testcases/HardcodedKeyFixture.java"
cat >"$key_repo/src/main/java/testcases/HardcodedKeyFixture.java" <<'EOF'
package testcases;

import javax.crypto.spec.SecretKeySpec;

class HardcodedKeyFixture {
    void safe() {
        String key = System.getenv("ENCRYPTION_KEY");
        SecretKeySpec spec = new SecretKeySpec(key.getBytes(), "AES");
    }
}
EOF
safe_key_output="$(PATH="$fake_bin:$PATH" TMPDIR="$fixture_root" \
  OLLAMA_REVIEW_LOCK_DIR="$fixture_root/lock-key-safe" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_NUM_CTX=65536 OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$key_repo")"
if printf '%s\n' "$safe_key_output" | grep -F '加密密钥由源码中的非空字面量提供' >/dev/null; then
  echo 'environment-injected crypto key was incorrectly reported as hardcoded' >&2
  printf '%s\n' "$safe_key_output" >&2
  exit 1
fi

weak_repo="$fixture_root/weak-repo"
git -C "$fixture_root" init -q weak-repo
git -C "$weak_repo" config user.email test@example.invalid
git -C "$weak_repo" config user.name java-weak-crypto-preflight
git -C "$weak_repo" commit --allow-empty -qm 基线
mkdir -p "$weak_repo/src/main/java/testcases"
cat >"$weak_repo/src/main/java/testcases/WeakCryptoFixture.java" <<'EOF'
package testcases;

import javax.crypto.Cipher;

class WeakCryptoFixture {
    void bad() throws Exception {
        Cipher.getInstance("DESede");
    }
}
EOF
weak_output="$(PATH="$fake_bin:$PATH" TMPDIR="$fixture_root" \
  OLLAMA_REVIEW_LOCK_DIR="$fixture_root/lock-weak" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_NUM_CTX=65536 OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$weak_repo")"
printf '%s\n' "$weak_output" | grep -F '已知风险或过时的加密算法' >/dev/null

rm "$weak_repo/src/main/java/testcases/WeakCryptoFixture.java"
cat >"$weak_repo/src/main/java/testcases/WeakCryptoFixture.java" <<'EOF'
package testcases;

import javax.crypto.Cipher;

class WeakCryptoFixture {
    void safe() throws Exception {
        // Example: Cipher.getInstance("DESede")
        Cipher.getInstance("AES/GCM/NoPadding");
    }
}
EOF
safe_weak_output="$(PATH="$fake_bin:$PATH" TMPDIR="$fixture_root" \
  OLLAMA_REVIEW_LOCK_DIR="$fixture_root/lock-weak-safe" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_NUM_CTX=65536 OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$weak_repo")"
if printf '%s\n' "$safe_weak_output" | grep -F '已知风险或过时的加密算法' >/dev/null; then
  echo 'modern AES algorithm was incorrectly reported as weak crypto' >&2
  printf '%s\n' "$safe_weak_output" >&2
  exit 1
fi

form_repo="$fixture_root/form-repo"
git -C "$fixture_root" init -q form-repo
git -C "$form_repo" config user.email test@example.invalid
git -C "$form_repo" config user.name java-password-form-preflight
git -C "$form_repo" commit --allow-empty -qm 基线
mkdir -p "$form_repo/src/main/java/testcases"
cat >"$form_repo/src/main/java/testcases/PasswordFormFixture.java" <<'EOF'
package testcases;

class PasswordFormFixture {
    // <form method="get">
    // <input name="password" type="text">
    void bad() {}
}
EOF
form_output="$(PATH="$fake_bin:$PATH" TMPDIR="$fixture_root" \
  OLLAMA_REVIEW_LOCK_DIR="$fixture_root/lock-form" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_NUM_CTX=65536 OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$form_repo")"
printf '%s\n' "$form_output" | grep -F '密码字段通过 GET 表单' >/dev/null

rm "$form_repo/src/main/java/testcases/PasswordFormFixture.java"
cat >"$form_repo/src/main/java/testcases/PasswordFormFixture.java" <<'EOF'
package testcases;

class PasswordFormFixture {
    // <form method="post">
    // <input name="password" type="text">
    void safe() {}
}
EOF
safe_form_output="$(PATH="$fake_bin:$PATH" TMPDIR="$fixture_root" \
  OLLAMA_REVIEW_LOCK_DIR="$fixture_root/lock-form-safe" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_NUM_CTX=65536 OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$form_repo")"
if printf '%s\n' "$safe_form_output" | grep -F '密码字段通过 GET 表单' >/dev/null; then
  echo 'POST password form was incorrectly reported as GET password form' >&2
  printf '%s\n' "$safe_form_output" >&2
  exit 1
fi

cookie_repo="$fixture_root/cookie-repo"
git -C "$fixture_root" init -q cookie-repo
git -C "$cookie_repo" config user.email test@example.invalid
git -C "$cookie_repo" config user.name java-cookie-preflight
git -C "$cookie_repo" commit --allow-empty -qm 基线
mkdir -p "$cookie_repo/src/main/java/testcases"
cat >"$cookie_repo/src/main/java/testcases/CookieFixture.java" <<'EOF'
package testcases;

import javax.servlet.http.Cookie;
import javax.servlet.http.HttpServletResponse;

class CookieFixture {
    void helper() {
        Cookie cookie = new Cookie("SessionToken", "x");
        cookie.setSecure(true);
    }

    void bad(HttpServletResponse response) {
        Cookie cookie = new Cookie("SessionToken", "x");
        response.addCookie(cookie);
    }
}
EOF
cookie_output="$(PATH="$fake_bin:$PATH" TMPDIR="$fixture_root" \
  OLLAMA_REVIEW_LOCK_DIR="$fixture_root/lock-cookie" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_NUM_CTX=65536 OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$cookie_repo")"
printf '%s\n' "$cookie_output" | grep -F '敏感 Cookie 未设置 Secure' >/dev/null

rm "$cookie_repo/src/main/java/testcases/CookieFixture.java"
cat >"$cookie_repo/src/main/java/testcases/CookieFixture.java" <<'EOF'
package testcases;

import javax.servlet.http.Cookie;
import javax.servlet.http.HttpServletResponse;

class CookieFixture {
    void safe(HttpServletResponse response) {
        Cookie cookie = new Cookie("SessionToken", "x");
        cookie.setSecure(true);
        response.addCookie(cookie);
    }
}
EOF
safe_cookie_output="$(PATH="$fake_bin:$PATH" TMPDIR="$fixture_root" \
  OLLAMA_REVIEW_LOCK_DIR="$fixture_root/lock-cookie-safe" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_NUM_CTX=65536 OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$cookie_repo")"
if printf '%s\n' "$safe_cookie_output" | grep -F '敏感 Cookie 未设置 Secure' >/dev/null; then
  echo 'Secure cookie was incorrectly reported as missing Secure' >&2
  printf '%s\n' "$safe_cookie_output" >&2
  exit 1
fi

resource_repo="$fixture_root/resource-repo"
git -C "$fixture_root" init -q resource-repo
git -C "$resource_repo" config user.email test@example.invalid
git -C "$resource_repo" config user.name java-resource-loop-preflight
git -C "$resource_repo" commit --allow-empty -qm 基线
mkdir -p "$resource_repo/src/main/java/testcases"
cat >"$resource_repo/src/main/java/testcases/ResourceLoopFixture.java" <<'EOF'
package testcases;

class ResourceLoopFixture {
    void bad() {
        String raw = System.getenv("COUNT");
        int count = Integer.parseInt(raw);
        for (int i = 0; i < count; i++) {
            work();
        }
    }

    private void work() {}
}
EOF
resource_output="$(PATH="$fake_bin:$PATH" TMPDIR="$fixture_root" \
  OLLAMA_REVIEW_LOCK_DIR="$fixture_root/lock-resource" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_NUM_CTX=65536 OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$resource_repo")"
printf '%s\n' "$resource_output" | grep -F '外部输入直接控制无上限循环' >/dev/null

rm "$resource_repo/src/main/java/testcases/ResourceLoopFixture.java"
cat >"$resource_repo/src/main/java/testcases/ResourceLoopFixture.java" <<'EOF'
package testcases;

class ResourceLoopFixture {
    void safe() {
        String raw = System.getenv("COUNT");
        int count = Integer.parseInt(raw);
        if (count > 0 && count <= 20) {
            for (int i = 0; i < count; i++) {
                work();
            }
        }
    }

    private void work() {}
}
EOF
safe_resource_output="$(PATH="$fake_bin:$PATH" TMPDIR="$fixture_root" \
  OLLAMA_REVIEW_LOCK_DIR="$fixture_root/lock-resource-safe" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_NUM_CTX=65536 OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$resource_repo")"
if printf '%s\n' "$safe_resource_output" | grep -F '外部输入直接控制无上限循环' >/dev/null; then
  echo 'bounded external loop was incorrectly reported as resource exhaustion' >&2
  printf '%s\n' "$safe_resource_output" >&2
  exit 1
fi

infinite_repo="$fixture_root/infinite-repo"
git -C "$fixture_root" init -q infinite-repo
git -C "$infinite_repo" config user.email test@example.invalid
git -C "$infinite_repo" config user.name java-infinite-loop-preflight
git -C "$infinite_repo" commit --allow-empty -qm 基线
mkdir -p "$infinite_repo/src/main/java/testcases"
cat >"$infinite_repo/src/main/java/testcases/InfiniteLoopFixture.java" <<'EOF'
package testcases;

class InfiniteLoopFixture {
    void bad() {
        int i = 0;
        do {
            i = (i + 1) % 256;
        } while (i >= 0);
    }
}
EOF
infinite_output="$(PATH="$fake_bin:$PATH" TMPDIR="$fixture_root" \
  OLLAMA_REVIEW_LOCK_DIR="$fixture_root/lock-infinite" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_NUM_CTX=65536 OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$infinite_repo")"
printf '%s\n' "$infinite_output" | grep -F '循环条件可由当前计数器更新证明永真' >/dev/null

rm "$infinite_repo/src/main/java/testcases/InfiniteLoopFixture.java"
cat >"$infinite_repo/src/main/java/testcases/InfiniteLoopFixture.java" <<'EOF'
package testcases;

class InfiniteLoopFixture {
    void safe() {
        int i = 0;
        do {
            if (i == 10) {
                break;
            }
            i = (i + 1) % 256;
        } while (i >= 0);
    }
}
EOF
safe_infinite_output="$(PATH="$fake_bin:$PATH" TMPDIR="$fixture_root" \
  OLLAMA_REVIEW_LOCK_DIR="$fixture_root/lock-infinite-safe" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_NUM_CTX=65536 OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$infinite_repo")"
if printf '%s\n' "$safe_infinite_output" | grep -F '循环条件可由当前计数器更新证明永真' >/dev/null; then
  echo 'loop with reachable break was incorrectly reported as infinite' >&2
  printf '%s\n' "$safe_infinite_output" >&2
  exit 1
fi

session_repo="$fixture_root/session-repo"
git -C "$fixture_root" init -q session-repo
git -C "$session_repo" config user.email test@example.invalid
git -C "$session_repo" config user.name java-session-expiration-preflight
git -C "$session_repo" commit --allow-empty -qm 基线
mkdir -p "$session_repo/src/main/java/testcases"
cat >"$session_repo/src/main/java/testcases/SessionFixture.java" <<'EOF'
package testcases;

import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpSession;

class SessionFixture {
    void bad(HttpServletRequest request) {
        HttpSession session = request.getSession(true);
        session.setMaxInactiveInterval(-1);
    }
}
EOF
session_output="$(PATH="$fake_bin:$PATH" TMPDIR="$fixture_root" \
  OLLAMA_REVIEW_LOCK_DIR="$fixture_root/lock-session" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_NUM_CTX=65536 OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$session_repo")"
printf '%s\n' "$session_output" | grep -F '会话被设置为永不过期' >/dev/null

rm "$session_repo/src/main/java/testcases/SessionFixture.java"
cat >"$session_repo/src/main/java/testcases/SessionFixture.java" <<'EOF'
package testcases;

import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpSession;

class SessionFixture {
    void safe(HttpServletRequest request) {
        HttpSession session = request.getSession(true);
        session.setMaxInactiveInterval(1800);
    }
}
EOF
safe_session_output="$(PATH="$fake_bin:$PATH" TMPDIR="$fixture_root" \
  OLLAMA_REVIEW_LOCK_DIR="$fixture_root/lock-session-safe" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_NUM_CTX=65536 OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$session_repo")"
if printf '%s\n' "$safe_session_output" | grep -F '会话被设置为永不过期' >/dev/null; then
  echo 'finite session timeout was incorrectly reported as never-expiring' >&2
  printf '%s\n' "$safe_session_output" >&2
  exit 1
fi

shutdown_repo="$fixture_root/shutdown-repo"
git -C "$fixture_root" init -q shutdown-repo
git -C "$shutdown_repo" config user.email test@example.invalid
git -C "$shutdown_repo" config user.name java-resource-shutdown-preflight
git -C "$shutdown_repo" commit --allow-empty -qm 基线
mkdir -p "$shutdown_repo/src/main/java/testcases"
cat >"$shutdown_repo/src/main/java/testcases/ShutdownFixture.java" <<'EOF'
package testcases;

import java.io.FileReader;

class ShutdownFixture {
    void bad() throws Exception {
        FileReader reader = new FileReader("input.txt");
        reader.read();
        reader.close();
    }
}
EOF
shutdown_output="$(PATH="$fake_bin:$PATH" TMPDIR="$fixture_root" \
  OLLAMA_REVIEW_LOCK_DIR="$fixture_root/lock-shutdown" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_NUM_CTX=65536 OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$shutdown_repo")"
printf '%s\n' "$shutdown_output" | grep -F '文件资源仅在成功路径关闭' >/dev/null

rm "$shutdown_repo/src/main/java/testcases/ShutdownFixture.java"
cat >"$shutdown_repo/src/main/java/testcases/ShutdownFixture.java" <<'EOF'
package testcases;

import java.io.FileReader;

class ShutdownFixture {
    void safe() throws Exception {
        FileReader reader = new FileReader("input.txt");
        try {
            reader.read();
        } finally {
            reader.close();
        }
    }
}
EOF
safe_shutdown_output="$(PATH="$fake_bin:$PATH" TMPDIR="$fixture_root" \
  OLLAMA_REVIEW_LOCK_DIR="$fixture_root/lock-shutdown-safe" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_NUM_CTX=65536 OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$shutdown_repo")"
if printf '%s\n' "$safe_shutdown_output" | grep -F '文件资源仅在成功路径关闭' >/dev/null; then
  echo 'finally-protected resource was incorrectly reported as leaked' >&2
  printf '%s\n' "$safe_shutdown_output" >&2
  exit 1
fi

lock_repo="$fixture_root/lock-repo"
git -C "$fixture_root" init -q lock-repo
git -C "$lock_repo" config user.email test@example.invalid
git -C "$lock_repo" config user.name java-lock-lifecycle-preflight
git -C "$lock_repo" commit --allow-empty -qm 基线
mkdir -p "$lock_repo/src/main/java/testcases"
cat >"$lock_repo/src/main/java/testcases/LockFixture.java" <<'EOF'
package testcases;

import java.util.concurrent.locks.ReentrantLock;

class LockFixture {
    private final ReentrantLock lock = new ReentrantLock();

    void bad() {
        lock.lock();
        work();
    }

    private void work() {}
}
EOF
lock_output="$(PATH="$fake_bin:$PATH" TMPDIR="$fixture_root" \
  OLLAMA_REVIEW_LOCK_DIR="$fixture_root/lock-lock" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_NUM_CTX=65536 OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$lock_repo")"
printf '%s\n' "$lock_output" | grep -F '锁获取后在当前方法内没有对应 unlock' >/dev/null

rm "$lock_repo/src/main/java/testcases/LockFixture.java"
cat >"$lock_repo/src/main/java/testcases/LockFixture.java" <<'EOF'
package testcases;

import java.util.concurrent.locks.ReentrantLock;

class LockFixture {
    private final ReentrantLock lock = new ReentrantLock();

    void safe() {
        lock.lock();
        try {
            work();
        } finally {
            lock.unlock();
        }
    }

    private void work() {}
}
EOF
safe_lock_output="$(PATH="$fake_bin:$PATH" TMPDIR="$fixture_root" \
  OLLAMA_REVIEW_LOCK_DIR="$fixture_root/lock-lock-safe" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_NUM_CTX=65536 OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$lock_repo")"
if printf '%s\n' "$safe_lock_output" | grep -F '锁获取后在当前方法内没有对应 unlock' >/dev/null; then
  echo 'finally-protected lock was incorrectly reported as leaked' >&2
  printf '%s\n' "$safe_lock_output" >&2
  exit 1
fi

echo 'Java external security preflight passed'
