#!/usr/bin/env bash
set -euo pipefail

# Regression for oversized unified-diff hunks. The splitter must retain every
# changed line and advance the @@ coordinates for each generated window.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-sharding-test.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
repo="$fixture_root/repo"
fake_bin="$fixture_root/bin"
capture="$fixture_root/requests"
mkdir -p "$repo" "$fake_bin"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name sharding-test
seq 1 120 | awk '{ printf "line-%03d\n", $1 }' >"$repo/A.txt"
git -C "$repo" add A.txt
git -C "$repo" commit -qm base
seq 1 120 | awk '{ printf "changed-%03d\n", $1 }' >"$repo/A.txt.new"
mv "$repo/A.txt.new" "$repo/A.txt"

cat >"$fake_bin/ollama" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
for ((i = 1; i <= $#; i++)); do
  if [[ "${!i}" == @* ]]; then
    cat "${!i#@}" >>"$LOCAL_REVIEW_CAPTURE"
    printf '\n--- request boundary ---\n' >>"$LOCAL_REVIEW_CAPTURE"
  fi
done
printf '{"response":"未发现阻塞问题","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/ollama" "$fake_bin/curl"

PATH="$fake_bin:$PATH" \
  LOCAL_REVIEW_CAPTURE="$capture" \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review \
  OLLAMA_REVIEW_MAX_DIFF_BYTES=1000 \
  OLLAMA_REVIEW_CHUNK_NUM_PREDICT=256 \
  OLLAMA_REVIEW_NUM_CTX=16384 \
  "$repo_root/bin/local-review.sh" --repo "$repo" >/dev/null

expected="$(printf '%s\n' \
  '@@ -1,81 +1,0 @@' \
  '@@ -82,39 +1,32 @@' \
  '@@ -121,0 +33,62 @@' \
  '@@ -121,0 +95,26 @@' | sort)"
actual="$(grep -o '@@ -[0-9,]* +[0-9,]* @@' "$capture" | sort -u)"
[[ "$actual" == "$expected" ]] || {
  echo 'oversized hunk coordinates changed unexpectedly' >&2
  printf '%s\n' "$actual" >&2
  exit 1
}

echo 'diff sharding regression passed'
