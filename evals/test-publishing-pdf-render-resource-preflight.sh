#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-publishing-pdf-render.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
repo="$fixture_root/repo"
safe_repo="$fixture_root/safe-repo"
fake_bin="$fixture_root/bin"
mkdir -p "$repo/src/main/java/com/bit/publishing/application/job" "$fake_bin"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name publishing-pdf-render-preflight

cat >"$repo/src/main/java/com/bit/publishing/application/job/TypesetEvidenceApplication.java" <<'EOF'
import org.apache.pdfbox.Loader;
import org.apache.pdfbox.rendering.ImageType;
import org.apache.pdfbox.rendering.PDFRenderer;

final class TypesetEvidenceApplication {
    byte[] renderPdfPage(int pageNumber) throws Exception {
        try (var document = Loader.loadPDF(path.toFile())) {
            return encodePng(null);
        }
    }

    byte[] encodePng(Object image) { return new byte[0]; }
    Object path = null;
    Object renderPdfPage = null;
}
EOF
git -C "$repo" add .
git -C "$repo" commit -qm base
python3 - "$repo/src/main/java/com/bit/publishing/application/job/TypesetEvidenceApplication.java" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
s = s.replace('return encodePng(null);',
              'var image = new PDFRenderer(document).renderImageWithDPI(pageNumber - 1, 144, ImageType.RGB);\n'
              '            return encodePng(image);')
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

# The fixture adds the renderer line in the concrete application path, so the
# current method is the exact vulnerable shape even though the surrounding
# project is intentionally minimal.
output="$(PATH="$fake_bin:$PATH" LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 OLLAMA_REVIEW_NUM_CTX=65536 \
  OLLAMA_REVIEW_TOTAL_TIMEOUT_SECONDS=120 \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
marker='PDF 预览在 PDFBox 光栅化前没有页面尺寸或像素面积上限'
[[ "$(printf '%s\n' "$output" | grep -cF "$marker" || true)" == 1 ]] || {
  echo 'publishing PDF render preflight did not emit exactly one finding' >&2
  printf '%s\n' "$output" >&2
  exit 1
}

cp -R "$repo" "$safe_repo"
python3 - "$safe_repo/src/main/java/com/bit/publishing/application/job/TypesetEvidenceApplication.java" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text().replace(
    'var image = new PDFRenderer(document).renderImageWithDPI(pageNumber - 1, 144, ImageType.RGB);',
    'var box = document.getPage(pageNumber - 1).getCropBox();\n'
    '            long pixels = Math.round(box.getWidth() * 144 / 72.0) * Math.round(box.getHeight() * 144 / 72.0);\n'
    '            if (pixels > 40_000_000L) throw new IllegalArgumentException("page too large");\n'
    '            var image = new PDFRenderer(document).renderImageWithDPI(pageNumber - 1, 144, ImageType.RGB);')
p.write_text(s)
PY
safe_output="$(PATH="$fake_bin:$PATH" LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 OLLAMA_REVIEW_NUM_CTX=65536 \
  OLLAMA_REVIEW_TOTAL_TIMEOUT_SECONDS=120 \
  "$repo_root/bin/local-review.sh" --repo "$safe_repo")"
if printf '%s\n' "$safe_output" | grep -F "$marker" >/dev/null; then
  echo 'publishing PDF render preflight reported the guarded safe fixture' >&2
  printf '%s\n' "$safe_output" >&2
  exit 1
fi

echo 'publishing PDF render resource preflight regression passed'
