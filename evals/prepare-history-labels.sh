#!/usr/bin/env bash
set -euo pipefail

manifest_file=""
results_dir=""
labels_dir=""
only_commit=""

usage() {
  cat <<'EOF'
用法:
  ./evals/prepare-history-labels.sh \
    --manifest ~/.local/share/local-review/evals/platform-api-20.tsv \
    --results ~/.local/share/local-review/evals/platform-api-results \
    --labels-dir ~/.local/share/local-review/evals/platform-api-labels

选项:
  --manifest <file>       私有历史提交清单
  --results <dir>         run-history.sh 生成的私有结果目录
  --labels-dir <dir>      标签模板输出目录
  --commit <sha>          只为指定提交生成模板

脚本只创建缺失的 .labels.tsv，不覆盖已有人工标签。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest)
      [[ $# -ge 2 ]] || { echo "--manifest 需要文件" >&2; exit 2; }
      manifest_file="$2"
      shift 2
      ;;
    --results)
      [[ $# -ge 2 ]] || { echo "--results 需要目录" >&2; exit 2; }
      results_dir="$2"
      shift 2
      ;;
    --labels-dir)
      [[ $# -ge 2 ]] || { echo "--labels-dir 需要目录" >&2; exit 2; }
      labels_dir="$2"
      shift 2
      ;;
    --commit)
      [[ $# -ge 2 ]] || { echo "--commit 需要提交 SHA" >&2; exit 2; }
      only_commit="$2"
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

[[ -f "$manifest_file" ]] || { echo "清单文件不存在: $manifest_file" >&2; exit 2; }
[[ -d "$results_dir" ]] || { echo "结果目录不存在: $results_dir" >&2; exit 2; }
[[ -n "$labels_dir" ]] || { usage >&2; exit 2; }

mkdir -p "$labels_dir"
created=0
skipped=0
missing=0

while IFS=$'\t' read -r commit parent date subject status _rest; do
  [[ "$commit" == "commit" || -z "$commit" ]] && continue
  [[ "$status" == "pending-human-label" ]] || continue
  [[ -z "$only_commit" || "$commit" == "$only_commit" ]] || continue

  metadata_file="$results_dir/$commit.meta.tsv"
  result_file="$results_dir/$commit.txt"
  label_file="$labels_dir/$commit.labels.tsv"

  if [[ ! -f "$metadata_file" && ! -f "$result_file" ]]; then
    printf '跳过 %s：还没有模型结果\n' "$commit" >&2
    missing=$((missing + 1))
    continue
  fi

  if [[ -e "$label_file" ]]; then
    printf '保留已有标签: %s\n' "$label_file"
    skipped=$((skipped + 1))
    continue
  fi

  {
    printf '# commit\t%s\n' "$commit"
    printf '# parent\t%s\n' "$parent"
    printf '# date\t%s\n' "$date"
    printf '# subject\t%s\n' "$subject"
    printf '# source_result\t%s\n' "$result_file"
    printf '#\n'
    printf '# 先阅读 source_result，再逐条记录模型发现和人工真值。\n'
    printf '# status 只能是 confirmed、false-positive 或 uncertain。\n'
    printf '# confirmed 表示代码/契约支持；false-positive 表示人工确认不成立；uncertain 不计入指标。\n'
    printf '# finding_id\tseverity\tpath\tline\tstatus\tnotes\n'
  } >"$label_file"
  printf '已创建标签模板: %s\n' "$label_file"
  created=$((created + 1))
done < <(tail -n +2 "$manifest_file")

printf 'label templates: created=%s skipped=%s missing-results=%s\n' "$created" "$skipped" "$missing"
