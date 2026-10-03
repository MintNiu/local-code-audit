#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-publishing-ticket-token.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
repo="$fixture_root/repo"
safe_repo="$fixture_root/safe-repo"
fake_bin="$fixture_root/bin"
mkdir -p "$repo/src/main/java/com/bit/publishing/infrastructure/file" "$fake_bin"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name publishing-ticket-token-preflight

cat >"$repo/src/main/java/com/bit/publishing/infrastructure/file/PlatformFileWorkspaceClient.java" <<'EOF'
import java.net.URI;
import java.net.http.HttpRequest;

final class PlatformFileWorkspaceClient {
    void download(String ticketUrl, String token) {
        URI base = URI.create("https://file.internal.invalid");
        URI uri = resolveTicketUri(base, ticketUrl);
        HttpRequest request = HttpRequest.newBuilder(uri)
                .header("Accept", "application/octet-stream")
                .GET().build();
    }

    private URI resolveTicketUri(URI base, String ticketUrl) {
        URI candidate = URI.create(ticketUrl);
        if (!candidate.isAbsolute()) return base.resolve(ticketUrl);
        if ("https".equalsIgnoreCase(candidate.getScheme())) return candidate;
        throw new IllegalStateException("untrusted");
    }
}
EOF
git -C "$repo" add .
git -C "$repo" commit -qm base
python3 - "$repo/src/main/java/com/bit/publishing/infrastructure/file/PlatformFileWorkspaceClient.java" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
s = s.replace('.header("Accept", "application/octet-stream")',
              '.header("X-Gateway-Token", token)\n                .header("Accept", "application/octet-stream")')
p.write_text(s)
PY

cat >"$fake_bin/ollama" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"response":"未发现阻塞问题","done":true,"done_reason":"stop"}'
EOF
chmod +x "$fake_bin/ollama" "$fake_bin/curl"

output="$(PATH="$fake_bin:$PATH" LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 OLLAMA_REVIEW_NUM_CTX=65536 \
  OLLAMA_REVIEW_TOTAL_TIMEOUT_SECONDS=120 \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
marker='文件中心下载票据允许绝对 HTTPS 地址时'
[[ "$(printf '%s\n' "$output" | grep -cF "$marker" || true)" == 1 ]] || {
  echo 'publishing external-ticket token preflight did not emit exactly one finding' >&2
  printf '%s\n' "$output" >&2
  exit 1
}

cp -R "$repo" "$safe_repo"
python3 - "$safe_repo/src/main/java/com/bit/publishing/infrastructure/file/PlatformFileWorkspaceClient.java" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
s = s.replace('if ("https".equalsIgnoreCase(candidate.getScheme())) return candidate;',
              'if ("https".equalsIgnoreCase(candidate.getScheme())\n'
              '                && candidate.getHost().endsWith(".trusted.invalid")) return candidate;')
p.write_text(s)
PY
safe_output="$(PATH="$fake_bin:$PATH" LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 OLLAMA_REVIEW_NUM_CTX=65536 \
  OLLAMA_REVIEW_TOTAL_TIMEOUT_SECONDS=120 \
  "$repo_root/bin/local-review.sh" --repo "$safe_repo")"
if printf '%s\n' "$safe_output" | grep -F "$marker" >/dev/null; then
  echo 'publishing external-ticket token preflight reported the allowlisted safe fixture' >&2
  printf '%s\n' "$safe_output" >&2
  exit 1
fi

echo 'publishing external ticket token preflight regression passed'
