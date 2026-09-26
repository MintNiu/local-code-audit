#!/usr/bin/env bash
set -euo pipefail

repo_dir=""
manifest_file=""
output_dir=""
limit=""
commit_filter=""
profile="personal"
context_files=()

usage() {
  cat <<'EOF'
用法:
  ./evals/run-history.sh \
    --repo /path/to/local/repo \
    --manifest ~/.local/share/local-review/evals/platform-api-20.tsv \
    --out-dir ~/.local/share/local-review/evals/platform-api-results

选项:
  --repo <dir>       本地 Git 仓库，只读读取提交和差异
  --manifest <file>  私有 TSV 清单，第一行必须是表头
                     parent 必须是 commit 的直接父；合并提交可选任一直接父
  --out-dir <dir>    私有结果目录，不要指向公开仓库
  --limit <n>        只运行前 n 个 pending-human-label 提交
  --commit <sha>     只运行指定的 pending-human-label 提交
  --profile <name>   使用 personal（默认，个人高性能）或 baseline profile
  --context <file>   附加跨仓库或外部消费者上下文文件，可重复指定
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || { echo "--repo 需要目录" >&2; exit 2; }
      repo_dir="$2"
      shift 2
      ;;
    --manifest)
      [[ $# -ge 2 ]] || { echo "--manifest 需要文件" >&2; exit 2; }
      manifest_file="$2"
      shift 2
      ;;
    --out-dir)
      [[ $# -ge 2 ]] || { echo "--out-dir 需要目录" >&2; exit 2; }
      output_dir="$2"
      shift 2
      ;;
    --limit)
      [[ $# -ge 2 ]] || { echo "--limit 需要正整数" >&2; exit 2; }
      limit="$2"
      shift 2
      ;;
    --commit)
      [[ $# -ge 2 ]] || { echo "--commit 需要提交 SHA" >&2; exit 2; }
      commit_filter="$2"
      shift 2
      ;;
    --profile)
      [[ $# -ge 2 ]] || { echo "--profile 需要 personal 或 baseline" >&2; exit 2; }
      [[ "$2" == "personal" || "$2" == "baseline" ]] || {
        echo "--profile 只能是 personal 或 baseline" >&2
        exit 2
      }
      profile="$2"
      shift 2
      ;;
    --context)
      [[ $# -ge 2 ]] || { echo "--context 需要文件" >&2; exit 2; }
      context_files+=("$2")
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

[[ -n "$repo_dir" && -n "$manifest_file" && -n "$output_dir" ]] || { usage >&2; exit 2; }
[[ -d "$repo_dir" ]] || { echo "仓库目录不存在: $repo_dir" >&2; exit 2; }
[[ -f "$manifest_file" ]] || { echo "清单文件不存在: $manifest_file" >&2; exit 2; }
if (( ${#context_files[@]} > 0 )); then
  resolved_context_files=()
  for context_file in "${context_files[@]}"; do
    context_path="$context_file"
    if [[ "$context_path" != /* ]]; then
      if [[ -f "$context_path" ]]; then
        context_path="$(cd "$(dirname "$context_path")" && pwd)/$(basename "$context_path")"
      elif [[ -f "$repo_dir/$context_path" ]]; then
        context_path="$(cd "$repo_dir" && pwd)/$context_path"
      else
        echo "--context 文件不存在（按当前目录或 --repo 根目录解析）: $context_file" >&2
        exit 2
      fi
    elif [[ ! -f "$context_path" ]]; then
      echo "--context 文件不存在: $context_file" >&2
      exit 2
    fi
    resolved_context_files+=("$context_path")
  done
  context_files=("${resolved_context_files[@]}")
fi
if (( ${#context_files[@]} > 0 )); then
  if ! command -v shasum >/dev/null 2>&1; then
    echo "使用 --context 时需要 shasum 以记录上下文版本哈希。" >&2
    exit 2
  fi
  if ! command -v realpath >/dev/null 2>&1; then
    echo "使用 --context 时需要 realpath 以规范化上下文路径。" >&2
    exit 2
  fi
  normalized_context_files=()
  for context_path in "${context_files[@]}"; do
    if ! context_path="$(realpath "$context_path")"; then
      echo "无法规范化 --context 路径: $context_path" >&2
      exit 2
    fi
    normalized_context_files+=("$context_path")
  done
  context_files=("${normalized_context_files[@]}")
fi
git -c core.fsmonitor=false -C "$repo_dir" rev-parse --show-toplevel >/dev/null 2>&1 || {
  echo "--repo 不是 Git 仓库: $repo_dir" >&2
  exit 2
}

if [[ -n "$limit" && ! "$limit" =~ ^[1-9][0-9]*$ ]]; then
  echo "--limit 必须是正整数。" >&2
  exit 2
fi

mkdir -p "$output_dir"
temp_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-history.XXXXXX")"
trap 'rm -rf "$temp_root"' EXIT
seen_commits_file="$temp_root/seen-commits"
: >"$seen_commits_file"

repo_root="$(git -c core.fsmonitor=false -C "$repo_dir" rev-parse --show-toplevel)"
if (( ${#context_files[@]} > 0 )); then
  for context_file in "${context_files[@]}"; do
    case "$context_file" in
      "$repo_root"/*)
        echo "--context 不能指向主仓库当前工作树；历史评测请先提取目标 ref 的私有快照: $context_file" >&2
        exit 2
        ;;
    esac
  done
fi
workflow_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v shasum >/dev/null 2>&1 || { echo "历史评测需要 shasum 记录审计器版本。" >&2; exit 2; }
workflow_git_revision="$(git -C "$workflow_root" rev-parse HEAD 2>/dev/null || printf 'not-a-git-checkout')"
workflow_dirty="$(git -C "$workflow_root" status --short 2>/dev/null | shasum -a 256 | awk '{print $1}')"
# Freeze the wrapper and its sibling implementation together. Executing an
# already-open shell script is not a snapshot: shells can read later sections
# after another process has edited the file, and wrappers resolve siblings at
# exec time. All commits in this invocation must use these exact same bytes.
review_snapshot="$temp_root/reviewer"
mkdir -p "$review_snapshot/bin"
reviewer_script_manifest() {
  local script_path
  for script_path in "$1"/*.sh; do
    [[ -f "$script_path" ]] || continue
    printf '%s\t%s\n' "${script_path##*/}" "$(shasum -a 256 "$script_path" | awk '{print $1}')"
  done | LC_ALL=C sort
}
reviewer_script_manifest "$workflow_root/bin" >"$temp_root/reviewer-before.tsv"
for script_path in "$workflow_root/bin"/*.sh; do
  [[ -f "$script_path" ]] || continue
  cp -p "$script_path" "$review_snapshot/bin/"
done
reviewer_script_manifest "$review_snapshot/bin" >"$temp_root/reviewer-snapshot.tsv"
reviewer_script_manifest "$workflow_root/bin" >"$temp_root/reviewer-after.tsv"
if ! cmp -s "$temp_root/reviewer-before.tsv" "$temp_root/reviewer-snapshot.tsv" || \
   ! cmp -s "$temp_root/reviewer-after.tsv" "$temp_root/reviewer-snapshot.tsv"; then
  echo "历史评测无效：冻结审计器期间 bin 脚本发生变化，请在编辑完成后重试。" >&2
  exit 12
fi
[[ -x "$review_snapshot/bin/local-review.sh" && -x "$review_snapshot/bin/local-review-local.sh" ]] || {
  echo "历史评测无效：审计器快照缺少可执行的 core 或 personal wrapper。" >&2
  exit 12
}
chmod a-w "$review_snapshot/bin/"*.sh
review_scripts_sha256="$(shasum -a 256 "$temp_root/reviewer-snapshot.tsv" | awk '{print $1}')"
review_core_sha256="$(shasum -a 256 "$review_snapshot/bin/local-review.sh" | awk '{print $1}')"
modelfile_path="$workflow_root/config/Modelfile"
modelfile_sha256="unavailable"
system_sha256="unavailable"
if [[ -f "$modelfile_path" ]]; then
  modelfile_sha256="$(shasum -a 256 "$modelfile_path" | awk '{print $1}')"
  system_tmp="$(mktemp "$temp_root/system.XXXXXX")"
  if awk '
    BEGIN { state = 0; blocks = 0 }
    state == 0 && $0 ~ /^SYSTEM[[:space:]]+"""[[:space:]]*$/ { state = 1; blocks++; next }
    state == 1 && $0 ~ /^"""[[:space:]]*$/ { state = 2; next }
    state == 1 { sub(/\r$/, ""); print; next }
    END { if (blocks != 1 || state != 2) exit 1 }
  ' "$modelfile_path" >"$system_tmp"; then
    system_sha256="$(shasum -a 256 "$system_tmp" | awk '{print $1}')"
  fi
fi
if [[ "$profile" == "personal" ]]; then
  review_script="$review_snapshot/bin/local-review-local.sh"
  profile_num_ctx="${OLLAMA_REVIEW_NUM_CTX:-16384}"
  profile_num_predict="${OLLAMA_REVIEW_NUM_PREDICT:-4096}"
  profile_max_diff_bytes="${OLLAMA_REVIEW_MAX_DIFF_BYTES:-3000}"
  profile_chunk_num_predict="${OLLAMA_REVIEW_CHUNK_NUM_PREDICT:-4096}"
  profile_keep_alive="${OLLAMA_REVIEW_KEEP_ALIVE:-5m}"
else
  review_script="$review_snapshot/bin/local-review.sh"
  profile_num_ctx="${OLLAMA_REVIEW_NUM_CTX:-16384}"
  profile_num_predict="${OLLAMA_REVIEW_NUM_PREDICT:-4096}"
  profile_max_diff_bytes="${OLLAMA_REVIEW_MAX_DIFF_BYTES:-3000}"
  profile_chunk_num_predict="${OLLAMA_REVIEW_CHUNK_NUM_PREDICT:-2048}"
  profile_keep_alive="${OLLAMA_REVIEW_KEEP_ALIVE:-0}"
fi
review_script_sha256="$(shasum -a 256 "$review_script" | awk '{print $1}')"
review_model="${OLLAMA_REVIEW_MODEL:-auto:tuned→review→base}"
review_temperature="${OLLAMA_REVIEW_TEMPERATURE:-0}"
review_seed="${OLLAMA_REVIEW_SEED:-42}"
review_top_k="${OLLAMA_REVIEW_TOP_K:-40}"
review_top_p="${OLLAMA_REVIEW_TOP_P:-0.9}"
count=0
manifest_row=1

record_invalid_range() {
  local invalid_id="$commit"
  # Invalid input must not be used as an output path (or overwrite a prior
  # successful result through path traversal).
  [[ "$invalid_id" =~ ^[0-9a-fA-F]{7,64}$ ]] || invalid_id="manifest-row-$manifest_row"
  : >"$output_dir/$invalid_id.txt"
  {
    printf 'commit\t%s\nparent\t%s\nsubject\t%s\n' "$commit" "$parent" "$subject"
    printf 'parent_policy\tany-direct-parent\n'
    printf 'status\tinvalid-range\nexit_code\t12\nfailure_reason\t%s\n' "$1"
    printf 'resolved_model\tnot-invoked\n'
  } >"$output_dir/$invalid_id.meta.tsv"
  echo "本次历史评测无效：$1 ($commit / $parent)，未调用审计器。" >&2
}

while IFS=$'\t' read -r commit parent date subject status _rest; do
  manifest_row=$((manifest_row + 1))
  [[ "$commit" == "commit" || -z "$commit" ]] && continue
  [[ "$status" == "pending-human-label" ]] || continue
  [[ -z "$commit_filter" || "$commit" == "$commit_filter" ]] || continue
  if grep -Fqx -- "$commit" "$seen_commits_file"; then
    echo "跳过重复提交清单行：$commit" >&2
    continue
  fi
  printf '%s\n' "$commit" >>"$seen_commits_file"
  if [[ -n "$limit" && "$count" -ge "$limit" ]]; then
    break
  fi

  if [[ ! "$commit" =~ ^[0-9a-fA-F]{7,64}$ || ! "$parent" =~ ^[0-9a-fA-F]{7,64}$ ]]; then
    record_invalid_range "non-hex-commit-or-parent"
    count=$((count + 1))
    continue
  fi
  if ! resolved_commit="$(git -c core.fsmonitor=false -C "$repo_root" rev-parse --verify "$commit^{commit}" 2>/dev/null)" || \
     ! resolved_parent="$(git -c core.fsmonitor=false -C "$repo_root" rev-parse --verify "$parent^{commit}" 2>/dev/null)"; then
    record_invalid_range "unresolvable-commit-or-parent"
    count=$((count + 1))
    continue
  fi
  # Use the commit object's parent list, not merge-base/ancestor membership.
  # A range spanning multiple commits is not a single-commit evaluation.
  # For a merge, selecting either direct parent is intentional and recorded.
  actual_parents="$(git --no-replace-objects -c core.fsmonitor=false -C "$repo_root" show -s --format=%P "$resolved_commit")"
  if [[ " $actual_parents " != *" $resolved_parent "* ]]; then
    record_invalid_range "parent-is-not-a-direct-parent"
    count=$((count + 1))
    continue
  fi

  worktree="$temp_root/$commit"
  patch_file="$temp_root/$commit.patch"
  result_file="$output_dir/$commit.txt"
  metadata_file="$output_dir/$commit.meta.tsv"
  : >"$result_file"
  mkdir -p "$worktree"

  if ! git --no-replace-objects -c core.fsmonitor=false -C "$repo_root" archive "$resolved_parent" | tar -xf - -C "$worktree"; then
    printf 'commit\t%s\nstatus\tarchive-failed\nsubject\t%s\n' "$commit" "$subject" >"$metadata_file"
    count=$((count + 1))
    continue
  fi

  git -C "$worktree" init -q
  git -C "$worktree" add -A
  git -C "$worktree" \
    -c user.name='local-review evaluation' \
    -c user.email='local-review-evaluation@localhost' \
    commit -qm 'evaluation parent snapshot'
  git --no-replace-objects -c core.fsmonitor=false -C "$repo_root" diff --binary --no-ext-diff --no-textconv "$resolved_parent" "$resolved_commit" >"$patch_file"
  diff_sha256="$(shasum -a 256 "$patch_file" | awk '{print $1}')"

  if ! git -C "$worktree" apply --whitespace=nowarn "$patch_file"; then
    printf 'commit\t%s\nstatus\tapply-failed\nsubject\t%s\n' "$commit" "$subject" >"$metadata_file"
    count=$((count + 1))
    continue
  fi

  start="$(date +%s)"
  exit_code=0
  failure_reason=""
  resolved_model_file="$temp_root/$commit.resolved-model"
  resolved_chunk_bytes_file="$temp_root/$commit.chunk-budget"
  resolved_trace_file="$temp_root/$commit.trace"
  review_stdout_file="$temp_root/$commit.stdout"
  review_stderr_file="$temp_root/$commit.stderr"
  : >"$review_stdout_file"
  : >"$review_stderr_file"
  resolved_model="unresolved"
  review_context_files=()
  context_hashes=()
  context_origins=()
  context_snapshot_dir="$temp_root/$commit.context"
  context_prepare_failed=false
  context_snapshot_complete=false
  if (( ${#context_files[@]} > 0 )); then
    context_snapshot_complete=true
    mkdir -p "$context_snapshot_dir"
    context_index=0
    for context_file in "${context_files[@]}"; do
      context_snapshot="$context_snapshot_dir/context-$context_index-${context_file##*/}"
      if ! cp "$context_file" "$context_snapshot"; then
        echo "本次历史评测无效：无法冻结 context 文件 $context_file。" >&2
        context_prepare_failed=true
        context_snapshot_complete=false
        break
      fi
      context_origins+=("$context_file")
      review_context_files+=("$context_snapshot")
      context_hashes+=("$(shasum -a 256 "$context_snapshot" | awk '{print $1}')")
      context_index=$((context_index + 1))
    done
  fi
  review_args=(--repo "$worktree")
  if (( ${#review_context_files[@]} > 0 )); then
    for context_snapshot in "${review_context_files[@]}"; do
      review_args+=(--context "$context_snapshot")
    done
  fi
  if [[ "$context_prepare_failed" == true ]]; then
    exit_code=12
    failure_reason="context-snapshot-failed"
  else
    LOCAL_REVIEW_RESOLVED_MODEL_FILE="$resolved_model_file" \
    OLLAMA_REVIEW_RESOLVED_CHUNK_BYTES_FILE="$resolved_chunk_bytes_file" \
    OLLAMA_REVIEW_TRACE_FILE="$resolved_trace_file" \
      "$review_script" "${review_args[@]}" >"$review_stdout_file" 2>"$review_stderr_file" || exit_code=$?
    if [[ "$exit_code" -eq 0 ]] && ! LC_ALL=C grep -q '[^[:space:]]' "$review_stdout_file"; then
      printf '本次历史评测无效：审计器 exit 0 但没有非空审查结果。\n' >>"$review_stderr_file"
      exit_code=12
      failure_reason="empty-review-output"
    fi
    if [[ "$exit_code" -eq 0 ]]; then
      # A successful retry may still have diagnostics from an earlier failed
      # transport attempt. Keep the review result machine-readable: stderr is
      # diagnostic metadata, never part of the finding text.
      cp "$review_stdout_file" "$result_file"
    else
      # Preserve both streams for failed runs so the private result remains
      # useful for diagnosis, while the non-zero status keeps it out of a
      # scorecard.
      {
        cat "$review_stderr_file"
        cat "$review_stdout_file"
      } >"$result_file"
      if [[ -s "$review_stderr_file" ]]; then
        cat "$review_stderr_file" >&2
      fi
    fi
  fi
  stderr_log_file="$output_dir/$commit.stderr.log"
  if [[ -s "$review_stderr_file" ]]; then
    cp "$review_stderr_file" "$stderr_log_file"
  else
    rm -f "$stderr_log_file"
  fi
  end="$(date +%s)"
  if [[ "$context_prepare_failed" == false && -f "$result_file" && ${#review_context_files[@]} -gt 0 ]]; then
    for context_index in "${!review_context_files[@]}"; do
      CONTEXT_FROM="${review_context_files[$context_index]}" \
      CONTEXT_TO="${context_origins[$context_index]}" \
        perl -0pi -e 's/\Q$ENV{CONTEXT_FROM}\E/$ENV{CONTEXT_TO}/g' "$result_file"
    done
  fi
  if [[ -s "$resolved_model_file" ]]; then
    resolved_model="$(head -n 1 "$resolved_model_file")"
  elif [[ "$exit_code" -eq 0 ]]; then
    echo "本次历史评测无效：审查成功但未记录实际模型名。" >&2
    exit_code=12
    failure_reason="missing-resolved-model"
  fi
  output_complete=false
  if [[ "$exit_code" -eq 0 && -f "$result_file" ]] && LC_ALL=C grep -q '[^[:space:]]' "$result_file"; then
    output_complete=true
  fi
  result_sha256="unavailable"
  if [[ -f "$result_file" ]]; then
    result_sha256="$(shasum -a 256 "$result_file" | awk '{print $1}')"
  fi
  {
    printf 'commit\t%s\n' "$commit"
    printf 'parent\t%s\n' "$parent"
    printf 'resolved_commit\t%s\nresolved_parent\t%s\n' "$resolved_commit" "$resolved_parent"
    printf 'parent_policy\tany-direct-parent\nparent_validation\tdirect-parent\n'
    printf 'date\t%s\n' "$date"
    printf 'subject\t%s\n' "$subject"
    printf 'diff_sha256\t%s\n' "$diff_sha256"
    printf 'profile\t%s\n' "$profile"
    printf 'workflow_git_revision\t%s\n' "$workflow_git_revision"
    printf 'workflow_dirty_state_sha256\t%s\n' "$workflow_dirty"
    printf 'review_script_sha256\t%s\n' "$review_script_sha256"
    printf 'review_core_sha256\t%s\n' "$review_core_sha256"
    printf 'review_scripts_sha256\t%s\nreview_scripts_snapshot\ttrue\n' "$review_scripts_sha256"
    while IFS=$'\t' read -r script_name script_hash; do
      printf 'review_script\tbin/%s\tsha256=%s\n' "$script_name" "$script_hash"
    done <"$temp_root/reviewer-snapshot.tsv"
    printf 'modelfile_sha256\t%s\n' "$modelfile_sha256"
    printf 'system_sha256\t%s\n' "$system_sha256"
    printf 'model\t%s\n' "$review_model"
    printf 'resolved_model\t%s\n' "$resolved_model"
    printf 'temperature\t%s\n' "$review_temperature"
    printf 'seed\t%s\n' "$review_seed"
    printf 'top_k\t%s\n' "$review_top_k"
    printf 'top_p\t%s\n' "$review_top_p"
    printf 'num_ctx\t%s\n' "$profile_num_ctx"
    printf 'num_predict\t%s\n' "$profile_num_predict"
    printf 'max_diff_bytes\t%s\n' "$profile_max_diff_bytes"
    printf 'chunk_num_predict\t%s\n' "$profile_chunk_num_predict"
    if [[ -s "$resolved_chunk_bytes_file" ]]; then
      while IFS=$'\t' read -r budget_key budget_value; do
        [[ -n "$budget_key" && -n "$budget_value" ]] || continue
        printf '%s\t%s\n' "$budget_key" "$budget_value"
      done <"$resolved_chunk_bytes_file"
    fi
    if [[ -s "$resolved_trace_file" ]]; then
      while IFS= read -r trace_line; do
        [[ -n "$trace_line" ]] || continue
        printf '%s\n' "$trace_line"
      done <"$resolved_trace_file"
    fi
    printf 'keep_alive\t%s\n' "$profile_keep_alive"
    if (( ${#context_origins[@]} > 0 )); then
      for context_index in "${!context_origins[@]}"; do
        printf 'context\t%s\tsha256=%s\n' \
          "${context_origins[$context_index]}" "${context_hashes[$context_index]}"
      done
    fi
    printf 'context_snapshot\t%s\n' "$context_snapshot_complete"
    if [[ "$exit_code" -eq 0 ]]; then
      printf 'status\tcompleted\n'
    else
      printf 'status\tfailed\n'
    fi
    printf 'exit_code\t%s\n' "$exit_code"
    printf 'output_complete\t%s\n' "$output_complete"
    printf 'failure_reason\t%s\n' "$failure_reason"
    printf 'elapsed_seconds\t%s\n' "$((end - start))"
    printf 'result_sha256\t%s\n' "$result_sha256"
    if [[ -f "$stderr_log_file" ]]; then
      printf 'stderr_sha256\t%s\n' "$(shasum -a 256 "$stderr_log_file" | awk '{print $1}')"
      printf 'stderr_file\t%s\n' "$stderr_log_file"
    else
      printf 'stderr_sha256\t%s\n' ""
    fi
    printf 'result_file\t%s\n' "$result_file"
  } >"$metadata_file"

  printf '%s exit=%s elapsed=%ss result=%s\n' "$commit" "$exit_code" "$((end - start))" "$result_file"
  count=$((count + 1))
done < <(tail -n +2 "$manifest_file")

printf 'history evaluation finished: %s commit(s), private output=%s\n' "$count" "$output_dir"
