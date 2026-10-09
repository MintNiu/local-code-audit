#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-java-tls-verifier.XXXXXX")"
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
  mkdir -p "$repo/src/main/java/example"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name java-tls-hostname-verifier-preflight
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

unsafe_repo="$fixture_root/unsafe"
new_repo "$unsafe_repo"
cat >"$unsafe_repo/src/main/java/example/SSLNetworkModule.java" <<'EOF'
package example;

import javax.net.ssl.SSLSession;
import javax.net.ssl.SSLSocket;

class SSLNetworkModule {
    private javax.net.ssl.HostnameVerifier hostnameVerifier;

    void start(SSLSocket socket, String host) throws Exception {
        socket.startHandshake();
        SSLSession session = socket.getSession();
        if (hostnameVerifier != null) {
            hostnameVerifier.verify(host, session);
        }
    }
}
EOF
unsafe_output="$(run_review "$unsafe_repo")"
printf '%s\n' "$unsafe_output" | grep -F 'TLS HostnameVerifier.verify() 的布尔结果被忽略' >/dev/null
printf '%s\n' "$unsafe_output" | grep -F 'SSLNetworkModule.java:13' >/dev/null
printf '%s\n' "$unsafe_output" | grep -F '影响：' >/dev/null
printf '%s\n' "$unsafe_output" | grep -F '修复建议：' >/dev/null
printf '%s\n' "$unsafe_output" | grep -F '验证方式：' >/dev/null
[[ "$(printf '%s\n' "$unsafe_output" | grep -c 'TLS HostnameVerifier.verify() 的布尔结果被忽略' || true)" -eq 1 ]]

safe_repo="$fixture_root/safe"
new_repo "$safe_repo"
cat >"$safe_repo/src/main/java/example/SSLNetworkModule.java" <<'EOF'
package example;

import javax.net.ssl.SSLSession;
import javax.net.ssl.SSLSocket;

class SSLNetworkModule {
    private javax.net.ssl.HostnameVerifier hostnameVerifier;

    void start(SSLSocket socket, String host) throws Exception {
        socket.startHandshake();
        SSLSession session = socket.getSession();
        if (hostnameVerifier != null && !hostnameVerifier.verify(host, session)) {
            session.invalidate();
            socket.close();
            throw new javax.net.ssl.SSLPeerUnverifiedException(host);
        }
    }
}
EOF
safe_output="$(run_review "$safe_repo")"
if printf '%s\n' "$safe_output" | grep -F 'TLS HostnameVerifier.verify() 的布尔结果被忽略' >/dev/null; then
  echo 'checked HostnameVerifier result was incorrectly reported' >&2
  printf '%s\n' "$safe_output" >&2
  exit 1
fi
printf '%s\n' "$safe_output" | grep -Fx '未发现阻塞问题' >/dev/null

echo 'Java TLS HostnameVerifier preflight regression passed'
