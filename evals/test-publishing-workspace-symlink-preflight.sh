#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-publishing-symlink.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
repo="$fixture_root/repo"
safe_repo="$fixture_root/safe-repo"
fake_bin="$fixture_root/bin"
mkdir -p "$repo/src/main/java/com/bit/publishing/mcp/tool" "$fake_bin"

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name publishing-symlink-preflight

cat >"$repo/src/main/java/com/bit/publishing/mcp/tool/PublishingDocumentTools.java" <<'EOF'
final class PublishingDocumentTools {
    private final Path workspaceRoot = Path.of("/tmp/workspace");
}
EOF
cat >"$repo/src/main/java/com/bit/publishing/mcp/tool/PublishingMcpTools.java" <<'EOF'
final class PublishingMcpTools {
    private final Path workspaceRoot = Path.of("/tmp/workspace");
}
EOF
git -C "$repo" add .
git -C "$repo" commit -qm base

cat >"$repo/src/main/java/com/bit/publishing/mcp/tool/PublishingDocumentTools.java" <<'EOF'
import java.nio.file.Files;
import java.nio.file.Path;

final class PublishingDocumentTools {
    private final Path workspaceRoot = Path.of("/tmp/workspace");
    Path resolve(String relativePath) {
        Path path = workspaceRoot.resolve(relativePath).normalize();
        if (!path.startsWith(workspaceRoot)) throw new IllegalArgumentException();
        return path;
    }
    void inspect(String relativePath) throws Exception {
        Files.newInputStream(resolve(relativePath));
        new ProcessBuilder("soffice", resolve(relativePath).toString()).start();
    }
}
EOF
cat >"$repo/src/main/java/com/bit/publishing/mcp/tool/PublishingMcpTools.java" <<'EOF'
import java.nio.file.Files;
import java.nio.file.Path;

final class PublishingMcpTools {
    private final Path workspaceRoot = Path.of("/tmp/workspace");
    Path resolveInsideWorkspace(String relativePath) {
        Path candidate = workspaceRoot.resolve(relativePath).normalize();
        if (!candidate.startsWith(workspaceRoot)) throw new IllegalArgumentException();
        return candidate;
    }
    void create(String job) throws Exception { Files.createDirectories(resolveInsideWorkspace(job)); }
}
EOF

cat >"$fake_bin/ollama" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '{"response":"未发现阻塞问题","done":true,"done_reason":"stop"}'
EOF
chmod +x "$fake_bin/ollama" "$fake_bin/curl"

output="$(
  PATH="$fake_bin:$PATH" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  OLLAMA_REVIEW_NUM_CTX=65536 \
  OLLAMA_REVIEW_TOTAL_TIMEOUT_SECONDS=120 \
  "$repo_root/bin/local-review.sh" --repo "$repo"
)"
marker='出版 MCP 工作区只做词法路径归一化'
[[ "$(printf '%s\n' "$output" | grep -cF "$marker" || true)" == 1 ]] || {
  echo 'publishing symlink preflight did not emit exactly one finding' >&2
  printf '%s\n' "$output" >&2
  exit 1
}
printf '%s\n' "$output" | grep -F 'PublishingDocumentTools.java:' >/dev/null
printf '%s\n' "$output" | grep -F 'PublishingMcpTools.java:' >/dev/null

cp -R "$repo" "$safe_repo"
python3 - "$safe_repo/src/main/java/com/bit/publishing/mcp/tool/PublishingDocumentTools.java" "$safe_repo/src/main/java/com/bit/publishing/mcp/tool/PublishingMcpTools.java" <<'PY'
from pathlib import Path
import sys
for name in sys.argv[1:]:
    path = Path(name)
    text = path.read_text()
    text = text.replace('return path;', 'path = path.toRealPath();\n        return path;')
    text = text.replace('return candidate;', 'candidate = candidate.toRealPath();\n        return candidate;')
    text += '\n// Files.isSymbolicLink and NOFOLLOW_LINKS are used before file operations.\n'
    path.write_text(text)
PY
safe_output="$(
  PATH="$fake_bin:$PATH" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  OLLAMA_REVIEW_NUM_CTX=65536 \
  OLLAMA_REVIEW_TOTAL_TIMEOUT_SECONDS=120 \
  "$repo_root/bin/local-review.sh" --repo "$safe_repo"
)"
if printf '%s\n' "$safe_output" | grep -F "$marker" >/dev/null; then
  echo 'publishing symlink preflight reported the realpath-safe fixture' >&2
  printf '%s\n' "$safe_output" >&2
  exit 1
fi

echo 'publishing workspace symlink preflight regression passed'
