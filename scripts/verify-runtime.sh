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
trap 'rm -f "$runtime_file"' EXIT
if ! ollama show "$model" --modelfile >"$runtime_file" 2>/dev/null; then
  echo "Ollama 中不存在模型: $model" >&2
  echo "请先执行: ollama create $model -f $modelfile" >&2
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

printf '运行态模型校验通过: %s\n' "$model"
