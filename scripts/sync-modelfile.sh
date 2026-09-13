#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
review_script="$project_root/bin/local-review.sh"
modelfile="$project_root/config/Modelfile"

[[ -r "$review_script" ]] || { echo "找不到审查脚本: $review_script" >&2; exit 2; }
[[ -r "$modelfile" ]] || { echo "找不到 Modelfile: $modelfile" >&2; exit 2; }

prompt_file="$(mktemp "${TMPDIR:-/tmp}/local-review-system-prompt.XXXXXX")"
output_file="$(mktemp "${TMPDIR:-/tmp}/local-review-modelfile.XXXXXX")"
trap 'rm -f "$prompt_file" "$output_file"' EXIT

awk '/^review_system="\$\(cat <<'\''EOF'\''$/{found=1; next} found && /^EOF$/{exit} found{print}' "$review_script" >"$prompt_file"
[[ -s "$prompt_file" ]] || { echo "无法从审查脚本提取 system prompt。" >&2; exit 2; }

awk '/^SYSTEM """/{exit} {print}' "$modelfile" >"$output_file"
printf 'SYSTEM """\n' >>"$output_file"
cat "$prompt_file" >>"$output_file"
printf '"""\n' >>"$output_file"
mv "$output_file" "$modelfile"
printf '已同步 Modelfile system prompt: %s\n' "$modelfile"
