#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-publishing-mcp-scope.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
repo="$fixture_root/repo"
safe_repo="$fixture_root/safe-repo"
fake_bin="$fixture_root/bin"
mkdir -p "$repo/src/main/java/com/bit/publishing/mcp/tool" "$fake_bin"

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name publishing-mcp-scope-preflight

cat >"$repo/README.md" <<'EOF'
MCP HTTP is protected by the common filter and requires X-Gateway-Token.
EOF
cat >"$repo/src/main/java/com/bit/publishing/mcp/tool/PublishingMcpTools.java" <<'EOF'
final class PublishingMcpTools {
    private final Path workspaceRoot = Path.of("/tmp/workspace");
    @McpTool(name = "publishing_create_job_workspace")
    WorkspaceResult createJobWorkspace(String jobNo) throws IOException {
        Path root = workspaceRoot.resolve(jobNo).normalize();
        Files.createDirectories(root.resolve("input"));
        return null;
    }
}
EOF
cat >"$repo/src/main/java/com/bit/publishing/mcp/tool/PublishingDocumentTools.java" <<'EOF'
final class PublishingDocumentTools {
    private final Path workspaceRoot = Path.of("/tmp/workspace");
    DocxInspection inspectDocx(String relativePath) throws IOException {
        Path input = resolveExisting(relativePath, ".docx");
        Files.newInputStream(input);
        return null;
    }
    void applyDocxProfile(String inputRelativePath, String outputRelativePath) throws IOException {
        Files.newOutputStream(resolveGeneratedOutput(outputRelativePath, ".docx"));
    }
    void renderDocxToPdf(String inputRelativePath, String outputDirectory) throws IOException {
        Files.createDirectories(resolveOutputDirectory(outputDirectory));
        new ProcessBuilder("soffice").start();
    }
}
EOF
git -C "$repo" add .
git -C "$repo" commit -qm base

# Put the tool declarations into the diff so the path-accurate preflight is
# exercised, while the current snapshot still contains the vulnerable sink.
python3 - "$repo/src/main/java/com/bit/publishing/mcp/tool/PublishingMcpTools.java" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
text = text.replace(
    '    WorkspaceResult createJobWorkspace(String jobNo) throws IOException {\n',
    '    @McpTool(name = "publishing_create_job_workspace")\n'
    '    // added MCP workspace tool declaration\n'
    '    WorkspaceResult createJobWorkspace(String jobNo) throws IOException {\n',
)
path.write_text(text)
PY

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
marker='出版 MCP 文件工具只有共享网关令牌认证'
[[ "$(printf '%s\n' "$output" | grep -cF "$marker" || true)" == 1 ]] || {
  echo 'publishing MCP job-scope preflight did not emit exactly one finding' >&2
  printf '%s\n' "$output" >&2
  exit 1
}
printf '%s\n' "$output" | grep -F 'PublishingMcpTools.java:' >/dev/null

cp -R "$repo" "$safe_repo"
python3 - "$safe_repo/src/main/java/com/bit/publishing/mcp/tool/PublishingMcpTools.java" "$safe_repo/src/main/java/com/bit/publishing/mcp/tool/PublishingDocumentTools.java" <<'PY'
from pathlib import Path
import sys

mcp_path, document_path = map(Path, sys.argv[1:])
mcp = mcp_path.read_text()
mcp = mcp.replace(
    'Path root = workspaceRoot.resolve(jobNo).normalize();\n',
    'var grant = grantService.authorize(executionGrant, "publishing_create_job_workspace");\n'
    '        Path root = workspaceRoot.resolve(jobNo).normalize();\n',
)
mcp += '''
// An unrelated helper must not suppress the guarded workspace method.
private final PublishingExecutionGrantService grantService = null;
private final PublishingWorkspaceService workspaceService = null;
void unrelatedGrantHelper() {
    var unrelated = grantService.authorize(executionGrant, "unrelated");
}
'''
mcp_path.write_text(mcp)

document = document_path.read_text()
document = document.replace(
    'Path input = resolveExisting(relativePath, ".docx");\n',
    'var grant = grantService.authorize(executionGrant, "publishing_inspect_docx");\n'
    '        Path input = resolveExisting(relativePath, ".docx");\n',
)
document += '''
private final PublishingExecutionGrantService grantService = null;
private final PublishingWorkspaceService workspaceService = null;
'''
document_path.write_text(document)
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
  echo 'publishing MCP job-scope preflight reported the grant-authorized safe fixture' >&2
  printf '%s\n' "$safe_output" >&2
  exit 1
fi

echo 'publishing MCP job scope preflight regression passed'
