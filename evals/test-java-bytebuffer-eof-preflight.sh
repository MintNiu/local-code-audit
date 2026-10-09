#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-java-bytebuffer-eof.XXXXXX")"
fake_bin="$fixture_root/bin"
trap 'rm -rf "$fixture_root"' EXIT
mkdir -p "$fake_bin"

cat >"$fake_bin/ollama" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"未发现阻塞问题","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/ollama" "$fake_bin/curl"

new_repo() {
  local repo="$1"
  mkdir -p "$repo/src/main/java/testcases"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name java-bytebuffer-eof-preflight
  git -C "$repo" commit --allow-empty -qm 基线
}

run_review() {
  local repo="$1"
  PATH="$fake_bin:$PATH" TMPDIR="$fixture_root" \
    OLLAMA_REVIEW_LOCK_DIR="$fixture_root/lock" \
    LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
    OLLAMA_REVIEW_NUM_CTX=65536 \
    OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
    OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
    OLLAMA_REVIEW_TOTAL_TIMEOUT_SECONDS=120 \
    "$repo_root/bin/local-review.sh" --repo "$repo"
}

bad_repo="$fixture_root/bad"
new_repo "$bad_repo"
cat >"$bad_repo/src/main/java/testcases/ByteBufferReader.java" <<'EOF'
package testcases;

import java.io.IOException;
import java.io.InputStream;
import java.nio.ByteBuffer;

class ByteBufferReader {
    private final ByteBuffer buf = ByteBuffer.allocate(16);

    int read(InputStream in, byte[] out) throws IOException {
        if (buf.position() >= buf.limit()) {
            buf.position(0);
            int n = in.read(buf.array());
            if (n == -1) {
                return -1;
            }
            buf.limit(n);
        }
        int count = Math.min(buf.remaining(), out.length);
        buf.get(out, 0, count);
        return count;
    }
}
EOF

bad_output="$(run_review "$bad_repo")"
printf '%s\n' "$bad_output" | grep -F 'ByteBuffer 读取底层 EOF 后未清空有效范围' >/dev/null
printf '%s\n' "$bad_output" | grep -F 'ByteBufferReader.java:' >/dev/null
printf '%s\n' "$bad_output" | grep -F '来源：确定性预检（代码证据，非模型原文）' >/dev/null

safe_repo="$fixture_root/safe"
new_repo "$safe_repo"
cat >"$safe_repo/src/main/java/testcases/ByteBufferReader.java" <<'EOF'
package testcases;

import java.io.IOException;
import java.io.InputStream;
import java.nio.ByteBuffer;

class ByteBufferReader {
    private final ByteBuffer buf = ByteBuffer.allocate(16);

    int read(InputStream in, byte[] out) throws IOException {
        if (buf.position() >= buf.limit()) {
            buf.position(0);
            int n = in.read(buf.array());
            if (n == -1) {
                buf.limit(0);
                return -1;
            }
            buf.limit(n);
        }
        int count = Math.min(buf.remaining(), out.length);
        buf.get(out, 0, count);
        return count;
    }
}
EOF

safe_output="$(run_review "$safe_repo")"
if printf '%s\n' "$safe_output" | grep -F 'ByteBuffer 读取底层 EOF 后未清空有效范围' >/dev/null; then
  echo 'safe ByteBuffer EOF handling was incorrectly reported' >&2
  printf '%s\n' "$safe_output" >&2
  exit 1
fi
printf '%s\n' "$safe_output" | grep -Fx '未发现阻塞问题' >/dev/null

clear_repo="$fixture_root/clear"
new_repo "$clear_repo"
cat >"$clear_repo/src/main/java/testcases/ByteBufferReader.java" <<'EOF'
package testcases;

import java.io.IOException;
import java.io.InputStream;
import java.nio.ByteBuffer;

class ByteBufferReader {
    private final ByteBuffer buf = ByteBuffer.allocate(16);

    int read(InputStream in, byte[] out) throws IOException {
        if (buf.position() >= buf.limit()) {
            buf.position(0);
            int n = in.read(buf.array());
            if (n == -1) {
                buf.clear();
                return -1;
            }
            buf.limit(n);
        }
        int count = Math.min(buf.remaining(), out.length);
        buf.get(out, 0, count);
        return count;
    }
}
EOF

clear_output="$(run_review "$clear_repo")"
printf '%s\n' "$clear_output" | grep -F 'ByteBuffer 读取底层 EOF 后未清空有效范围' >/dev/null

echo 'Java ByteBuffer EOF preflight regression passed'
