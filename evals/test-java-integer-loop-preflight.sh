#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-java-integer-loop.XXXXXX")"
fake_bin="$fixture_root/bin"
repo="$fixture_root/repo"
trap 'rm -rf "$fixture_root"' EXIT
mkdir -p "$fake_bin" "$repo/src/main/java/testcases"

cat >"$fake_bin/ollama" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"未发现阻塞问题","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/ollama" "$fake_bin/curl"

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name java-integer-loop-preflight
git -C "$repo" commit --allow-empty -qm 基线

cat >"$repo/src/main/java/testcases/IntegerLoopFixture.java" <<'EOF'
package testcases;

class ZipLong {}

class IntegerLoopFixture {
    void bad(byte[] data) {
        long count = ZipLong.getValue(data, 0);
        for (int i = 0; i < count; i++) {
            audit(i);
        }
    }

    void safeLong(byte[] data) {
        long count = ZipLong.getValue(data, 0);
        for (long i = 0; i < count; i++) {
            audit(i);
        }
    }

    void safeBounded(byte[] data) {
        long count = Math.min(ZipLong.getValue(data, 0), Integer.MAX_VALUE);
        for (int i = 0; i < count; i++) {
            audit(i);
        }
    }

    private void audit(long value) {}
}
EOF

output="$(PATH="$fake_bin:$PATH" TMPDIR="$fixture_root" \
  OLLAMA_REVIEW_LOCK_DIR="$fixture_root/lock" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_NUM_CTX=65536 OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
printf '%s\n' "$output" | grep -F '32 位循环计数器直接比较外部 long 值' >/dev/null
printf '%s\n' "$output" | grep -F 'IntegerLoopFixture.java:8' >/dev/null
if printf '%s\n' "$output" | grep -F 'IntegerLoopFixture.java:15' >/dev/null ||
   printf '%s\n' "$output" | grep -F 'IntegerLoopFixture.java:22' >/dev/null; then
  echo 'safe integer-loop variants were incorrectly reported' >&2
  printf '%s\n' "$output" >&2
  exit 1
fi

echo 'Java integer-loop overflow preflight regression passed'
