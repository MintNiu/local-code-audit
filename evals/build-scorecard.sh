#!/usr/bin/env bash
set -euo pipefail

labels_dir=""
results_dir=""
output_file=""

usage() {
  cat <<'EOF'
用法:
  ./evals/build-scorecard.sh \
    --labels-dir ~/.local/share/local-review/evals/platform-api-labels \
    --results-dir ~/.local/share/local-review/evals/platform-api-results \
    [--out /tmp/platform-api-scorecard.tsv]

选项:
  --labels-dir <dir>   人工标签目录，只读取已标为 complete 的标签
  --results-dir <dir>  与标签对应的 .txt 和 .meta.tsv 结果目录
  --out <file>         输出 TSV；省略时写到 stdout

脚本不会修改标签或结果。uncertain finding 不计入指标；只有
review_status=complete 的提交才会输出到 scorecard。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --labels-dir)
      [[ $# -ge 2 ]] || { echo "--labels-dir 需要目录" >&2; exit 2; }
      labels_dir="$2"
      shift 2
      ;;
    --results-dir)
      [[ $# -ge 2 ]] || { echo "--results-dir 需要目录" >&2; exit 2; }
      results_dir="$2"
      shift 2
      ;;
    --out)
      [[ $# -ge 2 ]] || { echo "--out 需要文件" >&2; exit 2; }
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

[[ -d "$labels_dir" ]] || { echo "标签目录不存在: $labels_dir" >&2; exit 2; }
[[ -d "$results_dir" ]] || { echo "结果目录不存在: $results_dir" >&2; exit 2; }

temporary_output=""
if [[ -n "$output_file" ]]; then
  temporary_output="$(mktemp "${TMPDIR:-/tmp}/local-review-scorecard.XXXXXX")"
  trap 'rm -f "$temporary_output"' EXIT
fi

emit() {
  if [[ -n "$temporary_output" ]]; then
    printf '%s\n' "$1" >>"$temporary_output"
  else
    printf '%s\n' "$1"
  fi
}

emit $'commit\tmodel\ttemperature\tseed\tnum_ctx\tgold_p0_p1\tp0_p1_found\tpredicted_candidates\tfalse_positive_count\toutput_complete\telapsed_seconds'

label_count=0
while IFS= read -r label_file; do
  [[ -f "$label_file" ]] || continue
  review_status="$(awk -F '\t' '$1 == "# review_status" { print $2; exit }' "$label_file")"
  [[ "$review_status" == "complete" ]] || continue
  verdict="$(awk -F '\t' '$1 == "# verdict" { print $2; exit }' "$label_file")"
  case "$verdict" in
    clean|findings) ;;
    *)
      echo "标签缺少有效 verdict（必须是 clean 或 findings）: $label_file" >&2
      exit 1
      ;;
  esac
  if [[ "$verdict" == "clean" ]]; then
    if awk -F '\t' '$1 !~ /^#/ && NF > 0 { found = 1 } END { exit(found ? 0 : 1) }' "$label_file"; then
      echo "verdict=clean 不能包含 finding 标签行: $label_file" >&2
      exit 1
    fi
  elif ! awk -F '\t' '$1 !~ /^#/ && NF >= 6 && ($5 == "confirmed" || $5 == "missed" || $5 == "false-positive") { found = 1 } END { exit(found ? 0 : 1) }' "$label_file"; then
    echo "verdict=findings 至少需要一条 confirmed、missed 或 false-positive 标签: $label_file" >&2
    exit 1
  fi
  commit="$(awk -F '\t' '$1 == "# commit" { print $2; exit }' "$label_file")"
  [[ "$commit" =~ ^[0-9a-fA-F]{7,64}$ ]] || {
    echo "标签缺少有效 commit: $label_file" >&2
    exit 1
  }
  meta_file="$results_dir/$commit.meta.tsv"
  result_file="$results_dir/$commit.txt"
  source_result="$(awk -F '\t' '$1 == "# source_result" { print $2; exit }' "$label_file")"
  source_result_sha256="$(awk -F '\t' '$1 == "# source_result_sha256" { print $2; exit }' "$label_file")"
  [[ -n "$source_result" && -n "$source_result_sha256" ]] || {
    echo "标签缺少 source_result 或 source_result_sha256，拒绝猜测配对: $commit" >&2
    exit 1
  }
  [[ "$source_result_sha256" =~ ^[0-9a-fA-F]{64}$ ]] || {
    echo "标签中的 source_result_sha256 无效: $commit" >&2
    exit 1
  }
  [[ -f "$meta_file" && -f "$result_file" ]] || {
    echo "缺少与标签对应的结果: $commit" >&2
    exit 1
  }
  result_sha256="$(shasum -a 256 "$result_file" | awk '{print $1}')"
  [[ "$source_result_sha256" == "$result_sha256" ]] || {
    echo "标签与结果内容不匹配，拒绝混用不同评测运行: $commit" >&2
    echo "  label source_result: $source_result" >&2
    echo "  label SHA-256:       $source_result_sha256" >&2
    echo "  result SHA-256:      $result_sha256" >&2
    exit 1
  }

  status="$(awk -F '\t' '$1 == "status" { print $2; exit }' "$meta_file")"
  exit_code="$(awk -F '\t' '$1 == "exit_code" { print $2; exit }' "$meta_file")"
  [[ "$status" == "completed" && "$exit_code" == "0" ]] || {
    echo "标签标为 complete 但运行未成功: $commit" >&2
    exit 1
  }
  output_complete="$(awk -F '\t' '$1 == "output_complete" { print $2; exit }' "$meta_file")"
  [[ "$output_complete" == "true" ]] || {
    echo "标签标为 complete 但结果没有 output_complete=true: $commit" >&2
    exit 1
  }

  model="$(awk -F '\t' '$1 == "resolved_model" { print $2; exit }' "$meta_file")"
  temperature="$(awk -F '\t' '$1 == "temperature" { print $2; exit }' "$meta_file")"
  seed="$(awk -F '\t' '$1 == "seed" { print $2; exit }' "$meta_file")"
  num_ctx="$(awk -F '\t' '$1 == "num_ctx" { print $2; exit }' "$meta_file")"
  elapsed="$(awk -F '\t' '$1 == "elapsed_seconds" { print $2; exit }' "$meta_file")"
  for value_name in model temperature seed num_ctx elapsed; do
    value="${!value_name}"
    [[ -n "$value" ]] || { echo "metadata 缺少 $value_name: $commit" >&2; exit 1; }
  done

  gold="$(awk -F '\t' '$1 !~ /^#/ && NF >= 6 && ($5 == "confirmed" || $5 == "missed") && ($2 == "P0" || $2 == "P1") { n++ } END { print n + 0 }' "$label_file")"
  found="$(awk -F '\t' '$1 !~ /^#/ && NF >= 6 && $5 == "confirmed" && ($2 == "P0" || $2 == "P1") { n++ } END { print n + 0 }' "$label_file")"
  false_positives="$(awk -F '\t' '$1 !~ /^#/ && NF >= 6 && $5 == "false-positive" { n++ } END { print n + 0 }' "$label_file")"
  candidates="$(grep -Ec '^(P[0-3]|信息) ' "$result_file" || true)"
  [[ "$candidates" =~ ^[0-9]+$ ]] || { echo "无法统计候选数: $commit" >&2; exit 1; }
  confirmed_count="$(awk -F '\t' '$1 !~ /^#/ && NF >= 6 && $5 == "confirmed" && ($2 == "P0" || $2 == "P1") { n++ } END { print n + 0 }' "$label_file")"
  if [[ "$confirmed_count" -gt "$candidates" ]]; then
    echo "模型命中的 P0/P1 多于结果候选数: $commit" >&2
    exit 1
  fi
  if [[ "$false_positives" -gt "$candidates" ]]; then
    echo "人工标记的误报多于结果中的模型候选数: ${commit}；标签与结果可能不匹配" >&2
    exit 1
  fi
  # Candidate counts alone do not prove that the label was made from this
  # result. Require every confirmed/false-positive location to overlap a
  # visible finding in the selected result. Location overlap does not identify
  # a root cause: a human-recorded `missed` row can share lines with a different
  # visible finding. Its evidence notes, not location alone, explain the miss.
  while IFS=$'\t' read -r finding_id finding_severity finding_path finding_line finding_status finding_notes _; do
    [[ -n "$finding_id" && "$finding_id" != \#* ]] || continue
    case "$finding_status" in
      confirmed|false-positive) ;;
      missed)
        [[ "$finding_severity" =~ ^P[01]$ ]] || {
          echo "missed 标签只能记录 P0/P1 根因: $commit $finding_id" >&2
          exit 1
        }
        [[ "$finding_path" =~ ^[^[:space:]]+$ && "$finding_path" != /* && "/$finding_path/" != */../* && "/$finding_path/" != */./* && "$finding_line" =~ ^[1-9][0-9]*(-[1-9][0-9]*)?$ && "$finding_notes" =~ [^[:space:]] ]] || {
          echo "missed 标签缺少有效路径、行号或证据备注: $commit $finding_id" >&2
          exit 1
        }
        # Compare decimal strings by length, then lexically, to avoid shell
        # integer overflow for malformed labels containing very large numbers.
        line_start="${finding_line%%-*}"
        line_end="${finding_line##*-}"
        if [[ ${#line_end} -lt ${#line_start} || ( ${#line_end} -eq ${#line_start} && "$line_end" < "$line_start" ) ]]; then
          echo "missed 标签行号范围必须正序: $commit $finding_id" >&2
          exit 1
        fi
        continue
        ;;
      uncertain) continue ;;
      *)
        echo "标签包含未知 finding status: $commit $finding_id" >&2
        exit 1
        ;;
    esac
    if ! awk -v want_path="$finding_path" -v want_line="$finding_line" '
      function range_start(value, fields) { split(value, fields, "-"); return fields[1] + 0 }
      function range_end(value, fields) { split(value, fields, "-"); return (fields[2] == "" ? fields[1] : fields[2]) + 0 }
      function ranges_overlap(candidate, wanted, candidate_ranges, wanted_ranges, candidate_count, wanted_count, i, j) {
        candidate_count = split(candidate, candidate_ranges, /[,，]/)
        wanted_count = split(wanted, wanted_ranges, /[,，]/)
        for (i = 1; i <= candidate_count; i++) {
          for (j = 1; j <= wanted_count; j++) {
            if (range_end(candidate_ranges[i]) >= range_start(wanted_ranges[j]) &&
                range_end(wanted_ranges[j]) >= range_start(candidate_ranges[i])) return 1
          }
        }
        return 0
      }
      /^(P[0-3]|信息) / {
        location = $2
        candidate_path = location
        sub(/:[0-9]+([[:space:]]*-[[:space:]]*[0-9]+)?([,，][[:space:]]*[0-9]+([[:space:]]*-[[:space:]]*[0-9]+)?)*$/, "", candidate_path)
        candidate_line = location
        sub(/^.*:/, "", candidate_line)
        if (candidate_path != want_path) next
        if (ranges_overlap(candidate_line, want_line)) found = 1
      }
      END { exit(found ? 0 : 1) }
    ' "$result_file"; then
      echo "标签定位不在结果候选中，拒绝汇总: $commit $finding_path:$finding_line" >&2
      exit 1
    fi
  done <"$label_file"
  emit "$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\ttrue\t%s' \
    "$commit" "$model" "$temperature" "$seed" "$num_ctx" "$gold" "$found" \
    "$candidates" "$false_positives" "$elapsed")"
  label_count=$((label_count + 1))
done < <(find "$labels_dir" -type f -name '*.labels.tsv' -print | LC_ALL=C sort)

(( label_count > 0 )) || { echo "没有找到 review_status=complete 的标签" >&2; exit 1; }
if [[ -n "$temporary_output" ]]; then
  mv "$temporary_output" "$output_file"
  temporary_output=""
fi
printf 'scorecard rows built: %d\n' "$label_count" >&2
