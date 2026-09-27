#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-path-safety.XXXXXX")"
fake_bin="$fixture_root/bin"
repo="$fixture_root/repo"
outside_file="$fixture_root/outside.yml"
trap 'rm -rf "$fixture_root"' EXIT
mkdir -p "$fake_bin" "$repo/src/main/java/example"

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name path-safety-test
cat >"$repo/src/main/java/example/Changed.java" <<'EOF'
package example;

final class Changed {
    int value() {
        return 1;
    }
}
EOF
git -C "$repo" add .
git -C "$repo" commit -qm base
printf '\n// changed\n' >>"$repo/src/main/java/example/Changed.java"

# If the filter follows a model-supplied ../ path, this contradictory source
# would turn the fabricated finding into a false clean result. It must never
# be read because it is not part of the diff evidence.
cat >"$outside_file" <<'EOF'
baseUrl: "http://localhost:8092"
EOF

cat >"$fake_bin/ollama" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "show" ]]; then
    exit 0
fi
exit 2
EOF
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"response":"P1 ../outside.yml:1 - baseUrl 缺少默认值和空值检查。\n影响：可能失败。\n修复建议：增加检查。\n验证方式：传入空值。","done":true,"done_reason":"stop"}'
EOF
chmod +x "$fake_bin/ollama" "$fake_bin/curl"

if PATH="$fake_bin:$PATH" \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  "$repo_root/bin/local-review.sh" --repo "$repo" \
  >"$fixture_root/stdout" 2>"$fixture_root/stderr"; then
  echo 'model-supplied path traversal was accepted as a review result' >&2
  cat "$fixture_root/stdout" >&2
  cat "$fixture_root/stderr" >&2
  exit 1
fi
grep -F '缺少可验证的严重级别或文件/行号' "$fixture_root/stderr" >/dev/null || {
  echo 'path traversal did not fail through the normal location gate' >&2
  cat "$fixture_root/stderr" >&2
  exit 1
}
echo 'path safety regression passed'
