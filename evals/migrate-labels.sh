#!/usr/bin/env bash
set -euo pipefail

labels_dir=""
from_results_dir=""
to_results_dir=""
output_dir=""

usage() {
  cat <<'EOF'
用法:
  ./evals/migrate-labels.sh \
    --labels-dir ~/.local/share/local-review/evals/labels-old \
    --from-results-dir ~/.local/share/local-review/evals/results-old \
    --to-results-dir ~/.local/share/local-review/evals/results-new \
    --out-labels-dir ~/.local/share/local-review/evals/labels-new

选项:
  --labels-dir <dir>       原人工标签目录
  --from-results-dir <dir> 原标签对应的结果目录
  --to-results-dir <dir>   新结果目录
  --out-labels-dir <dir>   新标签目录；必须不存在，避免覆盖人工标签

只有新旧结果文本 SHA-256 完全一致的 complete 标签才会迁移；内容变化、
缺少结果、标签不完整或标签中的确认/误报条目多于结果候选的提交会被跳过并要求重新人工复核。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --labels-dir|--from-results-dir|--to-results-dir|--out-labels-dir)
      [[ $# -ge 2 ]] || { echo "$1 需要目录" >&2; exit 2; }
      case "$1" in
        --labels-dir) labels_dir="$2" ;;
        --from-results-dir) from_results_dir="$2" ;;
        --to-results-dir) to_results_dir="$2" ;;
        --out-labels-dir) output_dir="$2" ;;
      esac
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

[[ -d "$labels_dir" ]] || { echo "标签目录不存在: $labels_dir" >&2; exit 2; }
[[ -d "$from_results_dir" ]] || { echo "原结果目录不存在: $from_results_dir" >&2; exit 2; }
[[ -d "$to_results_dir" ]] || { echo "新结果目录不存在: $to_results_dir" >&2; exit 2; }
[[ -n "$output_dir" ]] || { echo "--out-labels-dir 是必需参数" >&2; exit 2; }
[[ ! -e "$output_dir" ]] || { echo "拒绝覆盖已有标签目录: $output_dir" >&2; exit 2; }
mkdir -p "$output_dir"

temporary_file="$(mktemp "${TMPDIR:-/tmp}/local-review-label-migration.XXXXXX")"
trap 'rm -f "$temporary_file"' EXIT
migrated=0
skipped=0

while IFS= read -r label_file; do
  [[ -f "$label_file" ]] || continue
  review_status="$(awk -F '\t' '$1 == "# review_status" { print $2; exit }' "$label_file")"
  if [[ "$review_status" != "complete" ]]; then
    skipped=$((skipped + 1))
    continue
  fi
  commit="$(awk -F '\t' '$1 == "# commit" { print $2; exit }' "$label_file")"
  [[ "$commit" =~ ^[0-9a-fA-F]{7,64}$ ]] || {
    echo "跳过无效 commit 标签: $label_file" >&2
    skipped=$((skipped + 1))
    continue
  }
  label_hash="$(awk -F '\t' '$1 == "# source_result_sha256" { print $2; exit }' "$label_file")"
  old_result="$from_results_dir/${commit}.txt"
  if [[ ! -f "$old_result" ]]; then
    echo "跳过 ${commit}：原结果目录缺少结果文件" >&2
    skipped=$((skipped + 1))
    continue
  fi
  old_hash="$(shasum -a 256 "$old_result" | awk '{print $1}')"
  if [[ "$label_hash" =~ ^[0-9a-fA-F]{64}$ && "$label_hash" != "$old_hash" ]]; then
    echo "跳过 ${commit}：标签哈希与原结果不一致" >&2
    skipped=$((skipped + 1))
    continue
  fi
  new_result="$to_results_dir/${commit}.txt"
  if [[ ! -f "$new_result" ]]; then
    echo "跳过 ${commit}：新结果缺失" >&2
    skipped=$((skipped + 1))
    continue
  fi
  new_hash="$(shasum -a 256 "$new_result" | awk '{print $1}')"
  if [[ "$old_hash" != "$new_hash" ]]; then
    echo "跳过 ${commit}：结果内容已变化，必须重新人工标注" >&2
    skipped=$((skipped + 1))
    continue
  fi

  # A byte-identical result is not sufficient when an older label file was
  # assembled from a different/raw model response. Refuse to migrate labels
  # that claim more confirmed or false-positive findings than the final
  # result visibly contains; otherwise a later scorecard could silently pair
  # clean output with stale findings.
  candidate_count="$(grep -Ec '^(P[0-3]|信息) ' "$new_result" || true)"
  confirmed_count="$(awk -F '\t' '$1 !~ /^#/ && NF >= 6 && $5 == "confirmed" { n++ } END { print n + 0 }' "$label_file")"
  false_positive_count="$(awk -F '\t' '$1 !~ /^#/ && NF >= 6 && $5 == "false-positive" { n++ } END { print n + 0 }' "$label_file")"
  if (( confirmed_count > candidate_count || false_positive_count > candidate_count )); then
    echo "跳过 ${commit}：标签条目多于最终结果候选，可能来自不同/原始模型响应；必须重新人工标注" >&2
    skipped=$((skipped + 1))
    continue
  fi
  location_mismatch=false
  while IFS=$'\t' read -r finding_id finding_severity finding_path finding_line finding_status finding_notes _; do
    [[ -n "$finding_id" && "$finding_id" != \#* ]] || continue
    case "$finding_status" in
      confirmed|false-positive) ;;
      missed) continue ;;
      *) continue ;;
    esac
    if ! awk -v want_path="$finding_path" -v want_line="$finding_line" '
      function range_start(value, fields) { split(value, fields, "-"); return fields[1] + 0 }
      function range_end(value, fields) { split(value, fields, "-"); return (fields[2] == "" ? fields[1] : fields[2]) + 0 }
      /^(P[0-3]|信息) / {
        location = $2
        candidate_path = location
        sub(/:[0-9]+(-[0-9]+)?$/, "", candidate_path)
        candidate_line = location
        sub(/^.*:/, "", candidate_line)
        if (candidate_path != want_path) next
        if (range_end(candidate_line) >= range_start(want_line) && range_end(want_line) >= range_start(candidate_line)) found = 1
      }
      END { exit(found ? 0 : 1) }
    ' "$new_result"; then
      location_mismatch=true
      break
    fi
  done <"$label_file"
  if [[ "$location_mismatch" == true ]]; then
    echo "跳过 ${commit}：标签定位不在最终结果候选中，可能来自不同/原始模型响应；必须重新人工标注" >&2
    skipped=$((skipped + 1))
    continue
  fi

  destination="$output_dir/$(basename "$label_file")"
  awk -F '\t' -v result="$new_result" -v hash="$new_hash" '
    $1 == "# source_result" { print "# source_result\t" result; saw_result = 1; next }
    $1 == "# source_result_sha256" { print "# source_result_sha256\t" hash; saw_hash = 1; next }
    { print }
    END {
      if (!saw_result) print "# source_result\t" result
      if (!saw_hash) print "# source_result_sha256\t" hash
    }
  ' "$label_file" >"$temporary_file"
  mv "$temporary_file" "$destination"
  temporary_file="$(mktemp "${TMPDIR:-/tmp}/local-review-label-migration.XXXXXX")"
  migrated=$((migrated + 1))
done < <(find "$labels_dir" -type f -name '*.labels.tsv' -print | LC_ALL=C sort)

(( migrated > 0 )) || {
  echo "没有可安全迁移的 complete 标签" >&2
  exit 1
}
printf 'label migration passed: migrated=%d skipped=%d output=%s\n' "$migrated" "$skipped" "$output_dir"
