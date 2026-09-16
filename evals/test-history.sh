#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-history-test.XXXXXX")"
fake_bin="$fixture_root/bin"
repo="$fixture_root/repo"
manifest="$fixture_root/manifest.tsv"
out_dir="$fixture_root/results"
repeat_out="$fixture_root/repeated-results"
labels_out="$fixture_root/labels"
trap 'rm -rf "$fixture_root"' EXIT

mkdir -p "$fake_bin" "$repo/src"
cat >"$fake_bin/ollama" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"未发现阻塞问题","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/ollama" "$fake_bin/curl"

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name history-test
printf 'class Example {}\n' >"$repo/src/Example.java"
git -C "$repo" add .
git -C "$repo" commit -qm base
parent="$(git -C "$repo" rev-parse HEAD)"
printf 'class Example { int value = 1; }\n' >"$repo/src/Example.java"
git -C "$repo" add .
git -C "$repo" commit -qm change
commit="$(git -C "$repo" rev-parse HEAD)"

{
  printf 'commit\tparent\tdate\tsubject\tstatus\n'
  printf '%s\t%s\t2026-09-14\ttest duplicate\tpending-human-label\n' "$commit" "$parent"
  printf '%s\t%s\t2026-09-14\ttest duplicate\tpending-human-label\n' "$commit" "$parent"
} >"$manifest"

stderr_file="$fixture_root/stderr"
PATH="$fake_bin:$PATH" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  "$repo_root/evals/run-history.sh" \
    --repo "$repo" --manifest "$manifest" --out-dir "$out_dir" >"$fixture_root/stdout" 2>"$stderr_file"

grep -F "跳过重复提交清单行：$commit" "$stderr_file" >/dev/null
grep -F $'status\tcompleted' "$out_dir/$commit.meta.tsv" >/dev/null
grep -F $'configured_max_diff_bytes\t60000' "$out_dir/$commit.meta.tsv" >/dev/null
awk -F '\t' '$1 == "effective_max_diff_bytes" && $2 ~ /^[0-9]+$/ && $2 <= 60000 { found = 1 } END { exit(found ? 0 : 1) }' \
  "$out_dir/$commit.meta.tsv"
[[ -s "$out_dir/$commit.txt" ]]

"$repo_root/evals/prepare-history-labels.sh" \
  --manifest "$manifest" --results "$out_dir" --labels-dir "$labels_out" >/dev/null
result_sha256="$(shasum -a 256 "$out_dir/$commit.txt" | awk '{print $1}')"
grep -F $'# source_result_sha256\t'"$result_sha256" "$labels_out/$commit.labels.tsv" >/dev/null

PATH="$fake_bin:$PATH" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  "$repo_root/evals/run-history-repeat.sh" \
    --runs 2 --repo "$repo" --manifest "$manifest" --out-dir "$repeat_out" \
    >"$fixture_root/repeat-stdout"
grep -F 'history repeat stability passed: runs=2, commits=1' "$fixture_root/repeat-stdout" >/dev/null
cmp -s "$repeat_out/run-1/$commit.txt" "$repeat_out/run-2/$commit.txt"
printf 'history duplicate regression passed\n'
