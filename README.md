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
./scripts/sync-modelfile.sh
ollama create devstral-small-2-review-tuned:latest -f config/Modelfile
./scripts/install-global.sh
```

The installer only installs the local command. It never downloads a model automatically.
If your shell cannot find the command after installation, add
`export PATH="$HOME/.local/bin:$PATH"` to `~/.zprofile` (or your shell's startup
file) and open a new terminal.
The audit boundary is authored in `bin/local-review.sh`; `scripts/sync-modelfile.sh` copies it into `config/Modelfile` for direct Ollama use. The `local-review` path additionally applies deterministic output gates. Re-run the sync script and rebuild the tuned model after changing rules that should also affect direct Ollama use.

Prerequisites are a running Ollama service, the selected local model, Git, `jq`, `rg` (ripgrep), and Perl for output redaction. macOS already provides `curl`, `awk`, `tr`, `sort`, and `/usr/bin/perl`; check the required tools with `command -v ollama jq git curl awk tr sort rg perl`. On a Homebrew setup, install the missing utilities with `brew install jq ripgrep`.

## Usage

Run from any Git repository:

```bash
local-review
local-review --repo /path/to/repo --base origin/main
local-review --context src/main/java/path/to/RelatedService.java
local-review --examples /path/to/private/examples.md
```

When a change deletes, renames, or changes a public API, DTO, or declarative client, the main repository review does not automatically read consumers from other repositories. First extract downstream interfaces, configuration, call sites, or tests from the Git ref matching the target change, then pass them explicitly with repeatable `--context`; otherwise the result is limited to the current repository. For historical evaluations, use `scripts/extract-context-snapshot.sh` to create a private snapshot:

```bash
local-review --repo /path/to/platform-api \
  --context /path/to/platform-file/src/main/java/.../InternalFileController.java \
  --context /path/to/platform-file/pom.xml
```

This is required for cross-repository compatibility coverage in the personal high-performance workflow. Context files are evidence-only inputs and are never modified.

For your personal high-performance profile, install and run:

```bash
local-review-local
local-review-local --repo /path/to/repo --base origin/main
```

`local-review-local` keeps the same evidence, security, and truncation gates. Its
default budgets remain the validated 16k/4096 profile and
it keeps the model resident for consecutive reviews; this avoids the timeout
observed with oversized 32k/8192 requests on real cross-repository diffs.
It keeps the validated general-purpose decoding defaults
(`OLLAMA_REVIEW_TOP_K=40`, `OLLAMA_REVIEW_TOP_P=0.9`). For a focused,
high-impact check you can opt into greedy decoding with
`OLLAMA_REVIEW_TOP_K=1 OLLAMA_REVIEW_TOP_P=1`; this is intentionally not the
default because some real configuration diffs can make greedy generation stall.
Override any value with the same `OLLAMA_REVIEW_*` environment variables when
needed. Use `local-review` for the conservative baseline and
`local-review-local` when you want the personal high-performance defaults.

The launcher polls model availability at 100 ms intervals and reuses the successful
automatic model probe, avoiding an extra startup delay without changing the timeout
or fail-closed behavior.

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

Each shard also receives a paths-only inventory of all files changed by the commit. This is scope metadata, not extra source context: it helps the model distinguish “implemented in another shard” from “missing”, while preserving the rule that absence from the current shard is never evidence of a defect.

An individual hunk that still exceeds the byte budget, or a Git combined diff (`diff --cc` / `diff --combined`), is rejected explicitly instead of being sent as an unsafe oversized prompt.

The byte budget applies to collected Git diff material only. Project rules, explicit context files, README content, and the system prompt are additional context; raise `OLLAMA_REVIEW_NUM_CTX` or split the review further when those inputs are large.

The output gate rejects generic or incomplete summaries: every finding paragraph must include a severity, a file/line location that matches a changed file or an explicitly supplied context file, and explicit `影响：`, `修复建议：`, and `验证方式：` fields. A basename is accepted only when it is unambiguous in the review set.

Sampling defaults are `top_k=40` and `top_p=0.9`; keep them unchanged during comparisons unless the evaluation record includes the override.

The default temperature is `0` for repeatable local audits. This is a stability setting, not a substitute for human verification.

The conservative `local-review` command defaults to `keep_alive=0` and unloads the model after each review. The personal `local-review-local` wrapper defaults to `5m`; set `OLLAMA_REVIEW_KEEP_ALIVE=0` when battery conservation matters more.

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
