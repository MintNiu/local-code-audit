# Local Code Audit

[中文说明](README.zh-CN.md)

A local code-audit workflow for individual developers:

`Git diff → project rules and relevant context → Ollama model → complete findings → human verification → fixed evaluation set`

The default model is `devstral-small-2-review-tuned`. It is an Ollama-derived configuration based on the locally installed `devstral-small-2-review`; it does not retrain or replace the base model weights.

## Goals

- Maximize recall of P0/P1 findings.
- Require a file, line, and code-level evidence for every finding.
- Never silently filter, merge, deduplicate, or truncate model output.
- Fail explicitly on API errors, empty responses, or length truncation.
- Keep business source code, real diffs, and private review examples outside this public repository.
- Use one global command across multiple Git repositories.

## Install or update the global command

```bash
ollama create devstral-small-2-review-tuned:latest -f config/Modelfile
./scripts/install-global.sh
```

The installer only installs the local command. It never downloads a model automatically.

## Usage

Run from any Git repository:

```bash
local-review
local-review --repo /path/to/repo --base origin/main
local-review --context src/main/java/path/to/RelatedService.java
local-review --examples /path/to/private/examples.md
```

For an A/B test, override settings for one invocation:

```bash
OLLAMA_REVIEW_MODEL=devstral-small-2-review \
OLLAMA_REVIEW_NUM_CTX=32768 \
OLLAMA_REVIEW_NUM_PREDICT=4096 \
local-review --repo /path/to/repo
```

The default context is 32k and the default output budget is 4096 tokens. If the output reaches the limit, the command fails and reports truncation instead of returning an incomplete review. Large changes should be reviewed by file or module.

The default `keep_alive=0` unloads the model after each review. Set `OLLAMA_REVIEW_KEEP_ALIVE=5m` when running several reviews consecutively.

## Evaluation

Create a private set of at least 20 human-verified historical commits and follow [evals/README.md](evals/README.md) to track recall, false positives, line accuracy, completeness, and elapsed time.

The `examples/` directory contains only the public format specification. Real few-shot examples belong in the local private file `~/.local/share/local-review/examples.md`.

The tuning history and known failure modes are documented in [docs/tuning-process.zh-CN.md](docs/tuning-process.zh-CN.md).

## Privacy and GitHub

The public repository is [MintNiu/local-code-audit](https://github.com/MintNiu/local-code-audit) and uses Apache License 2.0. Do not commit business source code, real diffs, access tokens, model weights, or private review data.

## Commit convention

Use Conventional Commits such as `feat:`, `fix:`, `docs:`, and `perf:`. The type stays in English; the subject after the type is written in Chinese.
