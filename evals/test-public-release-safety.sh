#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Keep the public repository free of workstation paths, RFC1918 addresses, and
# the historical Platform fixture credential spellings.  Exclude this file so
# the guard patterns themselves do not become a false positive.
if git -C "$repo_root" grep -nE \
  '/Users/[A-Za-z0-9._-]+/Documents/|192[.]168[.][0-9]+[.][0-9]+|wanzhiTest' -- \
  . ':(exclude)evals/test-public-release-safety.sh' >/dev/null; then
  echo 'public release safety scan found a workstation path or internal fixture value' >&2
  git -C "$repo_root" grep -nE \
    '/Users/[A-Za-z0-9._-]+/Documents/|192[.]168[.][0-9]+[.][0-9]+|wanzhiTest' -- \
    . ':(exclude)evals/test-public-release-safety.sh' >&2 || true
  exit 1
fi

echo 'public release safety regression passed'
