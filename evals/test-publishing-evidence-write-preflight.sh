#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-publishing-evidence.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
repo="$fixture_root/repo"
safe_repo="$fixture_root/safe-repo"
fake_bin="$fixture_root/bin"
mkdir -p "$repo/src/main/java/com/bit/publishing/controller/job" \
  "$repo/src/main/java/com/bit/publishing/application/job" "$fake_bin"

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name publishing-evidence-preflight

cat >"$repo/src/main/java/com/bit/publishing/controller/job/TypesetEvidenceController.java" <<'EOF'
final class TypesetEvidenceController {
    Result<?> artifacts(Long jobId) { return null; }
}
EOF
cat >"$repo/src/main/java/com/bit/publishing/application/job/TypesetEvidenceApplication.java" <<'EOF'
final class TypesetEvidenceApplication {
    void list() {}
}
EOF
git -C "$repo" add .
git -C "$repo" commit -qm base

cat >"$repo/src/main/java/com/bit/publishing/controller/job/TypesetEvidenceController.java" <<'EOF'
final class TypesetEvidenceController {
    @PreAuthorize("@perm.has('publishing:job:execute')")
    @PostMapping("/artifacts")
    Result<?> addArtifact(Long jobId, ArtifactCreateDTO dto) { return application.addArtifact(jobId, dto); }

    @PreAuthorize("@perm.has('publishing:job:execute')")
    @PostMapping("/issues")
    Result<?> addIssue(Long jobId, QualityIssueCreateDTO dto) { return application.addIssue(jobId, dto); }

    @PreAuthorize("@perm.has('publishing:job:execute')")
    @PostMapping("/tool-invocations")
    Result<?> addInvocation(Long jobId, ToolInvocationCreateDTO dto) { return application.addInvocation(jobId, dto); }
}
EOF
cat >"$repo/src/main/java/com/bit/publishing/application/job/TypesetEvidenceApplication.java" <<'EOF'
final class TypesetEvidenceApplication {
    void addArtifact(Long jobId, ArtifactCreateDTO dto) {
        entity.setFileId(dto.getFileId());
        entity.setSha256(dto.getSha256());
        entity.setStatus("READY");
        evidenceRepository.saveArtifact(entity);
    }
    void addIssue(Long jobId, QualityIssueCreateDTO dto) {
        entity.setEvidence(dto.getEvidence());
        entity.setStatus("OPEN");
        evidenceRepository.saveIssue(entity);
    }
    void addInvocation(Long jobId, ToolInvocationCreateDTO dto) {
        entity.setResponseJson(dto.getResponseJson());
        evidenceRepository.saveInvocation(entity);
    }
    Review review(Long jobId) {
        evidenceRepository.countDeliverableArtifacts(tenantId, jobId);
        evidenceRepository.countOpenBlockingIssues(tenantId, jobId);
        return null;
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
marker='排版任务证据写入端点仅受普通 execute 权限保护'
[[ "$(printf '%s\n' "$output" | grep -cF "$marker" || true)" == 1 ]] || {
  echo 'publishing evidence preflight did not emit exactly one finding' >&2
  printf '%s\n' "$output" >&2
  exit 1
}
printf '%s\n' "$output" | grep -F 'TypesetEvidenceController.java:' >/dev/null

cp -R "$repo" "$safe_repo"
python3 - "$safe_repo/src/main/java/com/bit/publishing/controller/job/TypesetEvidenceController.java" \
  "$safe_repo/src/main/java/com/bit/publishing/application/job/TypesetEvidenceApplication.java" <<'PY'
from pathlib import Path
import sys
controller = Path(sys.argv[1])
application = Path(sys.argv[2])
controller.write_text(controller.read_text().replace(
    '@PreAuthorize("@perm.has(\'publishing:job:execute\')")',
    '@PreAuthorize("@perm.has(\'publishing:job:execute\')") // ExecutionRef worker grant required'))
application.write_text(application.read_text() + '\n'
    'ExecutionRef ref = requireExecutionRef();\n'
    'lockActiveExecution(ref);\n'
    'MessageDigest contentInspector = sha256Inspector();\n')
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
  echo 'publishing evidence preflight reported the worker-fenced safe fixture' >&2
  printf '%s\n' "$safe_output" >&2
  exit 1
fi

echo 'publishing evidence write preflight regression passed'
