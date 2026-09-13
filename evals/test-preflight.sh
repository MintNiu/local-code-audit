#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-preflight-test.XXXXXX")"
fake_bin="$fixture_root/bin"
repo="$fixture_root/repo"
context="$fixture_root/downstream/Downstream.java"
capture="$fixture_root/request.json"
show_log="$fixture_root/ollama-show.log"
tmp_dir="$fixture_root/tmp"
trap 'rm -rf "$fixture_root"' EXIT

mkdir -p "$fake_bin" "$tmp_dir" "$repo/src/main/java/com/example/api/client" "$repo/src/main/java/com/example/api/dto" "$repo/src/test/java/com/example/api/dto" "$(dirname "$context")"

cat >"$fake_bin/ollama" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${OLLAMA_SHOW_LOG:-/dev/null}"
exit 0
EOF

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
previous=""
for argument in "$@"; do
  if [[ "$previous" == "-d" ]]; then
    printf '%s' "$argument" >"$LOCAL_REVIEW_CAPTURE"
  elif [[ "$previous" == "--data-binary" && "$argument" == @* ]]; then
    cp "${argument#@}" "$LOCAL_REVIEW_CAPTURE"
  fi
  previous="$argument"
done
printf '{"response":"未发现阻塞问题","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/ollama" "$fake_bin/curl"

PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" OLLAMA_SHOW_LOG="$show_log" \
  OLLAMA_REVIEW_PROBE_TIMEOUT_SECONDS=invalid \
  "$repo_root/bin/local-review.sh" --help >/dev/null
[[ ! -s "$show_log" ]] || {
  echo '--help unexpectedly contacted Ollama' >&2
  cat "$show_log" >&2
  exit 1
}
if PATH="$fake_bin:$PATH" "$repo_root/bin/local-review.sh" --base '--output=/tmp/local-review-option-injection' --help >/dev/null 2>&1; then
  echo '--base accepted a Git option-like value' >&2
  exit 1
fi

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name preflight-test

cat >"$repo/src/main/java/com/example/api/client/Client.java" <<'EOF'
package com.example.api.client;

public interface Client {}
EOF
cat >"$repo/src/test/java/com/example/api/dto/MissingDTO.java" <<'EOF'
package com.example.api.dto;

final class MissingDTO {}
EOF
git -C "$repo" add .
git -C "$repo" commit -qm base

PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" OLLAMA_SHOW_LOG="$show_log" \
  "$repo_root/bin/local-review.sh" --repo "$repo" >/dev/null
[[ ! -s "$show_log" ]] || {
  echo 'clean repository unexpectedly contacted Ollama' >&2
  cat "$show_log" >&2
  exit 1
}
: >"$show_log"

cat >"$fake_bin/textconv" <<'EOF'
#!/usr/bin/env bash
touch "${TEXTCONV_MARKER:?}"
cat "$1"
EOF
chmod +x "$fake_bin/textconv"
git -C "$repo" config diff.evil.textconv "$fake_bin/textconv"
printf '*.bin diff=evil\n' >"$repo/.gitattributes"
printf 'base binary-like content\n' >"$repo/sample.bin"
git -C "$repo" add .gitattributes sample.bin
git -C "$repo" commit -qm textconv-base
printf 'changed binary-like content\n' >"$repo/sample.bin"
rm -f "$fixture_root/textconv.marker"

mkdir -p "$repo/module-a/src/main/java/com/example/api/client" "$repo/module-a/src/test/java/com/example/api/dto"
cat >"$repo/module-a/src/main/java/com/example/api/client/ModuleClient.java" <<'EOF'
package com.example.api.client;

public interface ModuleClient {}
EOF
cat >"$repo/module-a/src/test/java/com/example/api/dto/ModuleMissing.java" <<'EOF'
package com.example.api.dto;

final class ModuleMissing {}
EOF
git -C "$repo" add module-a
git -C "$repo" commit -qm module-base
cat >"$repo/module-a/src/main/java/com/example/api/client/ModuleClient.java" <<'EOF'
package com.example.api.client;

import com.example.api.dto.ModuleMissing;

public interface ModuleClient {
    ModuleMissing call();
}
EOF

cat >"$repo/src/main/java/com/example/api/client/Client.java" <<'EOF'
package com.example.api.client;

import com.example.api.dto.MissingDTO;

public interface Client {
    MissingDTO call(MissingDTO request);
}
EOF

cat >"$fake_bin/fsmonitor" <<'EOF'
#!/usr/bin/env bash
touch "${FSMONITOR_MARKER:-/dev/null}"
printf 'token\n'
exit 0
EOF
chmod +x "$fake_bin/fsmonitor"
git -C "$repo" config core.fsmonitor "$fake_bin/fsmonitor"
rm -f "$fixture_root/fsmonitor.marker"

PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" OLLAMA_SHOW_LOG="$show_log" \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  TEXTCONV_MARKER="$fixture_root/textconv.marker" FSMONITOR_MARKER="$fixture_root/fsmonitor.marker" \
  "$repo_root/bin/local-review.sh" --repo "$repo" >/dev/null
grep -F '当前提交快照缺少仓库内类型 com.example.api.dto.MissingDTO' "$capture" >/dev/null
grep -F '当前提交快照缺少仓库内类型 com.example.api.dto.ModuleMissing' "$capture" >/dev/null
[[ ! -e "$fixture_root/textconv.marker" ]] || {
  echo 'git diff executed a configured textconv filter' >&2
  exit 1
}
[[ ! -e "$fixture_root/fsmonitor.marker" ]] || {
  echo 'git status executed a configured fsmonitor hook' >&2
  exit 1
}
[[ "$(wc -l <"$show_log" | tr -d ' ')" == "1" ]] || {
  echo 'automatic model selection performed a redundant model probe' >&2
  cat "$show_log" >&2
  exit 1
}
if find "$tmp_dir" -maxdepth 1 -name 'local-review-untracked.*' -print -quit | grep -q .; then
  echo 'untracked diff temporary file was not cleaned up' >&2
  exit 1
fi

PATH="$fake_bin:$PATH" TMPDIR="$tmp_dir" LOCAL_REVIEW_CAPTURE="$capture" \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo" --model custom-review-model >/dev/null
grep -F 'custom-review-model' "$capture" >/dev/null || {
  echo '--model override was replaced by automatic model selection' >&2
  exit 1
}
: >"$show_log"

cat >"$repo/src/main/java/com/example/api/dto/DeletedDTO.java" <<'EOF'
package com.example.api.dto;

public record DeletedDTO(String value) {}
EOF
git -C "$repo" add .
git -C "$repo" commit -qm add-dto
cat >"$repo/src/main/java/com/example/api/client/Consumer.java" <<'EOF'
package com.example.api.client;

import com.example.api.dto.DeletedDTO;

final class Consumer {
    DeletedDTO value;
}
EOF
cat >"$context" <<'EOF'
package com.example.downstream;

import com.example.api.dto.DeletedDTO;

final class Downstream {
    DeletedDTO value;
}
EOF
git -C "$repo" rm -q src/main/java/com/example/api/dto/DeletedDTO.java

PATH="$fake_bin:$PATH" LOCAL_REVIEW_CAPTURE="$capture" \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo" --context "$context" >/dev/null
grep -F '当前提交删除类型 com.example.api.dto.DeletedDTO' "$capture" >/dev/null
grep -F '仓库内文件 src/main/java/com/example/api/client/Consumer.java' "$capture" >/dev/null

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"P0 src/main/java/com/example/api/client/Client.java:1-93 - 文件内容不完整，缺少类声明和字段定义，导致无法验证代码逻辑是否正确。\\n\\n影响：无法确定代码是否符合项目规则。\\n\\n修复建议：提供完整的文件内容。","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"
if ! shard_output="$(PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo" 2>/dev/null)"; then
  echo 'unsupported shard-boundary finding caused review failure' >&2
  exit 1
fi
if ! printf '%s\n' "$shard_output" | grep -Fx '未发现阻塞问题' >/dev/null; then
  echo 'unsupported shard-boundary finding was not filtered' >&2
  printf '%s\n' "$shard_output" >&2
  exit 1
fi

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"P1 src/main/java/com/example/api/client/Consumer.java:5 - Authorization: Bearer super-secret-token-value; \\\"Authorization\\\": \\\"Basic basic-secret-value\\\"\\n影响：凭据可能进入审查输出。\\n修复建议：轮换并移除凭据。\\n验证方式：确认输出不包含原始凭据。","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"
redacted_output="$(PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
[[ "$redacted_output" == *'Authorization: Bearer <REDACTED>'* ]] || {
  echo 'Authorization bearer value was not redacted' >&2
  printf '%s\n' "$redacted_output" >&2
  exit 1
}
[[ "$redacted_output" == *'"Authorization": "Basic <REDACTED>"'* ]] || {
  echo 'JSON Basic authorization value was not redacted' >&2
  printf '%s\n' "$redacted_output" >&2
  exit 1
}
[[ "$redacted_output" != *'super-secret-token-value'* ]] || {
  echo 'raw Authorization bearer value leaked in review output' >&2
  exit 1
}
[[ "$redacted_output" != *'basic-secret-value'* ]] || {
  echo 'raw Basic authorization value leaked in review output' >&2
  exit 1
}

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"P1 src/main/java/com/example/api/client/Consumer.java:5 - \\u001b[31mANSI marker\\u001b[0m remains visible","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"
safe_output="$(PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
if printf '%s' "$safe_output" | LC_ALL=C grep -q $'\033'; then
  echo 'ANSI escape sequence leaked in review output' >&2
  exit 1
fi
[[ "$safe_output" == *'ANSI marker'* ]] || {
  echo 'ANSI sanitization removed the finding text' >&2
  exit 1
}

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"P1 src/main/java/com/example/api/client/Consumer.java:5 - https://oss.example.test/upload?X-Amz-Credential=AKID_EXAMPLE&X-Amz-Signature=signature-secret-value&X-Amz-Security-Token=session-secret-value","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"
url_safe_output="$(PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo")"
[[ "$url_safe_output" == *'X-Amz-Credential=<REDACTED>'* ]] || {
  echo 'presigned URL credential was not redacted' >&2
  exit 1
}
[[ "$url_safe_output" == *'X-Amz-Signature=<REDACTED>'* ]] || {
  echo 'presigned URL signature was not redacted' >&2
  exit 1
}
[[ "$url_safe_output" == *'X-Amz-Security-Token=<REDACTED>'* ]] || {
  echo 'presigned URL security token was not redacted' >&2
  exit 1
}
[[ "$url_safe_output" != *'signature-secret-value'* && "$url_safe_output" != *'session-secret-value'* ]] || {
  echo 'raw presigned URL credential leaked in review output' >&2
  exit 1
}

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"未发现阻塞问题。","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"
marker_output="$(PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo" 2>/dev/null)"
if ! printf '%s\n' "$marker_output" | grep -Fx '未发现阻塞问题' >/dev/null; then
  echo 'clean marker with punctuation was not normalized' >&2
  printf '%s\n' "$marker_output" >&2
  exit 1
fi

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"P2 src/main/java/com/example/api/client/Consumer.java:5 - 低严重度示例问题。\\n\\nP0 src/main/java/com/example/api/client/Consumer.java:6 - 高严重度示例问题。","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/curl"
single_sorted_output="$(PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 "$repo_root/bin/local-review.sh" --repo "$repo")"
single_p0_line="$(printf '%s\n' "$single_sorted_output" | grep -n '^P0 ' | head -n1 | cut -d: -f1)"
single_p2_line="$(printf '%s\n' "$single_sorted_output" | grep -n '^P2 ' | head -n1 | cut -d: -f1)"
if [[ -z "$single_p0_line" || -z "$single_p2_line" || "$single_p0_line" -ge "$single_p2_line" ]]; then
  echo 'single-request findings were not globally sorted by severity' >&2
  printf '%s\n' "$single_sorted_output" >&2
  exit 1
fi

sort_repo="$fixture_root/sort-repo"
mkdir -p "$sort_repo/src"
git -C "$sort_repo" init -q
git -C "$sort_repo" config user.email test@example.invalid
git -C "$sort_repo" config user.name preflight-test
: >"$sort_repo/src/A.java"
: >"$sort_repo/src/B.java"
for i in {1..12}; do
  printf 'class A { int value = 1; } // baseline line %02d\n' "$i" >>"$sort_repo/src/A.java"
  printf 'class B { int value = 1; } // baseline line %02d\n' "$i" >>"$sort_repo/src/B.java"
done
git -C "$sort_repo" add .
git -C "$sort_repo" commit -qm sort-base
: >"$sort_repo/src/A.java"
: >"$sort_repo/src/B.java"
for i in {1..12}; do
  printf 'class A { int value = 2; } // changed line %02d\n' "$i" >>"$sort_repo/src/A.java"
  printf 'class B { int value = 2; } // changed line %02d\n' "$i" >>"$sort_repo/src/B.java"
done
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
previous=""
request_file=""
for argument in "$@"; do
  if [[ "$previous" == "--data-binary" && "$argument" == @* ]]; then
    request_file="${argument#@}"
  fi
  previous="$argument"
done
prompt="$(jq -r '.prompt' "$request_file")"
if printf '%s\n' "$prompt" | grep -q '^diff --git a/src/A.java'; then
  printf '{"response":"P2 src/A.java:1 - 低严重度示例问题。","done":true,"done_reason":"stop"}\n'
else
  printf '{"response":"P0 src/B.java:1 - 高严重度示例问题。","done":true,"done_reason":"stop"}\n'
fi
EOF
chmod +x "$fake_bin/curl"
sorted_output="$(PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  OLLAMA_REVIEW_MAX_DIFF_BYTES=1000 OLLAMA_REVIEW_CHUNK_NUM_PREDICT=512 \
  OLLAMA_REVIEW_CHUNK_TIMEOUT_SECONDS=30 OLLAMA_REVIEW_TOTAL_TIMEOUT_SECONDS=120 \
  "$repo_root/bin/local-review.sh" --repo "$sort_repo")"
p0_line="$(printf '%s\n' "$sorted_output" | grep -n '^P0 ' | head -n1 | cut -d: -f1)"
p2_line="$(printf '%s\n' "$sorted_output" | grep -n '^P2 ' | head -n1 | cut -d: -f1)"
if [[ -z "$p0_line" || -z "$p2_line" || "$p0_line" -ge "$p2_line" ]]; then
  echo 'aggregated findings were not globally sorted by severity' >&2
  printf '%s\n' "$sorted_output" >&2
  exit 1
fi

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"P1 src/main/java/com/example/api/client/Client.java:5 - incomplete","done":false,"done_reason":"length"}\n'
EOF
chmod +x "$fake_bin/curl"
if PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/bin/local-review.sh" --repo "$repo" >/dev/null 2>&1; then
  echo 'done=false response was incorrectly accepted' >&2
  exit 1
fi

printf 'preflight regression passed\n'
