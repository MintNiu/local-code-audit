#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-stage1-gate.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
header=$'commit\tsplit\tfeature_cluster\tgold_p0_p1\tp0_p1_found\tpredicted_candidates\tfalse_positive_count\toutput_complete\tlocation_accurate\trepeat_stable'
valid="$fixture_root/valid.tsv"
printf '%s\n' "$header" >"$valid"
for n in $(seq 1 8); do
  printf 'a%039d\ttrain\ttrain-cluster-%02d\t2\t2\t2\t0\ttrue\t2\ttrue\n' "$n" "$n" >>"$valid"
done
for n in $(seq 1 4); do
  printf 'b%039d\tdev\tdev-cluster-%02d\t2\t2\t2\t0\ttrue\t2\ttrue\n' "$n" "$n" >>"$valid"
done
for n in $(seq 1 12); do
  printf 'c%039d\tholdout\tholdout-cluster-%02d\t2\t2\t2\t0\ttrue\t2\ttrue\n' "$n" "$n" >>"$valid"
done
"$repo_root/evals/stage1-gate.sh" --scorecard "$valid" | grep -Fx 'stage1_gate=pass' >/dev/null

expect_fail() {
  local name="$1" file="$2" expected="$3"
  local output="$fixture_root/$name.stdout" diagnostic="$fixture_root/$name.stderr"
  shift 3
  if "$repo_root/evals/stage1-gate.sh" --scorecard "$file" "$@" >"$output" 2>"$diagnostic"; then
    echo "stage1 gate accepted invalid fixture: $name" >&2
    exit 1
  fi
  if [[ -s "$output" ]] || ! grep -F "$expected" "$diagnostic" >/dev/null; then
    echo "stage1 gate did not reject the intended invariant: $name" >&2
    cat "$output" "$diagnostic" >&2
    exit 1
  fi
}

low_recall="$fixture_root/low-recall.tsv"
cp "$valid" "$low_recall"
perl -0pi -e 's/^c[0-9]+\tholdout\tholdout-cluster-01\t2\t2\t2\t0\ttrue\t2\ttrue$/c0000000000000000000000000000000000000001\tholdout\tholdout-cluster-01\t2\t0\t2\t0\ttrue\t0\ttrue/m' "$low_recall"
expect_fail low-recall "$low_recall" 'holdout 召回率低于门槛' --min-recall 100

leakage="$fixture_root/leakage.tsv"
cp "$valid" "$leakage"
sed -i '' 's/holdout-cluster-01/train-cluster-01/' "$leakage"
expect_fail feature-cluster-leakage "$leakage" '同一 feature_cluster 泄漏到多个 split'

incomplete="$fixture_root/incomplete.tsv"
cp "$valid" "$incomplete"
sed -i '' 's/\ttrue\t2\ttrue$/\tfalse\t2\ttrue/' "$incomplete"
expect_fail incomplete "$incomplete" '存在不完整运行'

missing="$fixture_root/missing.tsv"
cut -f1-8,10 "$valid" >"$missing"
expect_fail missing-column "$missing" 'scorecard 缺少阶段 1 必需列'

impossible_found="$fixture_root/found-exceeds-predicted.tsv"
awk 'BEGIN { FS = OFS = "\t" } NR > 1 && $2 == "holdout" { $6 = 0 } { print }' \
  "$valid" >"$impossible_found"
expect_fail found-exceeds-predicted "$impossible_found" 'p0_p1_found 不能大于 predicted_candidates'

impossible_partition="$fixture_root/found-and-false-positive-exceed-predicted.tsv"
awk 'BEGIN { FS = OFS = "\t" } NR == 14 { $7 = 1 } { print }' \
  "$valid" >"$impossible_partition"
expect_fail found-and-false-positive-exceed-predicted "$impossible_partition" \
  '命中数与误报数之和不能大于 predicted_candidates'

case_duplicate="$fixture_root/case-duplicate.tsv"
awk 'BEGIN { FS = OFS = "\t" } NR == 2 { duplicate = toupper($1) } NR == 3 { $1 = duplicate } { print }' \
  "$valid" >"$case_duplicate"
expect_fail case-insensitive-duplicate "$case_duplicate" '重复 commit'

allowed_remainder="$fixture_root/allowed-remainder.tsv"
awk 'BEGIN { FS = OFS = "\t" }
  NR > 1 && $2 != "holdout" { $4 = $5 = $6 = $7 = $9 = 0 }
  NR == 14 { $6 = 4; $7 = 1 }
  { print }' "$valid" >"$allowed_remainder"
"$repo_root/evals/stage1-gate.sh" --scorecard "$allowed_remainder" >"$fixture_root/allowed-remainder.stdout"
grep -Fx 'stage1_gate=pass' "$fixture_root/allowed-remainder.stdout" >/dev/null
grep -Fx 'holdout_false_positive_rate=3.8%' "$fixture_root/allowed-remainder.stdout" >/dev/null

echo 'stage1 gate regression passed'
