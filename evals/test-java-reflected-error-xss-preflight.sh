#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-java-error-xss.XXXXXX")"
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
git -C "$repo" config user.name java-error-xss-preflight
git -C "$repo" commit --allow-empty -qm 基线

cat >"$repo/src/main/java/testcases/BadFilterController.java" <<'EOF'
package testcases;

class BadFilterController {
    @RequestMapping("/groups")
    Result list(@RequestParam String filter) {
        try {
            return service.list(filter);
        } catch (IllegalArgumentException e) {
            throw new BadRequestException("Invalid filter: [" + filter + "]");
        }
    }

    @ExceptionHandler(BadRequestException.class)
    ResponseEntity<String> handle(BadRequestException error) {
        return ResponseEntity.badRequest().body(error.getMessage());
    }
}
EOF
cat >"$repo/src/main/java/testcases/SafeFilterController.java" <<'EOF'
package testcases;

class SafeFilterController {
    @RequestMapping("/groups")
    Result list(@RequestParam String filter) {
        try {
            return service.list(filter);
        } catch (IllegalArgumentException e) {
            throw new BadRequestException("Invalid filter: [" + HtmlUtils.htmlEscape(filter) + "]");
        }
    }

    @ExceptionHandler(BadRequestException.class)
    ResponseEntity<String> handle(BadRequestException error) {
        return ResponseEntity.badRequest().body(error.getMessage());
    }
}
EOF
cat >"$repo/src/main/java/testcases/InternalError.java" <<'EOF'
package testcases;

class InternalError {
    void run(String filter) {
        throw new IllegalStateException("internal: " + filter);
    }
}
EOF

output="$(PATH="$fake_bin:$PATH" TMPDIR="$fixture_root" \
  OLLAMA_REVIEW_LOCK_DIR="$fixture_root/lock" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_NUM_CTX=65536 OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
printf '%s\n' "$output" | grep -F 'HTTP 输入 filter 未见上下文编码' >/dev/null
printf '%s\n' "$output" | grep -F 'BadFilterController.java:' >/dev/null
[[ "$(printf '%s\n' "$output" | grep -c 'HTTP 输入 filter 未见上下文编码' || true)" -eq 1 ]]
for field in '影响：' '修复建议：' '验证方式：'; do
  [[ "$(printf '%s\n' "$output" | grep -cF "$field" || true)" -eq 1 ]]
done
if printf '%s\n' "$output" | grep -E 'SafeFilterController.java:|InternalError.java:' >/dev/null; then
  echo 'safe escaped or non-HTTP exception was incorrectly reported' >&2
  printf '%s\n' "$output" >&2
  exit 1
fi

echo 'Java reflected-error XSS preflight regression passed'
