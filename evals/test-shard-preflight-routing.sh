#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-shard-preflight.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
repo="$fixture_root/repo"
fake_bin="$fixture_root/bin"
counter="$fixture_root/counter"
mkdir -p "$repo/src/main/java/example" "$fake_bin"

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name shard-preflight-test
cat >"$repo/src/main/java/example/Large.java" <<'EOF'
package example;

final class Large {
    String forward(String token) {
        return "ok";
    }
}
EOF
git -C "$repo" add .
git -C "$repo" commit -qm base

cat >"$repo/src/main/java/example/Missing.java" <<'EOF'
package example;

import example.dto.MissingAlpha;
import example.dto.MissingBeta;

final class Missing {
    MissingAlpha call(MissingBeta value) {
        return value;
    }
}
EOF

sed -i '' 's@return "ok";@return "https://internal.example/data?x-token=" + token;@' \
  "$repo/src/main/java/example/Large.java"
sed -i '' '$d' "$repo/src/main/java/example/Large.java"
for i in $(seq 1 220); do
  printf '    int filler%s = %s;\n' "$i" "$i" >>"$repo/src/main/java/example/Large.java"
done
printf '}\n' >>"$repo/src/main/java/example/Large.java"

cat >"$fake_bin/ollama" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
payload=""
previous=""
for argument in "$@"; do
  if [[ "$previous" == "--data-binary" && "$argument" == @* ]]; then
    payload="${argument#@}"
    break
  fi
  previous="$argument"
done
prompt="$(jq -r '.prompt // empty' "$payload")"
if grep -Fq 'diff --git a/src/main/java/example/Large.java b/src/main/java/example/Large.java' <<<"$prompt"; then
  count=0
  if [[ -f "${LOCAL_REVIEW_COUNTER:?}" ]]; then count="$(<"$LOCAL_REVIEW_COUNTER")"; fi
  count=$((count + 1))
  printf '%s\n' "$count" >"$LOCAL_REVIEW_COUNTER"
  if (( count % 2 == 0 )); then
    detail='同一风险的另一种措辞'
  else
    detail='模型重复描述'
  fi
  printf '{"response":"P1 src/main/java/example/Large.java:5 - 认证令牌从 URL 查询参数读取，%s。\\n影响：请求参数中的 token 可能进入访问日志。\\n修复建议：仅使用受保护请求头。\\n验证方式：检查最终请求 URI 和网关日志。","done":true,"done_reason":"stop"}' "$detail"
  printf '\n'
else
  printf '{"response":"未发现阻塞问题","done":true,"done_reason":"stop"}\n'
fi
EOF
chmod +x "$fake_bin/ollama" "$fake_bin/curl"

output="$(
  PATH="$fake_bin:$PATH" \
  LOCAL_REVIEW_COUNTER="$counter" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  OLLAMA_REVIEW_MAX_DIFF_BYTES=1000 \
  OLLAMA_REVIEW_TOTAL_TIMEOUT_SECONDS=120 \
  "$repo_root/bin/local-review.sh" --repo "$repo"
)"

count="$(printf '%s\n' "$output" | grep -c '^P1 src/main/java/example/Large.java:5 -' || true)"
if [[ "$count" != 1 ]]; then
  echo "expected one routed URL-token finding, got $count" >&2
  printf '%s\n' "$output" >&2
  exit 1
fi

grep -F 'P1 src/main/java/example/Missing.java:3,4 - 当前提交快照缺少多个仓库内类型' <<<"$output" >/dev/null || {
  echo 'comma-separated preflight finding was not routed to its shard' >&2
  printf '%s\n' "$output" >&2
  exit 1
}
grep -F 'example.dto.MissingAlpha（第 3 行）' <<<"$output" >/dev/null || {
  echo 'routed preflight finding omitted the first missing type' >&2
  printf '%s\n' "$output" >&2
  exit 1
}
grep -F 'example.dto.MissingBeta（第 4 行）' <<<"$output" >/dev/null || {
  echo 'routed preflight finding omitted the second missing type' >&2
  printf '%s\n' "$output" >&2
  exit 1
}

echo 'shard preflight routing regression passed'
