#!/usr/bin/env bash
set -euo pipefail

# Hermetic regression for deterministic path-traversal/model duplicate merge.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-path-dedup.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
export TMPDIR="$fixture_root"
helper_source="$(awk '
  /^filter_path_traversal_preflight_duplicates\(\) \{$/ { in_helper = 1 }
  in_helper { print }
  in_helper && /^\}$/ { found = 1; exit }
  END { if (!found) exit 1 }
' "$repo_root/bin/local-review.sh")"
eval "$helper_source"

preflight='P1 src/PathReader.java:8-11 - 不可信文件名或对象 key 未经根目录边界校验就用于本地文件访问，存在路径遍历风险。
影响：攻击者可通过 ../、绝对路径或等价路径逃逸允许目录。
修复建议：先 normalize/canonicalize，再检查根目录边界。
验证方式：使用 ../、绝对路径和符号链接测试。'
model='P1 src/PathReader.java:8 - 不可信文件名用于文件访问，存在路径遍历风险。
影响：攻击者可逃逸允许目录。
修复建议：规范化并校验根目录。
验证方式：执行越界路径测试。'

preflight_file="$fixture_root/preflight"
findings_file="$fixture_root/findings"
printf '%s\n' "$preflight" >"$preflight_file"
printf '%s\n' "$model" >"$findings_file"
filter_path_traversal_preflight_duplicates "$findings_file" "$preflight_file"
if [[ -s "$findings_file" ]]; then
  echo 'path traversal duplicate was not removed' >&2
  cat "$findings_file" >&2
  exit 1
fi

printf '%s\n' 'P1 src/PathReader.java:8-11 -' \
  '影响：攻击者可通过 ../、绝对路径或等价路径逃逸允许目录。' \
  '修复建议：先 normalize/canonicalize，再检查根目录边界。' >"$findings_file"
filter_path_traversal_preflight_duplicates "$findings_file" "$preflight_file"
if [[ -s "$findings_file" ]]; then
  echo 'path traversal empty-title duplicate was not removed' >&2
  cat "$findings_file" >&2
  exit 1
fi

printf '%s\n' 'P1 src/Other.java:8 - 不可信文件名用于文件访问，存在路径遍历风险。' >"$findings_file"
filter_path_traversal_preflight_duplicates "$findings_file" "$preflight_file"
grep -Fq 'src/Other.java:8' "$findings_file"

printf 'Path traversal dedup regression: 3 cases passed (no model calls)\n'
