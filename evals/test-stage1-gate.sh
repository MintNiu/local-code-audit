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
  local name="$1" file="$2"
  shift 2
  if "$repo_root/evals/stage1-gate.sh" --scorecard "$file" "$@" >/dev/null 2>&1; then
    echo "stage1 gate accepted invalid fixture: $name" >&2
    exit 1
  fi
}

low_recall="$fixture_root/low-recall.tsv"
cp "$valid" "$low_recall"
perl -0pi -e 's/^c[0-9]+\tholdout\tholdout-cluster-01\t2\t2\t2\t0\ttrue\t2\ttrue$/c0000000000000000000000000000000000000001\tholdout\tholdout-cluster-01\t2\t0\t2\t0\ttrue\t0\ttrue/m' "$low_recall"
expect_fail low-recall "$low_recall" --min-recall 100

leakage="$fixture_root/leakage.tsv"
cp "$valid" "$leakage"
sed -i '' 's/holdout-cluster-01/train-cluster-01/' "$leakage"
expect_fail feature-cluster-leakage "$leakage"

incomplete="$fixture_root/incomplete.tsv"
cp "$valid" "$incomplete"
sed -i '' 's/\ttrue\t2\ttrue$/\tfalse\t2\ttrue/' "$incomplete"
expect_fail incomplete "$incomplete"

missing="$fixture_root/missing.tsv"
cut -f1-8,10 "$valid" >"$missing"
expect_fail missing-column "$missing"

echo 'stage1 gate regression passed'
