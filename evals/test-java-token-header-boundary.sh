#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-java-token-header.XXXXXX")"
fake_bin="$fixture_root/bin"
repo="$fixture_root/repo"
trap 'rm -rf "$fixture_root"' EXIT
export LOCAL_REVIEW_TEST_ENVELOPE="$fixture_root/response.json"
mkdir -p "$fake_bin" "$repo/src"

cat >"$fake_bin/ollama" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"P1 src/TokenProxy.java:12-15 - 将请求参数 token 直接放入 HTTP header X-Token，可能泄漏。\\n影响：如果 header 被日志、持久化或外部边界记录，会导致凭据泄漏。\\n修复建议：改用安全认证通道。\\n验证方式：检查日志和请求边界。","done":true,"done_reason":"stop"}\n' | tee "$LOCAL_REVIEW_TEST_ENVELOPE"
EOF
chmod +x "$fake_bin/ollama" "$fake_bin/curl"

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name java-token-header-boundary
git -C "$repo" commit --allow-empty -qm 基线

cat >"$repo/src/TokenProxy.java" <<'EOF'
package com.example.gateway;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;

public final class TokenProxy {
    private final HttpClient client = HttpClient.newHttpClient();

    public HttpResponse<String> forward(String token) throws Exception {
        HttpRequest request = HttpRequest.newBuilder(URI.create("https://internal.example/data"))
                .header("X-Token", token)
                .GET()
                .build();
        return client.send(request, HttpResponse.BodyHandlers.ofString());
    }
}
EOF

review() {
  PATH="$fake_bin:$PATH" TMPDIR="$fixture_root" \
    OLLAMA_REVIEW_LOCK_DIR="$fixture_root/lock" LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
    OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
    "$repo_root/bin/local-review.sh" --repo "$repo"
}

# The internal-only response is unsupported advice, not factual gold.
# Its valid structure/location still requires complete retention.
safe_output="$(review)"
expected_output="$(jq -r '.response' "$LOCAL_REVIEW_TEST_ENVELOPE")"
[[ "$safe_output" == "$expected_output" ]] || {
  echo 'internal header-only token candidate was changed or hidden' >&2
  printf '%s\n' "$safe_output" >&2
  exit 1
}

git -C "$repo" add src/TokenProxy.java
git -C "$repo" commit -qm safe
sed -i '' 's#https://internal.example/data#https://api.example.com/data#' "$repo/src/TokenProxy.java"
external_output="$(review)"
expected_output="$(jq -r '.response' "$LOCAL_REVIEW_TEST_ENVELOPE")"
[[ "$external_output" == "$expected_output" ]] || {
  echo 'external token header candidate was changed or hidden' >&2
  printf '%s\n' "$external_output" >&2
  exit 1
}

echo 'Java token-header boundary regression passed'
