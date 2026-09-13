#!/usr/bin/env bash
set -euo pipefail

repo_dir=""
git_ref=""
repo_path=""
output_file=""

usage() {
  cat <<'EOF'
用法:
  ./scripts/extract-context-snapshot.sh \
    --repo /path/to/downstream-repo \
    --ref <git-ref> \
    --path path/inside/repo \
    --out /path/to/private/context-file

说明:
  从指定 Git ref 提取一个下游 context 文件，供 local-review --context 使用。
  输出文件应放在公开仓库之外；源仓库不会被修改。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || { echo "--repo 需要目录" >&2; exit 2; }
      repo_dir="$2"
      shift 2
      ;;
    --ref)
      [[ $# -ge 2 ]] || { echo "--ref 需要 Git ref" >&2; exit 2; }
      [[ "$2" != -* ]] || { echo "--ref 不接受以 - 开头的值" >&2; exit 2; }
      git_ref="$2"
      shift 2
      ;;
    --path)
      [[ $# -ge 2 ]] || { echo "--path 需要仓库内相对路径" >&2; exit 2; }
      repo_path="$2"
      shift 2
      ;;
    --out)
      [[ $# -ge 2 ]] || { echo "--out 需要输出文件" >&2; exit 2; }
      output_file="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$repo_dir" && -n "$git_ref" && -n "$repo_path" && -n "$output_file" ]] || {
  usage >&2
  exit 2
}
[[ -d "$repo_dir" ]] || { echo "仓库目录不存在: $repo_dir" >&2; exit 2; }
[[ "$repo_path" != /* && "$repo_path" != -* ]] || {
  echo "--path 必须是仓库内相对路径" >&2
  exit 2
}
if [[ "$repo_path" == ../* || "$repo_path" == */../* || "$repo_path" == */.. ]]; then
  echo "--path 不允许跳出仓库目录" >&2
  exit 2
fi

git -c core.fsmonitor=false -C "$repo_dir" rev-parse --verify "$git_ref^{commit}" >/dev/null 2>&1 || {
  echo "Git ref 不存在或不是提交: $git_ref" >&2
  exit 2
}
git -c core.fsmonitor=false -C "$repo_dir" cat-file -e "$git_ref:$repo_path" 2>/dev/null || {
  echo "指定 ref 中不存在文件: $repo_path" >&2
  exit 2
}
[[ "$(git -c core.fsmonitor=false -C "$repo_dir" cat-file -t "$git_ref:$repo_path")" == "blob" ]] || {
  echo "指定路径不是普通文件: $repo_path" >&2
  exit 2
}
[[ ! -e "$output_file" && ! -L "$output_file" ]] || {
  echo "输出文件已存在或是符号链接，为避免覆盖请换一个路径: $output_file" >&2
  exit 2
}

git -c core.fsmonitor=false -C "$repo_dir" show "$git_ref:$repo_path" >"$output_file"
printf '已提取 context 快照: %s\n' "$output_file"
