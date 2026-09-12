#!/usr/bin/env bash
set -euo pipefail

# Personal high-performance profile. Values remain overridable per invocation.
# It still uses the same conservative tenant/security rules and private examples
# as local-review; only runtime budgets and model residency are changed.
export OLLAMA_REVIEW_NUM_CTX="${OLLAMA_REVIEW_NUM_CTX:-16384}"
export OLLAMA_REVIEW_NUM_PREDICT="${OLLAMA_REVIEW_NUM_PREDICT:-4096}"
export OLLAMA_REVIEW_MAX_DIFF_BYTES="${OLLAMA_REVIEW_MAX_DIFF_BYTES:-6000}"
export OLLAMA_REVIEW_TIMEOUT_SECONDS="${OLLAMA_REVIEW_TIMEOUT_SECONDS:-600}"
export OLLAMA_REVIEW_TOTAL_TIMEOUT_SECONDS="${OLLAMA_REVIEW_TOTAL_TIMEOUT_SECONDS:-900}"
export OLLAMA_REVIEW_CHUNK_TIMEOUT_SECONDS="${OLLAMA_REVIEW_CHUNK_TIMEOUT_SECONDS:-180}"
export OLLAMA_REVIEW_CHUNK_NUM_PREDICT="${OLLAMA_REVIEW_CHUNK_NUM_PREDICT:-2048}"
export OLLAMA_REVIEW_KEEP_ALIVE="${OLLAMA_REVIEW_KEEP_ALIVE:-5m}"
# Keep the validated general-purpose sampling defaults. Greedy decoding can
# be enabled per run for focused high-impact checks, but is not the default:
# on some real config diffs it can make generation stall for several minutes.
export OLLAMA_REVIEW_TOP_K="${OLLAMA_REVIEW_TOP_K:-40}"
export OLLAMA_REVIEW_TOP_P="${OLLAMA_REVIEW_TOP_P:-0.9}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$script_dir/local-review.sh" "$@"
