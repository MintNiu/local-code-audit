#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin_dir="${LOCAL_REVIEW_BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$bin_dir"

link_script() {
  local source="$1"
  local target="$2"
  if [[ -e "$target" && ! -L "$target" ]]; then
    local backup="${target}.backup-$(date +%Y%m%d%H%M%S)"
    mv "$target" "$backup"
    printf '已保留旧脚本备份: %s\n' "$backup"
  fi
  ln -sfn "$source" "$target"
}

# Keep the global entry points linked to the checked-out workflow. A copied
# script can silently keep old deterministic prechecks after the repository is
# updated, which is exactly how known findings start recurring.
link_script "$project_dir/bin/local-review.sh" "$bin_dir/local-review.sh"
link_script "$project_dir/bin/local-review-local.sh" "$bin_dir/local-review-local.sh"
ln -sfn "$bin_dir/local-review.sh" "$bin_dir/local-review"
ln -sfn "$bin_dir/local-review-local.sh" "$bin_dir/local-review-local"

printf '已安装全局命令: %s/local-review\n' "$bin_dir"
printf '已安装本地高性能命令: %s/local-review-local\n' "$bin_dir"
printf '模型不会由此脚本自动下载；请先确认 Ollama 中已有 review 模型。\n'
