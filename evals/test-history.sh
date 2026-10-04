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
if [[ -n "${HISTORY_TEST_MAX_DIFF_FILE:-}" ]]; then
  printf '%s\n' "${OLLAMA_REVIEW_MAX_DIFF_BYTES:-unset}" >"$HISTORY_TEST_MAX_DIFF_FILE"
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

# Manifest control characters and unescaped tabs must fail before the output
# directory is created; otherwise metadata/label paths could become
# ambiguous or carry injected records.
control_manifest="$fixture_root/control-manifest.tsv"
printf 'commit\tparent\tdate\tsubject\tstatus\n%s\t%s\t2026-09-14\tbad\vsubject\tpending-human-label\n' \
  "$commit" "$parent" >"$control_manifest"
control_status=0
"$repo_root/evals/run-history.sh" \
  --repo "$repo" --manifest "$control_manifest" --out-dir "$fixture_root/control-results" \
  >"$fixture_root/control-stdout" 2>"$fixture_root/control-stderr" || control_status=$?
(( control_status == 2 )) || {
  echo 'manifest control-character input was incorrectly accepted' >&2
  exit 1
}
grep -F '控制字符' "$fixture_root/control-stderr" >/dev/null
[[ ! -e "$fixture_root/control-results" ]]

tab_manifest="$fixture_root/tab-manifest.tsv"
printf 'commit\tparent\tdate\tsubject\tstatus\n%s\t%s\t2026-09-14\tbad\tsubject\tpending-human-label\n' \
  "$commit" "$parent" >"$tab_manifest"
tab_status=0
"$repo_root/evals/run-history.sh" \
  --repo "$repo" --manifest "$tab_manifest" --out-dir "$fixture_root/tab-results" \
  >"$fixture_root/tab-stdout" 2>"$fixture_root/tab-stderr" || tab_status=$?
(( tab_status == 2 )) || {
  echo 'manifest unescaped-tab input was incorrectly accepted' >&2
  exit 1
}
grep -F '列数与表头不一致' "$fixture_root/tab-stderr" >/dev/null
[[ ! -e "$fixture_root/tab-results" ]]

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
grep -F $'output_complete\ttrue' "$out_dir/$commit.meta.tsv" >/dev/null
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

# When the personal profile is left at its default, a small diff just above
# 6KB should use the validated 12KB shard budget to avoid an unnecessary
# second model request. The adaptive value is recorded and passed to the
# reviewer; an explicit environment override remains authoritative.
awk 'BEGIN {
  printf "class Adaptive { String payload = \""
  for (i = 0; i < 7000; i++) printf "x"
  printf "\"; }\n"
}' >"$repo/src/Adaptive.java"
git -C "$repo" add src/Adaptive.java
git -C "$repo" commit -qm 'adaptive history budget'
adaptive_parent="$commit"
adaptive_commit="$(git -C "$repo" rev-parse HEAD)"
adaptive_manifest="$fixture_root/adaptive-manifest.tsv"
adaptive_out="$fixture_root/adaptive-results"
printf 'commit\tparent\tdate\tsubject\tstatus\n%s\t%s\t2026-09-14\tadaptive budget\tpending-human-label\n' \
  "$adaptive_commit" "$adaptive_parent" >"$adaptive_manifest"
PATH="$fake_bin:$PATH" \
  HISTORY_TEST_MAX_DIFF_FILE="$fixture_root/adaptive-max-diff" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/evals/run-history.sh" \
    --repo "$repo" --manifest "$adaptive_manifest" --out-dir "$adaptive_out" \
    >"$fixture_root/adaptive-stdout" 2>"$fixture_root/adaptive-stderr"
grep -F $'max_diff_bytes\t12000' "$adaptive_out/$adaptive_commit.meta.tsv" >/dev/null
grep -Fx '12000' "$fixture_root/adaptive-max-diff" >/dev/null

"$repo_root/evals/prepare-history-labels.sh" \
  --manifest "$manifest" --results "$out_dir" --labels-dir "$labels_out" >/dev/null
result_sha256="$(shasum -a 256 "$out_dir/$commit.txt" | awk '{print $1}')"
grep -F $'# source_result_sha256\t'"$result_sha256" "$labels_out/$commit.labels.tsv" >/dev/null

# Label generation must reject a manifest commit that could escape
# --labels-dir through path traversal before creating any output.
unsafe_label_manifest="$fixture_root/unsafe-label-manifest.tsv"
printf 'commit\tparent\tdate\tsubject\tstatus\n../../escape\t%s\t2026-09-14\tunsafe\tpending-human-label\n' \
  "$parent" >"$unsafe_label_manifest"
unsafe_label_status=0
"$repo_root/evals/prepare-history-labels.sh" \
  --manifest "$unsafe_label_manifest" --results "$out_dir" \
  --labels-dir "$fixture_root/unsafe-labels" \
  >"$fixture_root/unsafe-label-stdout" 2>"$fixture_root/unsafe-label-stderr" || unsafe_label_status=$?
(( unsafe_label_status == 2 )) || {
  echo 'unsafe manifest commit path was incorrectly accepted by label preparation' >&2
  exit 1
}
grep -F 'commit 和 parent 必须是 7-64 位十六进制' "$fixture_root/unsafe-label-stderr" >/dev/null
[[ ! -e "$fixture_root/unsafe-labels" ]]

# Labels must not bind a result to a changed manifest or to a different
# commit/parent pair. The result directory remains immutable; only the input
# manifest changes.
drifted_manifest="$fixture_root/drifted-manifest.tsv"
sed "s/${parent}/${commit}/" "$manifest" >"$drifted_manifest"
if "$repo_root/evals/prepare-history-labels.sh" \
  --manifest "$drifted_manifest" --results "$out_dir" --labels-dir "$fixture_root/drifted-labels" \
  >"$fixture_root/drifted-labels-stdout" 2>"$fixture_root/drifted-labels-stderr"; then
  echo 'label preparation accepted a manifest/result mismatch' >&2
  exit 1
fi
grep -F '结果与当前 manifest 不一致' "$fixture_root/drifted-labels-stderr" >/dev/null

# A manifest row with no matching pending commit must not be reported as a
# successful empty history run.
empty_manifest="$fixture_root/empty-manifest.tsv"
printf 'commit\tparent\tdate\tsubject\tstatus\n' >"$empty_manifest"
empty_history_status=0
PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/evals/run-history.sh" \
    --repo "$repo" --manifest "$empty_manifest" --out-dir "$fixture_root/empty-history-results" \
    >"$fixture_root/empty-history-stdout" 2>"$fixture_root/empty-history-stderr" || empty_history_status=$?
(( empty_history_status != 0 )) || {
  echo 'empty history manifest was incorrectly accepted' >&2
  exit 1
}
grep -F '没有匹配的 pending-human-label 提交' "$fixture_root/empty-history-stderr" >/dev/null

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

# A single run cannot establish repeat stability; reject it before creating
# output or invoking the reviewer.
if PATH="$fake_bin:$PATH" \
  HISTORY_TEST_CURL_COUNT="$fixture_root/repeat-single-curl-count" \
  "$repo_root/evals/run-history-repeat.sh" \
    --runs 1 --repo "$repo" --manifest "$manifest" --out-dir "$fixture_root/repeat-single" \
    >"$fixture_root/repeat-single-stdout" 2>"$fixture_root/repeat-single-stderr"; then
  echo 'history repeat accepted runs=1' >&2
  exit 1
fi
grep -F -- '--runs 必须是大于等于 2 的整数' "$fixture_root/repeat-single-stderr" >/dev/null
[[ ! -e "$fixture_root/repeat-single-curl-count" ]]
[[ ! -e "$fixture_root/repeat-single" ]]

# Multi-digit values such as 10 remain valid; stop at argument validation so
# the regression does not launch a history run.
if PATH="$fake_bin:$PATH" \
  "$repo_root/evals/run-history-repeat.sh" \
    --runs 10 >"$fixture_root/repeat-ten-stdout" 2>"$fixture_root/repeat-ten-stderr"; then
  echo 'history repeat unexpectedly ran without required output directory' >&2
  exit 1
fi
grep -F -- '--out-dir 是必需参数' "$fixture_root/repeat-ten-stderr" >/dev/null
printf 'history duplicate regression passed\n'

# Parent validation is fail-closed and must happen before any model transport.
invalid_manifest="$fixture_root/invalid-parent.tsv"
invalid_out="$fixture_root/invalid-parent-results"
invalid_old_parent="$commit"
printf 'commit\tparent\tdate\tsubject\tstatus\n%s\t%s\t2026-09-14\tinvalid parent\tpending-human-label\n' "$commit" "$invalid_old_parent" >"$invalid_manifest"
invalid_curl_count="$fixture_root/invalid-curl-count"
invalid_status=0
PATH="$fake_bin:$PATH" \
  HISTORY_TEST_CURL_COUNT="$invalid_curl_count" \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/evals/run-history.sh" \
    --repo "$repo" --manifest "$invalid_manifest" --out-dir "$invalid_out" >/dev/null 2>"$fixture_root/invalid-stderr" || invalid_status=$?
(( invalid_status != 0 )) || {
  echo 'invalid parent history run unexpectedly exited successfully' >&2
  exit 1
}
grep -F $'status\tinvalid-range' "$invalid_out/$commit.meta.tsv" >/dev/null
grep -F $'failure_reason\tparent-is-not-a-direct-parent' "$invalid_out/$commit.meta.tsv" >/dev/null
[[ ! -e "$invalid_curl_count" ]]
grep -F '未调用审计器' "$fixture_root/invalid-stderr" >/dev/null
printf 'history invalid-parent fail-closed regression passed\n'

# The same commit must not be silently evaluated against two different
# parents; a merge commit needs an explicit, single parent choice per run.
conflict_manifest="$fixture_root/conflicting-parent.tsv"
{
  printf 'commit\tparent\tdate\tsubject\tstatus\n'
  printf '%s\t%s\t2026-09-14\tfirst parent\tpending-human-label\n' "$commit" "$parent"
  printf '%s\t%s\t2026-09-14\tconflicting parent\tpending-human-label\n' "$commit" "$commit"
} >"$conflict_manifest"
conflict_status=0
PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  "$repo_root/evals/run-history.sh" \
    --repo "$repo" --manifest "$conflict_manifest" --out-dir "$fixture_root/conflicting-results" \
    >"$fixture_root/conflicting-stdout" 2>"$fixture_root/conflicting-stderr" || conflict_status=$?
(( conflict_status != 0 )) || {
  echo 'conflicting parent manifest was incorrectly accepted' >&2
  exit 1
}
grep -F '多个不同 parent' "$fixture_root/conflicting-stderr" >/dev/null
printf 'history conflicting-parent fail-closed regression passed\n'

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
  :
else
  echo 'empty-output history run unexpectedly exited successfully' >&2
  exit 1
fi
grep -F $'status\tfailed' "$empty_out/$commit.meta.tsv" >/dev/null
grep -F $'output_complete\tfalse' "$empty_out/$commit.meta.tsv" >/dev/null
grep -F $'failure_reason\tempty-review-output' "$empty_out/$commit.meta.tsv" >/dev/null
grep -F 'exit 0 但没有非空审查结果' "$empty_out/$commit.stderr.log" >/dev/null
printf 'history empty-output fail-closed regression passed\n'

# A non-empty but malformed exit-0 reviewer result must also be rejected.
cat >"$fake_workflow/bin/local-review-local.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "fake-core" >"${LOCAL_REVIEW_RESOLVED_MODEL_FILE:?}"
printf 'FROZEN-REVIEW\n'
EOF
chmod +x "$fake_workflow/bin/local-review-local.sh"
malformed_out="$fixture_root/malformed-results"
malformed_status=0
PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=fake \
  "$fake_workflow/evals/run-history.sh" \
    --repo "$repo" --manifest "$manifest" --out-dir "$malformed_out" >/dev/null 2>"$fixture_root/malformed-stderr" || malformed_status=$?
(( malformed_status != 0 )) || {
  echo 'malformed reviewer output was incorrectly accepted' >&2
  exit 1
}
grep -F $'status\tfailed' "$malformed_out/$commit.meta.tsv" >/dev/null
grep -F $'failure_reason\tmalformed-review-output' "$malformed_out/$commit.meta.tsv" >/dev/null
printf 'history malformed-output fail-closed regression passed\n'

# A finding-shaped output without a path and line is not auditable evidence.
cat >"$fake_workflow/bin/local-review-local.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "fake-core" >"${LOCAL_REVIEW_RESOLVED_MODEL_FILE:?}"
printf 'P1 generic finding\n影响：x\n修复建议：y\n验证方式：z\n'
EOF
chmod +x "$fake_workflow/bin/local-review-local.sh"
unlocated_out="$fixture_root/unlocated-results"
unlocated_status=0
PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=fake \
  "$fake_workflow/evals/run-history.sh" \
    --repo "$repo" --manifest "$manifest" --out-dir "$unlocated_out" >/dev/null 2>"$fixture_root/unlocated-stderr" || unlocated_status=$?
(( unlocated_status != 0 )) || {
  echo 'history accepted a finding without path/line evidence' >&2
  exit 1
}
grep -F $'failure_reason\tmalformed-review-output' "$unlocated_out/$commit.meta.tsv" >/dev/null
printf 'history unlocated-output fail-closed regression passed\n'

# The reviewer is copied before execution. Mutating source scripts while the
# frozen run is sleeping must not change its output or recorded hashes.
cat >"$fake_workflow/bin/local-review-local.sh" <<'EOF'
#!/usr/bin/env bash
: >"${HISTORY_RACE_STARTED_FILE:?}"
sleep 1
printf '%s\n' "fake-core" >"${LOCAL_REVIEW_RESOLVED_MODEL_FILE:?}"
printf '未发现阻塞问题\n'
EOF
chmod +x "$fake_workflow/bin/local-review-local.sh"
race_out="$fixture_root/race-results"
(PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=fake \
  HISTORY_RACE_STARTED_FILE="$fixture_root/race-started" \
  "$fake_workflow/evals/run-history.sh" \
    --repo "$repo" --manifest "$manifest" --out-dir "$race_out" >"$fixture_root/race-stdout" 2>"$fixture_root/race-stderr") &
history_pid=$!
for _ in {1..100}; do
  [[ -e "$fixture_root/race-started" ]] && break
  sleep 0.05
done
[[ -e "$fixture_root/race-started" ]] || {
  echo 'history reviewer did not reach the frozen snapshot in time' >&2
  cat "$fixture_root/race-stderr" >&2
  exit 1
}
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
grep -Fx '未发现阻塞问题' "$race_out/$commit.txt" >/dev/null
if grep -Fx 'MUTATED-REVIEW' "$race_out/$commit.txt" >/dev/null; then
  echo 'frozen history result unexpectedly used mutated wrapper' >&2
  exit 1
fi
grep -F $'review_scripts_snapshot\ttrue' "$race_out/$commit.meta.tsv" >/dev/null
grep -F $'review_script\tbin/local-review-local.sh\tsha256=' "$race_out/$commit.meta.tsv" >/dev/null
printf 'history reviewer snapshot race regression passed\n'
