# Local Code Audit

[中文说明](README.zh-CN.md)

A local code-audit workflow for individual developers:

`Git diff → project rules and relevant context → Ollama model → complete findings → human verification → fixed evaluation set`

The default model is `devstral-small-2-review-tuned`. It is an Ollama-derived configuration based on the locally installed `devstral-small-2-review`; it does not retrain or replace the base model weights.

## Goals

- Maximize recall of P0/P1 findings.
- Require a file, line, and code-level evidence for every finding.
- Never silently drop or truncate findings; a repeated root cause may be represented once only when every affected file/line range remains visible.
- Fail explicitly on API errors, empty responses, or length truncation.
- Keep business source code, real diffs, and private review examples outside this public repository.
- Use one global command across multiple Git repositories.

## Install or update the global command

```bash
ollama create devstral-small-2-review-tuned:latest -f config/Modelfile
./scripts/install-global.sh
```

The installer only installs the local command. It never downloads a model automatically.
The audit boundary is kept in `config/Modelfile` for direct Ollama use, and `local-review` sends the same boundary explicitly on every request; rebuild the tuned model after changing that policy.

Prerequisites are a running Ollama service, the selected local model, Git, `jq`, and `rg` (ripgrep). macOS already provides `curl`, `awk`, `tr`, and `sort`; check the required tools with `command -v ollama jq git curl awk tr sort rg`. On a Homebrew setup, install the missing utilities with `brew install jq ripgrep`.

## Usage

Run from any Git repository:

```bash
local-review
local-review --repo /path/to/repo --base origin/main
local-review --context src/main/java/path/to/RelatedService.java
local-review --examples /path/to/private/examples.md
```

For your personal high-performance profile, install and run:

```bash
local-review-local
local-review-local --repo /path/to/repo --base origin/main
```

`local-review-local` keeps the same evidence, tenant-isolation, security, and
truncation gates. Its default budgets remain the validated 16k/4096 profile and
it keeps the model resident for consecutive reviews; this avoids the timeout
observed with oversized 32k/8192 requests on real cross-repository diffs.
For higher recall stability on high-impact findings, it also defaults to greedy
decoding (`OLLAMA_REVIEW_TOP_K=1`, `OLLAMA_REVIEW_TOP_P=1`); override either
variable when you explicitly want a different sampling trade-off.
Override any value with the same
`OLLAMA_REVIEW_*` environment variables when needed. The team-safe `local-review`
command remains the default and is the one to share with collaborators.

On this Mac, the same clean fixture took about 23s then 4s with `keep_alive=5m`,
versus about 20s and 21s when unloading after every request. The five-minute
residency is therefore intentional for consecutive local reviews; use
`OLLAMA_REVIEW_KEEP_ALIVE=0` when battery conservation matters more.

For an A/B test, override settings for one invocation:

```bash
OLLAMA_REVIEW_MODEL=devstral-small-2-review \
OLLAMA_REVIEW_NUM_CTX=32768 \
OLLAMA_REVIEW_NUM_PREDICT=4096 \
local-review --repo /path/to/repo
```

The default context is 16k; set `OLLAMA_REVIEW_NUM_CTX=32768` for larger changes when the machine has enough memory. The default output budget is 4096 tokens. If the output reaches the limit, the command fails and reports truncation instead of returning an incomplete review. Large changes should be reviewed by file or module.

When the collected diff exceeds `OLLAMA_REVIEW_MAX_DIFF_BYTES` (default `3000`), `local-review` automatically performs deterministic file- and unified-hunk-boundary sharding. Each shard is reviewed separately; only byte-identical repeated paragraphs are removed during aggregation, while distinct findings remain visible. A shard uses `OLLAMA_REVIEW_CHUNK_TIMEOUT_SECONDS=180` and `OLLAMA_REVIEW_CHUNK_NUM_PREDICT=2048` by default; any shard timeout, truncation, or invalid output fails the whole review and prints completed shards only as diagnostic output.

An individual hunk that still exceeds the byte budget, or a Git combined diff (`diff --cc` / `diff --combined`), is rejected explicitly instead of being sent as an unsafe oversized prompt.

The byte budget applies to collected Git diff material only. Project rules, explicit context files, README content, and the system prompt are additional context; raise `OLLAMA_REVIEW_NUM_CTX` or split the review further when those inputs are large.

The output gate rejects generic summaries: every finding paragraph must include a severity and a file/line location that matches a changed file or an explicitly supplied context file. A basename is accepted only when it is unambiguous in the review set.

Sampling defaults are `top_k=40` and `top_p=0.9`; keep them unchanged during comparisons unless the evaluation record includes the override.

The default temperature is `0` for repeatable local audits. This is a stability setting, not a substitute for human verification.

The default `keep_alive=0` unloads the model after each review. Set `OLLAMA_REVIEW_KEEP_ALIVE=5m` when running several reviews consecutively.

## Evaluation

Create a private set of at least 20 human-verified historical commits and follow [evals/README.md](evals/README.md) to track recall, false positives, line accuracy, completeness, and elapsed time.

Run the public synthetic regression gate before changing prompts or runtime options:

```bash
./evals/run-synthetic.sh
```

The current gate is intentionally strict: it fails on extra P0–P3 findings, contradictory output, API errors, timeouts, or truncation. See [evals/goal.md](evals/goal.md) for the acceptance target and current status.

For private historical-commit evaluation, use [evals/README.md](evals/README.md) and keep the manifest, raw outputs, and labels outside this public repository.

Use `evals/prepare-history-labels.sh` to create non-overwriting private TSV label templates before calculating recall and false-positive rates.

The `examples/` directory contains only the public format specification. Real few-shot examples belong in the local private file `~/.local/share/local-review/examples.md`.

The tuning history and known failure modes are documented in [docs/tuning-process.zh-CN.md](docs/tuning-process.zh-CN.md).

## Privacy and GitHub

The public repository is [MintNiu/local-code-audit](https://github.com/MintNiu/local-code-audit) and uses Apache License 2.0. Do not commit business source code, real diffs, access tokens, model weights, or private review data.

## Commit convention

Use Conventional Commits such as `feat:`, `fix:`, `docs:`, and `perf:`. The type stays in English; the subject after the type is written in Chinese.
