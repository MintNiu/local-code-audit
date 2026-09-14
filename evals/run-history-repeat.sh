#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runs=3
output_dir=""
forward_args=()

usage() {
  cat <<'EOF'
用法:
  ./evals/run-history-repeat.sh \
    --repo /path/to/local/repo \
    --manifest ~/.local/share/local-review/evals/manifest.tsv \
    --out-dir ~/.local/share/local-review/evals/repeated-results

选项:
  --runs <n>        每个历史提交重复运行次数，默认 3
  --repo <dir>      转发给 run-history.sh 的仓库目录
  --manifest <file> 转发给 run-history.sh 的历史清单
  --out-dir <dir>   根目录；每次结果写入 run-1、run-2 等子目录
  --limit <n>       只评测前 n 个 pending-human-label 提交
  --commit <sha>    只评测指定提交
  --profile <name>  personal（默认）或 baseline
  --context <file>  转发跨仓库 context 文件，可重复指定
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs)
      [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || {
        echo "--runs 必须是正整数。" >&2
        exit 2
      }
      runs="$2"
      shift 2
      ;;
    --out-dir)
      [[ $# -ge 2 ]] || { echo "--out-dir 需要目录。" >&2; exit 2; }
      output_dir="$2"
      shift 2
      ;;
    --repo|--manifest|--limit|--commit|--profile|--context)
      [[ $# -ge 2 ]] || { echo "$1 需要参数。" >&2; exit 2; }
      forward_args+=("$1" "$2")
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

[[ -n "$output_dir" ]] || { echo "--out-dir 是必需参数。" >&2; exit 2; }
mkdir -p "$output_dir"

for ((run = 1; run <= runs; run++)); do
  run_dir="$output_dir/run-$run"
  if [[ -e "$run_dir" ]]; then
    echo "拒绝覆盖已有重复评测目录: $run_dir" >&2
    exit 2
  fi
  "$repo_root/evals/run-history.sh" "${forward_args[@]}" --out-dir "$run_dir"
done

baseline_dir="$output_dir/run-1"
baseline_files=()
while IFS= read -r result_file; do
  baseline_files+=("$result_file")
done < <(find "$baseline_dir" -type f -name '*.txt' -print | LC_ALL=C sort)
(( ${#baseline_files[@]} > 0 )) || {
  echo "重复评测没有生成结果文件。" >&2
  exit 1
}

for ((run = 2; run <= runs; run++)); do
  run_dir="$output_dir/run-$run"
  current_files=()
  while IFS= read -r result_file; do
    current_files+=("$result_file")
  done < <(find "$run_dir" -type f -name '*.txt' -print | LC_ALL=C sort)
  if [[ "${#current_files[@]}" != "${#baseline_files[@]}" ]]; then
    echo "历史评测第 $run 轮结果文件数量变化: ${#baseline_files[@]} -> ${#current_files[@]}" >&2
    exit 1
  fi
  for baseline_file in "${baseline_files[@]}"; do
    relative_file="${baseline_file#"$baseline_dir/"}"
    current_file="$run_dir/$relative_file"
    [[ -f "$current_file" ]] || {
      echo "历史评测第 $run 轮缺少结果: $relative_file" >&2
      exit 1
    }
    if ! cmp -s "$baseline_file" "$current_file"; then
      echo "历史评测输出漂移: $relative_file（run-1 vs run-$run）" >&2
      diff -u "$baseline_file" "$current_file" >&2 || true
      exit 1
    fi
  done
done

printf 'history repeat stability passed: runs=%d, commits=%d, output=%s\n' \
  "$runs" "${#baseline_files[@]}" "$output_dir"
