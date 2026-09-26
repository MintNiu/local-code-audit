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
if [[ -n "${HISTORY_TEST_CURL_COUNT:-}" ]]; then
  count=0
  if [[ -f "$HISTORY_TEST_CURL_COUNT" ]]; then
    count="$(<"$HISTORY_TEST_CURL_COUNT")"
  fi
  count=$((count + 1))
  printf '%s\n' "$count" >"$HISTORY_TEST_CURL_COUNT"
  # The repeatability checker must ignore this elapsed-time difference while
  # still comparing the chunk outcome and response bytes.
  if [[ "$count" -eq 2 ]]; then
    sleep 1
  fi
  if [[ "$count" -eq 1 ]]; then
    printf 'transient transport warning\n' >&2
  fi
fi
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
  HISTORY_TEST_CURL_COUNT="$fixture_root/first-curl-count" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  "$repo_root/evals/run-history.sh" \
    --repo "$repo" --manifest "$manifest" --out-dir "$out_dir" >"$fixture_root/stdout" 2>"$stderr_file"

grep -F "跳过重复提交清单行：$commit" "$stderr_file" >/dev/null
grep -F $'status\tcompleted' "$out_dir/$commit.meta.tsv" >/dev/null
grep -F $'configured_max_diff_bytes\t60000' "$out_dir/$commit.meta.tsv" >/dev/null
grep -F $'chunk_count\t1' "$out_dir/$commit.meta.tsv" >/dev/null
grep -F $'stderr_file\t' "$out_dir/$commit.meta.tsv" >/dev/null
awk -F '\t' '$1 == "effective_max_diff_bytes" && $2 ~ /^[0-9]+$/ && $2 <= 60000 { found = 1 } END { exit(found ? 0 : 1) }' \
  "$out_dir/$commit.meta.tsv"
[[ -s "$out_dir/$commit.txt" ]]
if grep -F 'transient transport warning' "$out_dir/$commit.txt" >/dev/null; then
  echo 'history result incorrectly contains stderr diagnostics' >&2
  exit 1
fi
grep -F 'transient transport warning' "$out_dir/$commit.stderr.log" >/dev/null

"$repo_root/evals/prepare-history-labels.sh" \
  --manifest "$manifest" --results "$out_dir" --labels-dir "$labels_out" >/dev/null
result_sha256="$(shasum -a 256 "$out_dir/$commit.txt" | awk '{print $1}')"
grep -F $'# source_result_sha256\t'"$result_sha256" "$labels_out/$commit.labels.tsv" >/dev/null

PATH="$fake_bin:$PATH" \
  HISTORY_TEST_CURL_COUNT="$fixture_root/repeat-curl-count" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  "$repo_root/evals/run-history-repeat.sh" \
    --runs 2 --repo "$repo" --manifest "$manifest" --out-dir "$repeat_out" \
    >"$fixture_root/repeat-stdout"
grep -F 'history repeat stability passed: runs=2, commits=1' "$fixture_root/repeat-stdout" >/dev/null
cmp -s "$repeat_out/run-1/$commit.txt" "$repeat_out/run-2/$commit.txt"
printf 'history duplicate regression passed\n'

# Parent validation is fail-closed and must happen before any model transport.
invalid_manifest="$fixture_root/invalid-parent.tsv"
invalid_out="$fixture_root/invalid-parent-results"
invalid_old_parent="$commit"
printf 'commit\tparent\tdate\tsubject\tstatus\n%s\t%s\t2026-09-14\tinvalid parent\tpending-human-label\n' "$commit" "$invalid_old_parent" >"$invalid_manifest"
invalid_curl_count="$fixture_root/invalid-curl-count"
PATH="$fake_bin:$PATH" \
  HISTORY_TEST_CURL_COUNT="$invalid_curl_count" \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/evals/run-history.sh" \
    --repo "$repo" --manifest "$invalid_manifest" --out-dir "$invalid_out" >/dev/null 2>"$fixture_root/invalid-stderr"
grep -F $'status\tinvalid-range' "$invalid_out/$commit.meta.tsv" >/dev/null
grep -F $'failure_reason\tparent-is-not-a-direct-parent' "$invalid_out/$commit.meta.tsv" >/dev/null
[[ ! -e "$invalid_curl_count" ]]
grep -F '未调用审计器' "$fixture_root/invalid-stderr" >/dev/null
printf 'history invalid-parent fail-closed regression passed\n'

# An exit-0 reviewer with only whitespace is not a completed review.
fake_workflow="$fixture_root/workflow"
mkdir -p "$fake_workflow/bin" "$fake_workflow/evals"
git -C "$fake_workflow" init -q
cp "$repo_root/evals/run-history.sh" "$fake_workflow/evals/run-history.sh"
chmod +x "$fake_workflow/evals/run-history.sh"
cat >"$fake_workflow/bin/local-review.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "fake-core" >"${LOCAL_REVIEW_RESOLVED_MODEL_FILE:?}"
printf '   \n\t\n'
EOF
cat >"$fake_workflow/bin/local-review-local.sh" <<'EOF'
#!/usr/bin/env bash
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/local-review.sh" "$@"
EOF
chmod +x "$fake_workflow/bin/"*.sh
empty_out="$fixture_root/empty-results"
empty_status=0
PATH="$fake_bin:$PATH" \
  OLLAMA_REVIEW_MODEL=fake \
  "$fake_workflow/evals/run-history.sh" \
    --repo "$repo" --manifest "$manifest" --out-dir "$empty_out" >/dev/null 2>"$fixture_root/empty-stderr" || empty_status=$?
if (( empty_status != 0 )); then
  cat "$fixture_root/empty-stderr" >&2
  echo "empty-output history fixture exited unexpectedly: $empty_status" >&2
  exit 1
fi
grep -F $'status\tfailed' "$empty_out/$commit.meta.tsv" >/dev/null
grep -F $'failure_reason\tempty-review-output' "$empty_out/$commit.meta.tsv" >/dev/null
grep -F 'exit 0 但没有非空审查结果' "$empty_out/$commit.stderr.log" >/dev/null
printf 'history empty-output fail-closed regression passed\n'

# The reviewer is copied before execution. Mutating source scripts while the
# frozen run is sleeping must not change its output or recorded hashes.
cat >"$fake_workflow/bin/local-review-local.sh" <<'EOF'
#!/usr/bin/env bash
sleep 1
printf '%s\n' "fake-core" >"${LOCAL_REVIEW_RESOLVED_MODEL_FILE:?}"
printf 'FROZEN-REVIEW\n'
EOF
chmod +x "$fake_workflow/bin/local-review-local.sh"
race_out="$fixture_root/race-results"
(PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=fake \
  "$fake_workflow/evals/run-history.sh" \
    --repo "$repo" --manifest "$manifest" --out-dir "$race_out" >"$fixture_root/race-stdout" 2>"$fixture_root/race-stderr") &
history_pid=$!
sleep 0.2
cat >"$fake_workflow/bin/local-review-local.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "fake-mutated" >"${LOCAL_REVIEW_RESOLVED_MODEL_FILE:?}"
printf 'MUTATED-REVIEW\n'
EOF
cat >"$fake_workflow/bin/local-review.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "fake-mutated" >"${LOCAL_REVIEW_RESOLVED_MODEL_FILE:?}"
printf 'MUTATED-CORE\n'
EOF
chmod +x "$fake_workflow/bin/"*.sh
wait "$history_pid"
grep -Fx 'FROZEN-REVIEW' "$race_out/$commit.txt" >/dev/null
if grep -Fx 'MUTATED-REVIEW' "$race_out/$commit.txt" >/dev/null; then
  echo 'frozen history result unexpectedly used mutated wrapper' >&2
  exit 1
fi
grep -F $'review_scripts_snapshot\ttrue' "$race_out/$commit.meta.tsv" >/dev/null
grep -F $'review_script\tbin/local-review-local.sh\tsha256=' "$race_out/$commit.meta.tsv" >/dev/null
printf 'history reviewer snapshot race regression passed\n'
