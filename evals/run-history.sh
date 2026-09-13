#!/usr/bin/env bash
set -euo pipefail

repo_dir=""
manifest_file=""
output_dir=""
limit=""
commit_filter=""
profile="personal"

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
  --out-dir <dir>    私有结果目录，不要指向公开仓库
  --limit <n>        只运行前 n 个 pending-human-label 提交
  --commit <sha>     只运行指定的 pending-human-label 提交
  --profile <name>   使用 personal（默认，个人高性能）或 baseline profile
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

repo_root="$(git -c core.fsmonitor=false -C "$repo_dir" rev-parse --show-toplevel)"
workflow_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$profile" == "personal" ]]; then
  review_script="$workflow_root/bin/local-review-local.sh"
else
  review_script="$workflow_root/bin/local-review.sh"
fi
count=0

while IFS=$'\t' read -r commit parent date subject status _rest; do
  [[ "$commit" == "commit" || -z "$commit" ]] && continue
  [[ "$status" == "pending-human-label" ]] || continue
  [[ -z "$commit_filter" || "$commit" == "$commit_filter" ]] || continue
  if [[ -n "$limit" && "$count" -ge "$limit" ]]; then
    break
  fi

  worktree="$temp_root/$commit"
  patch_file="$temp_root/$commit.patch"
  result_file="$output_dir/$commit.txt"
  metadata_file="$output_dir/$commit.meta.tsv"
  mkdir -p "$worktree"

  if ! git -c core.fsmonitor=false -C "$repo_root" archive "$parent" | tar -xf - -C "$worktree"; then
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
  git -c core.fsmonitor=false -C "$repo_root" diff --binary --no-ext-diff --no-textconv "$parent" "$commit" >"$patch_file"

  if ! git -C "$worktree" apply --whitespace=nowarn "$patch_file"; then
    printf 'commit\t%s\nstatus\tapply-failed\nsubject\t%s\n' "$commit" "$subject" >"$metadata_file"
    count=$((count + 1))
    continue
  fi

  start="$(date +%s)"
  exit_code=0
  "$review_script" --repo "$worktree" >"$result_file" 2>&1 || exit_code=$?
  end="$(date +%s)"

  {
    printf 'commit\t%s\n' "$commit"
    printf 'parent\t%s\n' "$parent"
    printf 'date\t%s\n' "$date"
    printf 'subject\t%s\n' "$subject"
    printf 'profile\t%s\n' "$profile"
    if [[ "$exit_code" -eq 0 ]]; then
      printf 'status\tcompleted\n'
    else
      printf 'status\tfailed\n'
    fi
    printf 'exit_code\t%s\n' "$exit_code"
    printf 'elapsed_seconds\t%s\n' "$((end - start))"
    printf 'result_file\t%s\n' "$result_file"
  } >"$metadata_file"

  printf '%s exit=%s elapsed=%ss result=%s\n' "$commit" "$exit_code" "$((end - start))" "$result_file"
  count=$((count + 1))
done < <(tail -n +2 "$manifest_file")

printf 'history evaluation finished: %s commit(s), private output=%s\n' "$count" "$output_dir"
