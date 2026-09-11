#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin_dir="${LOCAL_REVIEW_BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$bin_dir"

install -m 755 "$project_dir/bin/local-review.sh" "$bin_dir/local-review.sh"
ln -sfn "$bin_dir/local-review.sh" "$bin_dir/local-review"

printf '已安装全局命令: %s/local-review\n' "$bin_dir"
printf '模型不会由此脚本自动下载；请先确认 Ollama 中已有 review 模型。\n'
