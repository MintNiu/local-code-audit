#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-http-job-ssrf.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
repo="$fixture_root/repo"
fake_bin="$fixture_root/bin"
mkdir -p "$repo/src/vulnerable" "$repo/src/safe" "$fake_bin"

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name http-job-ssrf-test
cat >"$repo/src/vulnerable/HttpJobHandler.java" <<'EOF'
final class HttpJobHandler {}
EOF
cat >"$repo/src/safe/HttpJobHandler.java" <<'EOF'
final class HttpJobHandler {}
EOF
git -C "$repo" add .
git -C "$repo" commit -qm base

cat >"$repo/src/vulnerable/HttpJobHandler.java" <<'EOF'
import org.apache.http.client.methods.HttpGet;

final class HttpJobHandler {
    ReturnT<String> execute(String param) throws Exception {
        if (param == null || param.trim().length() == 0) return FAIL;
        HttpGet httpGet = new HttpGet(param);
        CloseableHttpClient httpClient = HttpClients.createDefault();
        httpClient.execute(httpGet);
        return SUCCESS;
    }
}
EOF
cat >"$repo/src/safe/HttpJobHandler.java" <<'EOF'
import org.apache.http.client.methods.HttpGet;

final class HttpJobHandler {
    ReturnT<String> execute(String param) throws Exception {
        if (!isAllowedUrl(param)) return FAIL;
        HttpGet httpGet = new HttpGet(param);
        CloseableHttpClient httpClient = HttpClients.createDefault();
        httpClient.execute(httpGet);
        return SUCCESS;
    }

    private boolean isAllowedUrl(String param) {
        return param.startsWith("https://trusted.example/");
    }
}
EOF

cat >"$fake_bin/ollama" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
payload=""
previous=""
for argument in "$@"; do
  if [[ "$previous" == "--data-binary" && "$argument" == @* ]]; then
    payload="${argument#@}"
    break
  fi
  previous="$argument"
done
jq -e '.prompt' "$payload" >/dev/null
printf '%s\n' '{"response":"未发现阻塞问题","done":true,"done_reason":"stop"}'
EOF
chmod +x "$fake_bin/ollama" "$fake_bin/curl"

output="$(
  PATH="$fake_bin:$PATH" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  OLLAMA_REVIEW_TOTAL_TIMEOUT_SECONDS=120 \
  "$repo_root/bin/local-review.sh" --repo "$repo"
)"

vulnerable_count="$(printf '%s\n' "$output" | grep -c 'P1 src/vulnerable/HttpJobHandler.java:' || true)"
[[ "$vulnerable_count" == 1 ]] || {
  echo "expected one vulnerable HTTP job finding, got $vulnerable_count" >&2
  printf '%s\n' "$output" >&2
  exit 1
}
if grep -Fq 'src/safe/HttpJobHandler.java' <<<"$output"; then
  echo 'safe allowlisted HTTP job handler was reported' >&2
  printf '%s\n' "$output" >&2
  exit 1
fi
grep -F '服务端请求伪造（SSRF）风险' <<<"$output" >/dev/null
grep -F '直接 new HttpGet(param)' <<<"$output" >/dev/null

echo 'HTTP job SSRF preflight regression passed'
