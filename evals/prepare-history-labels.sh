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
command -v shasum >/dev/null 2>&1 || { echo "生成标签需要 shasum 记录 manifest 版本。" >&2; exit 2; }

validate_manifest_input() {
  local input_file="$1"
  if ! LC_ALL=C perl -ne '
    if (/[\x00-\x08\x0B\x0C\x0D\x0E-\x1F\x7F]/) {
      printf "清单第 %d 行包含不可安全写入 TSV 的控制字符。\n", $.;
      exit 1
    }
  ' "$input_file"; then
    echo "拒绝使用包含控制字符的 manifest: $input_file" >&2
    return 1
  fi
  if ! LC_ALL=C awk -F '\t' '
    function fail(message) {
      printf "清单第 %d 行无效：%s\n", NR, message > "/dev/stderr"
      bad = 1
    }
    NR == 1 {
      if (NF < 5 || $1 != "commit" || $2 != "parent" || $3 != "date" || $4 != "subject" || $5 != "status") {
        fail("首行必须以 commit、parent、date、subject、status 为前五列")
      }
      expected_fields = NF
      next
    }
    /^[[:space:]]*$/ { next }
    {
      if (NF != expected_fields) fail("列数与表头不一致，可能包含未转义的换行或制表符")
      if ($5 == "pending-human-label" &&
          ($1 !~ /^[0-9A-Fa-f]{7,64}$/ || $2 !~ /^[0-9A-Fa-f]{7,64}$/)) {
        fail("pending-human-label 行的 commit 和 parent 必须是 7-64 位十六进制")
      }
    }
    END {
      if (NR == 0) {
        print "清单为空，缺少表头" > "/dev/stderr"
        bad = 1
      }
      exit bad
    }
  ' "$input_file"; then
    echo "拒绝使用结构不完整或路径不安全的 manifest: $input_file" >&2
    return 1
  fi
}
validate_manifest_input "$manifest_file" || exit 2

label_temp_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-labels.XXXXXX")"
trap 'rm -rf "$label_temp_root"' EXIT
manifest_snapshot="$label_temp_root/manifest.tsv"
if ! cp "$manifest_file" "$manifest_snapshot"; then
  echo "无法冻结 manifest，拒绝生成可能漂移的标签: $manifest_file" >&2
  exit 1
fi
manifest_sha256="$(shasum -a 256 "$manifest_snapshot" | awk '{print $1}')"
[[ "$manifest_sha256" =~ ^[0-9a-fA-F]{64}$ ]] || {
  echo "无法计算 manifest 的 SHA-256，拒绝生成可能漂移的标签。" >&2
  exit 1
}

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

  if [[ ! -f "$metadata_file" ]]; then
    if [[ -f "$result_file" ]]; then
      echo "结果缺少 run-history metadata，无法验证 manifest 来源: $commit" >&2
      exit 1
    fi
    printf '跳过 %s：还没有模型结果\n' "$commit" >&2
    missing=$((missing + 1))
    continue
  fi

  metadata_manifest_sha256="$(awk -F '\t' '$1 == "manifest_sha256" { print $2; exit }' "$metadata_file")"
  if [[ "$metadata_manifest_sha256" != "$manifest_sha256" ]]; then
    echo "结果与当前 manifest 不一致，拒绝生成标签: $commit" >&2
    echo "  结果 manifest_sha256=${metadata_manifest_sha256:-<missing>} 当前=${manifest_sha256}" >&2
    exit 1
  fi
  metadata_commit="$(awk -F '\t' '$1 == "commit" { print $2; exit }' "$metadata_file")"
  metadata_parent="$(awk -F '\t' '$1 == "parent" { print $2; exit }' "$metadata_file")"
  [[ "$metadata_commit" == "$commit" && "$metadata_parent" == "$parent" ]] || {
    echo "结果的 commit/parent 与当前 manifest 不一致，拒绝生成标签: $commit" >&2
    exit 1
  }

  if [[ -e "$label_file" ]]; then
    printf '保留已有标签: %s\n' "$label_file"
    skipped=$((skipped + 1))
    continue
  fi

  source_result_sha256=""
  source_result_sha256="$(awk -F '\t' '$1 == "result_sha256" { print $2; exit }' "$metadata_file")"
  if [[ -z "$source_result_sha256" && -f "$result_file" ]]; then
    source_result_sha256="$(shasum -a 256 "$result_file" | awk '{print $1}')"
  fi
  [[ "$source_result_sha256" =~ ^[0-9a-fA-F]{64}$ ]] || {
    echo "结果缺少可记录的 SHA-256，无法创建可迁移标签: $commit" >&2
    exit 1
  }

  {
    printf '# commit\t%s\n' "$commit"
    printf '# parent\t%s\n' "$parent"
    printf '# date\t%s\n' "$date"
    printf '# subject\t%s\n' "$subject"
    printf '# source_result\t%s\n' "$result_file"
    printf '# source_result_sha256\t%s\n' "$source_result_sha256"
    printf '#\n'
    printf '# 先阅读 source_result，再逐条记录模型发现和人工真值。\n'
    printf '# status 只能是 confirmed、missed、false-positive 或 uncertain。\n'
    printf '# confirmed 表示模型命中且代码/契约支持；missed 表示人工确认的问题未出现在模型结果中；false-positive 表示人工确认不成立；uncertain 不计入指标。\n'
    printf '# verdict	人工填写 clean 或 findings，分别表示整次结果无问题或包含已确认问题。\n'
    printf '# review_status	人工填写 pending 或 complete；只有 complete 才能进入汇总。\n'
    printf '# split	阶段一人工填写 train、dev 或 holdout；按功能簇整体切分，禁止泄漏。\n'
    printf '# feature_cluster	阶段一人工填写稳定的功能簇标识，例如 hr-directory-contract。\n'
    printf '# location_accurate	阶段一人工填写定位准确的已命中 P0/P1 根因数。\n'
    printf '# repeat_stable	阶段一人工根据两次相同运行的结果哈希和运行签名填写 true 或 false。\n'
    printf '# finding_id\tseverity\tpath\tline\tstatus\tnotes\n'
  } >"$label_file"
  printf '已创建标签模板: %s\n' "$label_file"
  created=$((created + 1))
done < <(tail -n +2 "$manifest_snapshot")

printf 'label templates: created=%s skipped=%s missing-results=%s\n' "$created" "$skipped" "$missing"
