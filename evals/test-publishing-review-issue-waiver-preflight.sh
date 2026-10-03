#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-publishing-waiver.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
repo="$fixture_root/repo"
safe_repo="$fixture_root/safe-repo"
fake_bin="$fixture_root/bin"
mkdir -p "$repo/src/main/java/com/bit/publishing/application/job" \
  "$repo/src/main/java/com/bit/publishing/repository/job" "$fake_bin"

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name publishing-review-waiver-preflight

cat >"$repo/src/main/java/com/bit/publishing/application/job/TypesetEvidenceApplication.java" <<'EOF'
final class TypesetEvidenceApplication {
    private static final Set<String> ISSUE_DECISIONS = Set.of("RESOLVED", "ACCEPTED", "IGNORED");
    QualityIssueVO decideIssue(Long jobId, Long issueId, QualityIssueDecisionDTO dto) {
        String status = enumValue(dto.getStatus());
        if (!ISSUE_DECISIONS.contains(status)) throw new BusinessException();
        entity.setStatus(status);
        evidenceRepository.updateIssue(entity);
        return null;
    }
    ReviewVO review(Long jobId, ReviewCreateDTO dto) {
        if ("APPROVED".equals(dto.getDecision())
                && evidenceRepository.countOpenBlockingIssues(tenantId, jobId) > 0) throw new BusinessException();
        return null;
    }
}
EOF
cat >"$repo/src/main/java/com/bit/publishing/repository/job/TypesetEvidenceRepository.java" <<'EOF'
final class TypesetEvidenceRepository {
    long countOpenBlockingIssues(Long tenantId, Long jobId) {
        return issueMapper.selectCount(query.eq(TypesetQualityIssue::getStatus, "OPEN")
                .in(TypesetQualityIssue::getSeverity, List.of("ERROR", "BLOCKER")));
    }
}
EOF
git -C "$repo" add .
git -C "$repo" commit -qm base

cat >>"$repo/src/main/java/com/bit/publishing/application/job/TypesetEvidenceApplication.java" <<'EOF'

// The changed workflow keeps the same status decision and review gate.
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

# Change the source in a way that puts the waiver contract into the diff.
python3 - "$repo/src/main/java/com/bit/publishing/application/job/TypesetEvidenceApplication.java" <<'PY'
from pathlib import Path
path = Path(__import__('sys').argv[1])
text = path.read_text().replace(
    'entity.setStatus(status);',
    'entity.setStatus(status); // changed decision path; ERROR/BLOCKER waiver remains possible',
)
path.write_text(text)
PY

output="$(
  PATH="$fake_bin:$PATH" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  OLLAMA_REVIEW_NUM_CTX=65536 \
  OLLAMA_REVIEW_TOTAL_TIMEOUT_SECONDS=120 \
  "$repo_root/bin/local-review.sh" --repo "$repo"
)"
marker='排版质量门禁允许人工把 ERROR/BLOCKER 问题改为已接受/已忽略'
[[ "$(printf '%s\n' "$output" | grep -cF "$marker" || true)" == 1 ]] || {
  echo 'publishing review waiver preflight did not emit exactly one finding' >&2
  printf '%s\n' "$output" >&2
  exit 1
}

cp -R "$repo" "$safe_repo"
python3 - "$safe_repo/src/main/java/com/bit/publishing/application/job/TypesetEvidenceApplication.java" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text().replace(
    'entity.setStatus(status); // changed decision path; ERROR/BLOCKER waiver remains possible',
    'if (NON_WAIVABLE_SEVERITIES.contains(entity.getSeverity())) throw new BusinessException("不能人工豁免");\n'
    '        entity.setStatus(status); // guarded decision path',
)
text = text.replace(
    'final class TypesetEvidenceApplication {',
    'final class TypesetEvidenceApplication {\n'
    '    private static final Set<String> NON_WAIVABLE_SEVERITIES = Set.of("ERROR", "BLOCKER");',
)
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
  echo 'publishing review waiver preflight reported the non-waivable safe fixture' >&2
  printf '%s\n' "$safe_output" >&2
  exit 1
fi

echo 'publishing review issue waiver preflight regression passed'
