#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-runtime-test.XXXXXX")"
fake_bin="$fixture_root/bin"
global_bin="$fixture_root/global"
trap 'rm -rf "$fixture_root"' EXIT
mkdir -p "$fake_bin" "$global_bin"

cat >"$fake_bin/ollama" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "show" && "${2:-}" == "${VERIFY_MODEL:-devstral-small-2-review-tuned:latest}" && "${3:-}" == "--modelfile" ]] || exit 2
if [[ "${VERIFY_DRIFT:-0}" == "1" ]]; then
  sed '/^SYSTEM """$/a drifted rule' "$VERIFY_MODELF_FILE"
else
  cat "$VERIFY_MODELF_FILE"
fi
EOF
chmod +x "$fake_bin/ollama"

# Keep the fake command independent from the repository's Ollama installation;
# the verifier must compare the exact SYSTEM payload, not just marker strings.
PATH="$fake_bin:$PATH" LOCAL_REVIEW_BIN_DIR="$fixture_root/no-global" VERIFY_MODELF_FILE="$repo_root/config/Modelfile" \
  VERIFY_MODEL=devstral-small-2-review-tuned:latest \
  "$repo_root/scripts/verify-runtime.sh" >/dev/null

if PATH="$fake_bin:$PATH" VERIFY_MODELF_FILE="$repo_root/config/Modelfile" \
  VERIFY_MODEL=devstral-small-2-review-tuned:latest VERIFY_DRIFT=1 \
  "$repo_root/scripts/verify-runtime.sh" >/dev/null 2>&1; then
  echo 'runtime verifier accepted a drifted SYSTEM rule' >&2
  exit 1
fi

cp "$repo_root/bin/local-review.sh" "$global_bin/local-review"
printf '\n# stale wrapper marker\n' >>"$global_bin/local-review"
if PATH="$fake_bin:$PATH" LOCAL_REVIEW_BIN_DIR="$global_bin" VERIFY_MODELF_FILE="$repo_root/config/Modelfile" \
  VERIFY_MODEL=devstral-small-2-review-tuned:latest \
  "$repo_root/scripts/verify-runtime.sh" >/dev/null 2>&1; then
  echo 'runtime verifier accepted a stale global wrapper' >&2
  exit 1
fi

printf 'runtime verification regression passed\n'
