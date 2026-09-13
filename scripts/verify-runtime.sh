#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
model="${1:-devstral-small-2-review-tuned:latest}"
modelfile="$project_root/config/Modelfile"

command -v ollama >/dev/null 2>&1 || {
  echo "找不到 ollama，请先安装并启动 Ollama。" >&2
  exit 2
}
[[ -r "$modelfile" ]] || { echo "找不到 Modelfile: $modelfile" >&2; exit 2; }

runtime_file="$(mktemp "${TMPDIR:-/tmp}/local-review-runtime.XXXXXX")"
expected_system_file="$(mktemp "${TMPDIR:-/tmp}/local-review-expected-system.XXXXXX")"
runtime_system_file="$(mktemp "${TMPDIR:-/tmp}/local-review-runtime-system.XXXXXX")"
trap 'rm -f "$runtime_file" "$expected_system_file" "$runtime_system_file"' EXIT
if ! ollama show "$model" --modelfile >"$runtime_file" 2>/dev/null; then
  echo "Ollama 中不存在模型: $model" >&2
  echo "请先执行: ollama create $model -f $modelfile" >&2
  exit 1
fi

# `ollama show --modelfile` emits a generated Modelfile.  Compare the complete
# SYSTEM payload rather than a few marker strings so a stale or partially
# rebuilt model cannot silently pass the runtime gate.  Strip only CRLF
# carriage returns; all other whitespace is part of the prompt contract.
extract_system_prompt() {
  local source="$1"
  local destination="$2"
  awk '
    BEGIN { state = 0; blocks = 0 }
    state == 0 && $0 ~ /^SYSTEM[[:space:]]+"""[[:space:]]*$/ {
      state = 1
      blocks++
      next
    }
    state == 1 && $0 ~ /^"""[[:space:]]*$/ {
      state = 2
      next
    }
    state == 1 {
      sub(/\r$/, "")
      print
      next
    }
    END {
      if (blocks != 1 || state != 2) exit 1
    }
  ' "$source" >"$destination"
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    echo "找不到 shasum 或 sha256sum，无法校验 SYSTEM 规则。" >&2
    return 2
  fi
}

verify_global_wrapper_file() {
  local global_wrapper="$1"
  local expected_script="$2"
  [[ -e "$global_wrapper" ]] || return 0
  local expected_hash actual_hash
  expected_hash="$(sha256_file "$expected_script")"
  actual_hash="$(sha256_file "$global_wrapper")"
  if [[ "$expected_hash" != "$actual_hash" ]]; then
    printf '全局 local-review 与当前仓库脚本不一致: expected=%s actual=%s\n' \
      "$expected_hash" "$actual_hash" >&2
    echo "请执行: $project_root/scripts/install-global.sh" >&2
    return 1
  fi
}

global_bin_dir="${LOCAL_REVIEW_BIN_DIR:-$HOME/.local/bin}"
verify_global_wrapper_file "$global_bin_dir/local-review" "$project_root/bin/local-review.sh"
verify_global_wrapper_file "$global_bin_dir/local-review.sh" "$project_root/bin/local-review.sh"
verify_global_wrapper_file "$global_bin_dir/local-review-local" "$project_root/bin/local-review-local.sh"
verify_global_wrapper_file "$global_bin_dir/local-review-local.sh" "$project_root/bin/local-review-local.sh"

if ! extract_system_prompt "$modelfile" "$expected_system_file"; then
  echo "当前 config/Modelfile 缺少可解析的唯一 SYSTEM 规则块。" >&2
  exit 2
fi
if ! extract_system_prompt "$runtime_file" "$runtime_system_file"; then
  echo "运行态模型缺少可解析的唯一 SYSTEM 规则块。" >&2
  exit 1
fi

expected_system_hash="$(sha256_file "$expected_system_file")"
runtime_system_hash="$(sha256_file "$runtime_system_file")"
if [[ "$expected_system_hash" != "$runtime_system_hash" ]]; then
  printf '运行态 SYSTEM 规则哈希不一致: expected=%s runtime=%s\n' \
    "$expected_system_hash" "$runtime_system_hash" >&2
  echo "运行态模型与当前个人审计配置不一致。请重建：" >&2
  echo "  ./scripts/sync-modelfile.sh" >&2
  echo "  ollama create $model -f $modelfile" >&2
  exit 1
fi

required_patterns=(
  'PARAMETER num_ctx 16384'
  'PARAMETER temperature 0'
  'PARAMETER seed 42'
  'PARAMETER top_k 40'
  'PARAMETER top_p 0.9'
  'PARAMETER num_predict 4096'
  'stdin'
  '影响：'
  '修复建议：'
  '验证方式：'
  '对象存储上传取消边界'
)

missing=0
for pattern in "${required_patterns[@]}"; do
  if ! grep -Fq "$pattern" "$runtime_file"; then
    printf '运行态缺少规则或参数: %s\n' "$pattern" >&2
    missing=1
  fi
done

if (( missing )); then
  echo "运行态模型与当前个人审计配置不一致。请重建：" >&2
  echo "  ./scripts/sync-modelfile.sh" >&2
  echo "  ollama create $model -f $modelfile" >&2
  exit 1
fi

printf '运行态模型校验通过: %s (SYSTEM sha256=%s)\n' "$model" "$expected_system_hash"
