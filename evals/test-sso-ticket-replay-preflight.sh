#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-sso-ticket-replay.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
repo="$fixture_root/repo"
safe_repo="$fixture_root/safe-repo"
fake_bin="$fixture_root/bin"
mkdir -p "$repo/src/main/java/com/bit/auth/controller" "$fake_bin"

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name sso-ticket-replay-preflight
cat >"$repo/src/main/java/com/bit/auth/controller/SsoController.java" <<'EOF'
@RequestMapping("/sso")
class SsoController {
    @PostMapping("/status")
    Object status() { return null; }
}
EOF
git -C "$repo" add .
git -C "$repo" commit -qm base

cat >"$repo/src/main/java/com/bit/auth/controller/SsoController.java" <<'EOF'
@RequestMapping("/sso")
class SsoController {
    @PostMapping("/exchange")
    Object exchange(String ticket) {
        String key = RedisKeyUtil.getSsoTicketKey(ticket);
        Object cached = redisUtil.get(key);
        redisUtil.delete(key);
        return cached;
    }
}
EOF

cat >"$fake_bin/ollama" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"response":"未发现阻塞问题","done":true,"done_reason":"stop"}'
EOF
chmod +x "$fake_bin/ollama" "$fake_bin/curl"

run_review() {
  PATH="$fake_bin:$PATH" LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
    OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
    OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 OLLAMA_REVIEW_NUM_CTX=65536 \
    OLLAMA_REVIEW_TOTAL_TIMEOUT_SECONDS=120 \
    "$repo_root/bin/local-review.sh" --repo "$1"
}

output="$(run_review "$repo")"
marker='SSO 一次性票据先读取后删除'
[[ "$(printf '%s\n' "$output" | grep -cF "$marker" || true)" == 1 ]] || {
  echo 'SSO ticket replay preflight did not emit exactly one finding' >&2
  printf '%s\n' "$output" >&2
  exit 1
}
for field in '影响：' '修复建议：' '验证方式：' '来源：确定性预检'; do
  printf '%s\n' "$output" | grep -F "$field" >/dev/null || {
    echo "SSO ticket replay preflight omitted $field" >&2
    exit 1
  }
done

cp -R "$repo" "$safe_repo"
python3 - "$safe_repo/src/main/java/com/bit/auth/controller/SsoController.java" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
text = text.replace(
    'Object cached = redisUtil.get(key);\n        redisUtil.delete(key);',
    'Object cached = redisUtil.getAndDelete(key);',
)
path.write_text(text)
PY
safe_output="$(run_review "$safe_repo")"
if printf '%s\n' "$safe_output" | grep -F "$marker" >/dev/null; then
  echo 'SSO ticket replay preflight reported atomic getAndDelete fixture' >&2
  printf '%s\n' "$safe_output" >&2
  exit 1
fi

echo 'SSO ticket replay preflight regression passed'
