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

Prerequisites are a running Ollama service, the selected local model, Python 3, Git, `jq`, `rg` (ripgrep), and Perl for output redaction. macOS already provides `curl`, `awk`, `tr`, `sort`, and `/usr/bin/perl`; check the required tools with `command -v python3 ollama jq git curl awk tr sort rg perl`. On a Homebrew setup, install the missing utilities with `brew install jq ripgrep`.

## Usage

Run from any Git repository:

```bash
local-review
local-review --repo /path/to/repo --base origin/main
local-review --context src/main/java/path/to/RelatedService.java
local-review --examples /path/to/private/examples.md
```

Every parseable model final response is now retained **before filtering or retry**
in a private local `final-candidates.jsonl` report, including excluded, repeated,
unconfirmed, and incomplete candidates. The command announces its absolute path
on stderr once per review. Read all candidate text with
`jq -r '.final_text' /path/to/final-candidates.jsonl`; stdout remains the existing
validated workflow result, not the complete original candidate list.

Reports default to `~/.local/share/local-review/reports`. Use
`--report-dir /private/absolute/directory` or `LOCAL_REVIEW_REPORT_DIR` to select
another private directory (mode `0700`, report files `0600`; symlinks are refused).
If creation, writing, or flushing fails, the complete sanitized final text falls
back to stderr rather than disappearing. Only final text is retained, never the
API envelope or non-final internal fields. Existing credential redaction still
applies, but is not a guarantee that all secrets are detected: reports are
plaintext, may contain source excerpts, stay local, and are not auto-deleted.
Treat them as private and do not commit them. Retention does not confirm a
finding or turn a truncated/invalid response into a successful review.

Workflow gates are not semantic certification: even exit code `0` does not prove
a finding, severity, suggested repair, or absence of defects is correct.

For an evidence-first review, use an existing trusted test task or a separately
reviewed fixed probe, then pass its private text/JSON observations through the
existing `--context /private/absolute/review-evidence.txt` option. Record the
matching source/diff identity, exact command, relevant runtime/configuration,
inputs, outputs and failures; verify that they still match the reviewed version.
Keep counterevidence and complete logs private, and do not treat a few passing
calls as universal safety. Do not run model-generated or untrusted repository
code just to verify a claim. The command reads evidence; it does not execute it
or automatically certify conclusions. This uses no new model, dependency or
automatic judging stage, and does not establish a measured quality improvement.

When a change deletes, renames, or changes a public API, DTO, or declarative client, the main repository review does not automatically read consumers from other repositories. First extract downstream interfaces, configuration, call sites, or tests from the Git ref matching the target change, then pass them explicitly with repeatable `--context`; otherwise the result is limited to the current repository. For historical evaluations, use `scripts/extract-context-snapshot.sh` to create a private snapshot:

```bash
local-review --repo /path/to/platform-api \
  --context /path/to/platform-file/src/main/java/.../InternalFileController.java \
  --context /path/to/platform-file/pom.xml
```

This is required for cross-repository compatibility coverage in the personal high-performance workflow. Context files are evidence-only inputs and are never modified.

When downstream service context explicitly shows tenant-bearing event data and `ignoreTenant`/`supplyWithIgnoreTenant`, a newly added internal claim/ack client that carries only `X-Gateway-Token` receives an additional narrow tenant-isolation preflight. Without those server-side facts, the runner does not infer a tenant vulnerability from a client signature alone.

For your personal high-performance profile, install and run:

```bash
local-review-local
local-review-local --repo /path/to/repo --base origin/main
```

`local-review-local` keeps the same evidence, security, and truncation gates. Its
default budget is the validated 16k/4096 personal profile and
it keeps the model resident for consecutive reviews. Keep the current work at
16K: the slower 32K route was rejected and is not being retried. For larger
reviews, bound the relevant evidence and split the work instead.
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
OLLAMA_REVIEW_NUM_CTX=16384 \
OLLAMA_REVIEW_NUM_PREDICT=4096 \
local-review --repo /path/to/repo
```

The default context is 16k. Prefer file/module sharding for large changes; 32k is an explicit experimental override, not a recommended fix for latency or missed findings. The default output budget is 4096 tokens. If the output reaches the limit, the command fails and reports truncation instead of returning an incomplete review.

For an explicitly selected, already-installed experimental model, `OLLAMA_REVIEW_THINK`
can request `false`, `true`, `low`, `medium`, `high`, or `xhigh`. The configured local
daemon's `/api/show` must advertise that exact JSON value and type; unsupported,
empty, invalid, or unverifiable settings fail before inference. With this variable
unset, no `think` field or extra capability request is added. Boolean `false` is
not omission or the string `"false"`. Request traces record the sent setting;
this option does not download a model, change defaults, or waive format/quality gates.

When the collected diff exceeds `OLLAMA_REVIEW_MAX_DIFF_BYTES` (core default `3000`), `local-review` automatically performs deterministic file- and unified-hunk-boundary sharding. Each shard is reviewed separately; only byte-identical repeated paragraphs are removed during aggregation, while distinct findings remain visible. The general command uses `OLLAMA_REVIEW_CHUNK_TIMEOUT_SECONDS=180` and `OLLAMA_REVIEW_CHUNK_NUM_PREDICT=2048`; the personal high-performance wrapper uses a validated 6000-byte default and raises the shard output budget to 4096. Any shard timeout, truncation, or invalid output fails the whole review and prints completed shards only as diagnostic output.

Each shard also receives a paths-only inventory of all files changed by the commit. This is scope metadata, not extra source context: it helps the model distinguish “implemented in another shard” from “missing”, while preserving the rule that absence from the current shard is never evidence of a defect.

The deterministic Java missing-import preflight is limited to conventional
`src/main/java` and `src/test/java` paths, including module prefixes. A custom
or legacy source root does not establish a build classpath, so its imports
cannot alone trigger a compile-failure finding; its diff remains in the model
review. This preflight is not a compiler or a build-configuration resolver.

Java reviews can opt into a bounded method-context sidecar for a private A/B evaluation:

```bash
OLLAMA_REVIEW_JAVA_METHOD_SIDECAR=true \
local-review --repo /path/to/repo
```

It is disabled by default. When enabled, the helper reads only current-worktree Java methods that contain added lines in the current diff, sends those windows as evidence-only context, and never follows symlinks or writes source content to the trace. Whole methods are omitted when the per-method or total byte budget cannot hold them; if the resulting prompt exceeds the actual input budget, the runner falls back to the original bounded prompt. Tune `OLLAMA_REVIEW_JAVA_METHOD_SIDECAR_MAX_BYTES`, `OLLAMA_REVIEW_JAVA_METHOD_SIDECAR_MAX_METHOD_BYTES`, and `OLLAMA_REVIEW_JAVA_METHOD_SIDECAR_MAX_METHODS` only while recording an A/B result. Do not count a sidecar-assisted result as model-native recall until a private clean-set comparison confirms no false-positive or latency regression.

An individual hunk that still exceeds the byte budget, or a Git combined diff (`diff --cc` / `diff --combined`), is rejected explicitly instead of being sent as an unsafe oversized prompt.

The byte budget applies to collected Git diff material only. Project rules, explicit context files, README content, and the system prompt are additional context; select the necessary complete evidence and split the review further when those inputs are large. Do not silently truncate evidence or relax the input guard.

Transient Ollama transport failures are retried up to two times within the total review timeout by default. The personal high-performance wrapper uses a 2400-second total budget to accommodate many serial shards; set `OLLAMA_REVIEW_TOTAL_TIMEOUT_SECONDS` explicitly for a fail-fast limit. Set `OLLAMA_REVIEW_RETRY_ATTEMPTS=0` to disable retries or tune it for local stability. The launcher also estimates the input budget for system rules, context, and diff before sending; tune `OLLAMA_REVIEW_INPUT_RESERVE_TOKENS` when you need a different safety margin.

For a small diff, the launcher first budgets the complete initial prompt so
examples and preflight context remain available when they fit. Optional context
is removed only when that estimate exceeds the input budget; all deterministic
findings still appear in the final merge. A failed initial request triggers a
fresh shard-budget calculation. Evaluation metadata records `budget_mode` as
`initial` or `shard` to distinguish these two estimates.

For diagnostic A/B runs only, set `OLLAMA_REVIEW_SPECIALIST_CHANNEL` to `auth-tenant`, `concurrency-state`, or `external-io`. The runner performs one additional serial, narrow risk-family pass and unions both complete outputs; the default is empty, so normal reviews keep one request. Any specialist timeout, truncation, or invalid output fails closed, and specialist union results are not counted as model-native scorecard recall until independently validated.

The output gate validates structure, not defect truth: every finding paragraph must include a severity, a file/line location that matches a changed file or an explicitly supplied context file, and explicit `影响：`, `修复建议：`, and `验证方式：` fields. A basename is accepted only when it is unambiguous in the review set.

Configuration findings are not suppressed merely for saying “may” or “if”.
These words can describe the impact of a real defect. Structurally valid
candidates remain visible for independent verification; passing the output
gate does not confirm their correctness. Unknown paths, invalid line ranges,
and missing required fields still fail the review rather than becoming clean.

The generic file-wide `token`/`currentToken` null-guard filter has been removed.
A check in deleted lines, another method, a comment/string or after the failing
operation cannot disprove a concrete dereference finding. The launcher retains
these candidates for normal validation rather than inferring clean from that
text match. `bash evals/test-token-guard-filtering.sh` covers five false-clean
shapes and three protocol controls: the old code passed 3/8; the fix passed 8/8
with byte-identical requests and fixed fake responses. This proves workflow
retention, not model-native recall, lower false positives or candidate truth.

Logging-related wording in evidence, impact, a fix or verification no longer
discards an entire candidate. Normal structure and location checks still apply.
Generic “add logging” advice may therefore reappear and needs independent
verification; it is not a confirmed defect. Run
`bash evals/test-logging-word-retention.sh` for ten offline cases: five
source-supported response variants, one explicitly non-gold noise-visibility
control and four protocol controls. The old filter passed 2/10; its removal
passed 10/10 with byte-identical requests and fixed responses. These are
retention/protocol checks, not independent-root or model-quality scores.

The only configuration exception is an evidence-backed contradiction guard:
when the diff removes literal credential values, every current credential line
uses an environment placeholder, and the model itself says the old value was
removed with no further fix needed, that self-contradictory paragraph is
treated as clean. A real literal retained in an added/context line, or any
independent security/compatibility finding, remains visible.

When a finding contains a parseable file line, the launcher also checks it against the actual current file or explicit context length; an out-of-range location fails the review instead of being treated as evidence. Deleted files are not forced through a current-worktree line check.

Sampling defaults are `top_k=40` and `top_p=0.9`; keep them unchanged during comparisons unless the evaluation record includes the override.

The default temperature is `0` for repeatable local audits. This is a stability setting, not a substitute for human verification.

The conservative `local-review` command defaults to `keep_alive=0` and unloads the model after each review. The personal `local-review-local` wrapper defaults to `5m`; set `OLLAMA_REVIEW_KEEP_ALIVE=0` when battery conservation matters more.
After changing rules or parameters, run `./scripts/verify-runtime.sh` to read-only check that the installed Ollama tuned model still matches the current `config/Modelfile`. If it fails, follow the printed rebuild commands; the script never recreates models automatically.

## Evaluation

Create a private set of at least 20 human-verified historical commits and follow [evals/README.md](evals/README.md) to track recall, false positives, line accuracy, completeness, and elapsed time.

Run the public synthetic regression gate before changing prompts or runtime options:

```bash
./evals/run-synthetic.sh
```

For Git path-move semantics, run `bash evals/test-rename-evidence.sh`. It verifies that only an exact `R100` rename (identical content) receives anti-duplicate migration evidence; a rewritten rename remains an ordinary review target. Ollama-backed regressions should run serially because the local single-instance lock intentionally rejects a concurrent second review.

The repository also runs the model-independent regression suites in GitHub Actions on macOS for every push and pull request. This catches parser, sharding, aggregation, label-migration, and runtime-verifier regressions without requiring Ollama or exposing private review data.

`scripts/run-regression.py` gives each suite its own temporary private report
directory, overriding an inherited `LOCAL_REVIEW_REPORT_DIR`, so fake model
responses never enter the user's persistent reports. Those fixture reports are
removed with the suite's temporary files; ordinary review reports are retained.

Latest targeted workflow verification (2026-10-19): shard-qualification
retention improved from 5/12 to 12/12 offline cases with byte-identical
requests and fixed responses. A concrete finding is no longer deleted just
because it also says that callers are not shown. Five supported-response
cases (two source roots, including one mixed response) and two malformed
responses had incorrectly become successful clean results. Required-field
and line-range checks now reject the latter; strict incomplete-only, clean
and truncation controls remain intact. Original finals were already archived
before filtering. The complete local no-model regression passed 89/89 suites
in 549.51 seconds; shell syntax and the runner self-test also passed.
This is not native model quality, proof of every remaining
filter, or overall acceptance; unsupported suggestions may remain visible.

Preceding model-independent verification (2026-10-19): logging-word retention
passed 10/10 targeted cases and all 88/88 suites in 529.03 seconds, plus shell
syntax checks and the runner self-test. This fixes reproduced workflow
false-clean cases and restores structure/range rejection; generic logging
noise remains visible. It is not model-native quality or overall acceptance.
The preceding token-guard fix passed 8/8 targeted cases and 87/87 suites in
525.67 seconds, correcting five false-clean cases. The earlier Java source-root
guard passed 10/10 targeted cases and 86/86 suites in 550.18 seconds, correcting
four reproduced deterministic false positives.

Latest native diagnostic (2026-10-19): a one-paragraph evidence-gate A/B
kept the existing model, complete inputs and 16K/4096. The candidate changed
evidence sufficiency wording, not the output protocol; all other SYSTEM bytes
and request fields were retained. On the same correct Java source, A completed
in 96.151 seconds but repeated one false immutable-list-copy P1 three times.
B completed in 34.495 seconds but falsely claimed that sharing immutable
Integer references lets a caller's list replacement change its independent
copy. Both source-qualified reviewers rejected that mechanism. The frozen
safe-case gate closed the other six slots unattempted and unscored; the
candidate was not adopted. All received finals remain private and unfiltered.
These two calls do not establish recall, repetition stability, general speed
or quality improvement. No model, weights or defaults changed. See the
[tuning record](docs/tuning-process.zh-CN.md).

Earlier native diagnostic (2026-10-19): a combined JSON result-protocol candidate
retained complete materials and the existing model with 16K/4096. All four
development inputs fit the conservative byte estimate, including the full
added API schema cost; the tightest margin was only nine estimated tokens.
The first correct Java implementation completed in 47.114 seconds with valid
JSON, but falsely reported a P1 broken import and proposed replacing that
import with the identical text. The exact source had already compiled.
The safe-case gate closed the remaining three slots unattempted and unscored.
Every received candidate remains private and unfiltered. The candidate was
not adopted; recall, stability and causal speed or quality effects are not
established. See the [tuning record](docs/tuning-process.zh-CN.md).

Earlier native diagnostic (2026-10-19): a complete-material typed-framing A/B
comparison was prepared, but the first original-format safe Java request hit
the 4,096-output-token limit after 332.301 seconds. It falsely alleged broken
imports and missing JDK dependencies, repeating the latter paragraph 29 times.
The exact target had already compiled with the existing JDK. The pre-registered
stop rule closed the other seven slots before any typed request or defect
control ran. Every received final byte remains private and unfiltered;
treatment effectiveness, recall and stability are unmeasured. No defaults or
weights changed. See the [tuning record](docs/tuning-process.zh-CN.md).

Earlier native development screen (2026-10-19): a candidate consolidated duplicate
output instructions, saving 585 SYSTEM bytes while retaining all other rules,
examples, source and contracts. Four frozen Java/Python requests completed with
the expected model identity and 16K runtime. Both correct implementations were
clean, but both defective implementations were also clean: the model missed a
constructor array alias and a sibling-directory prefix escape. The candidate
failed the four-case gate and was not adopted. These exposed functional cases
are not formal P0/P1 holdout scores; without a matched original-instruction
baseline, they do not establish a causal quality or speed change. Defaults and
weights remain unchanged. See the [tuning record](docs/tuning-process.zh-CN.md).

The synthetic gate checks 23 positive and 22 clean development fixtures five
times each, plus explicit truncation handling. Clean fixtures reject findings;
positive fixtures check known risk families, not every possible extra false
positive. Thirteen security-clean fixtures use 512 output tokens and greedy
decoding, and the presigned fixture also uses greedy decoding. Results include
deterministic preflight, filtering, and narrowly documented recovery paths, so
passing this gate is not evidence of model-native recall, zero false positives,
or successful model generation on every call. See [evals/goal.md](evals/goal.md)
for the independent acceptance target and current status.

The visibility-retention change passed all 84 then-existing model-independent
local suites in 545.66 seconds. The subsequent synthetic stdout/stderr separation
passed four targeted suites (17.63 seconds), including its new nine-scenario
no-model test, history, signatures, and runner isolation. That addition brought
CI discovery to 85 suites; these are engineering checks, not model-quality acceptance.
Synthetic scores use only stdout, retain and show complete stderr separately,
and automatically keep failed-run results even without `SYNTHETIC_KEEP_RESULTS=1`.
Fake preflight reports use an isolated temporary directory; actual model reviews
still retain their ordinary private candidate reports.

Previous verification (2026-10-16, `49293e3`): the complete model-independent regression
passed 83/83 local suites in 534.18 seconds with `GITHUB_ACTIONS=true`, including sidecar fallback,
prompt-budget coverage, dependency diagnostics, the native-canary collector,
and 27 opt-in thinking-option scenarios. The stage-one gate now also rejects
impossible hit/candidate counts and case-variant duplicate commit IDs; an
additional positive test preserves legitimate unclassified candidates.
The [remote CI run for the same `49293e3` commit](https://github.com/MintNiu/local-code-audit/actions/runs/38771203542)
also passed the complete workflow. The preceding `88ca8a6` remote failure did not
reproduce; its cause remains unknown. CI-only safe failure annotations improve
diagnostic visibility without changing the suite set or acceptance thresholds.
Before the opt-in thinking addition, the
[remote CI run for `ad9920a`](https://github.com/MintNiu/local-code-audit/actions/runs/38757857910)
passed all 82 then-existing suites in 670.79 seconds. The earlier 80/82 remote result
remains in the tuning log; its unresolved preflight failure must not be
attributed to a locale or production-filter fix without evidence.
The real-model five-round gate is **not passing**: after 60 successful
executions it stopped on a resource-ownership false positive in
`java-command-safe`. Experimental prompt variants have not replaced the
defaults. See the [tuning log](docs/tuning-process.zh-CN.md) for the failures
and the distinction between raw model output and wrapper results.

The independent scorecard also requires reconciliation: root-cause records
were being confused with unique commits, and the audit found identity and
count conflicts. The validator now rejects those conflicts and reports record
and commit counts separately. Previous recall figures are not current
acceptance evidence until the labels and run identities are reconciled.

To compare native model behavior without the workflow's preflight or output
filters, use the paired Java/Python/JavaScript development canary:

```bash
python3 scripts/run-native-canary.py \
  --model devstral-small-2-review-tuned:latest \
  --out-dir /private/path/new-native-canary-results
```

The model tag must already be installed and the output directory must be new
and outside this public checkout. The tool sends only the shared contract and
complete source diff, pins the installed model digest, and preserves every raw
response. API completion is recorded separately from review format and manual
semantic assessment; it is not a quality pass. These 16 original synthetic
programs are development diagnostics, not an independent holdout. Optional
`--thinking` values must be advertised by the local model. No model is downloaded
and no default is changed. See [evals/README.md](evals/README.md) for the review
procedure. If the local service cannot resolve the installed manifest by its
digest, the read-only preflight refuses the run; it does not fall back to a
mutable tag.

For private historical-commit evaluation, use [evals/README.md](evals/README.md) and keep the manifest, raw outputs, and labels outside this public repository.

Use `evals/prepare-history-labels.sh` to create non-overwriting private TSV label templates before calculating recall and false-positive rates.

For a multilingual external dataset, keep normalized JSONL and license metadata outside this public repository. Validate it before sampling or fine-tuning:

```bash
python3 scripts/validate-external-dataset.py /path/to/private/review-dataset.jsonl
```

The validator checks source/license metadata, positive finding completeness, changed-file line locations, and repository/commit leakage across `train`, `dev`, and `holdout`. It never downloads data or prints source snippets.

See [docs/external-datasets-plan.zh-CN.md](docs/external-datasets-plan.zh-CN.md) for the current dataset priority, license boundaries, split policy, and model-native versus deterministic-preflight metrics.

For AACR-Bench review-format smoke data, keep the downloaded JSON outside this repository and normalize only human comments:

```bash
python3 scripts/prepare-aacr-review-dataset.py \
  /private/path/positive_samples.json /private/path/negative_samples.json \
  --limit-per-language 4 \
  --output /private/path/aacr-human-external-smoke.jsonl
python3 scripts/validate-external-dataset.py /private/path/aacr-human-external-smoke.jsonl
```

The converter excludes LLM-enhanced comments by default and does not treat AACR review comments as Platform P0/P1 gold.

For ReviewBench PR-context smoke data, keep the downloaded manifest and all
referenced repositories outside this public repository. Normalize only the
fixed-revision metadata:

```bash
python3 scripts/prepare-reviewbench-candidates.py \
  /private/path/reviewbench/corpus/manifest.json \
  --revision 66df3f322d0d85ea133ea9fa777f5d1a8c933c4e \
  --output /private/path/reviewbench-candidates.jsonl
```

The converter emits repository, PR, base/head, language, and size metadata;
every row remains `pending-human-label` with `golden_status=not-loaded`. It
does not copy source, diffs, review text, or golden findings. ReviewBench is
useful for multilingual review context and location smoke, but its seven Java
PRs are not a Java P0/P1 recall gate. Run
`bash evals/test-reviewbench-candidates.sh` for the no-leakage regression.

For SWE-PRBench, normalize only the metadata in `prs.jsonl`; keep diffs,
contexts, comments, and referenced repositories outside this public repository:

```bash
python3 scripts/prepare-swe-prbench-candidates.py \
  /private/path/swe-prbench/dataset/prs.jsonl \
  --revision b87f5797aef3ed2c3153bb1304ea4d801d36ba6e \
  --language java \
  --output /private/path/swe-prbench-java-candidates.jsonl
```

Every row stays `pending-human-label` with `golden_status=not-loaded`; the
adapter preserves the source `task_id`, derives a candidate PR number from it,
and preserves difficulty,
RVS, and substantive-comment metadata without importing review text or patch
content. SWE-PRBench has limited Java coverage, so the Java filter is only a
small external smoke; all languages still require repository-license,
file/line, and severity verification. Run
`bash evals/test-swe-prbench-candidates.sh` for the no-leakage regression.

For VCC-Eval Java vulnerability-introduction metadata, create a private
metadata-only candidate index:

```bash
python3 scripts/prepare-vcc-eval-candidates.py \
  /private/path/tool_assisted_manual_dataset.json \
  --output /private/path/vcc-eval-candidates.jsonl
```

The converter canonicalizes repository mirrors, groups by repository/CVE/
introduction lineage, parses introduction and fix line ranges, and marks every
row `pending-human-label`. VCC-Eval does not declare a reusable dataset
license; records without introduction lines, parent-diff verification, or
trigger evidence must stay out of strict gold. No source or patch text is
copied and no row is labeled `positive`; the regression is
`bash evals/test-vcc-eval-candidates.sh`.

After preparing local read-only Git mirrors, verify parent commits and exact
added lines with a private repository map:

```bash
python3 scripts/verify-vcc-eval-candidates.py \
  /private/path/vcc-eval-candidates.jsonl \
  --repo-map /private/path/vcc-eval-repo-map.json \
  --output /private/path/vcc-eval-verified.jsonl
```

The verifier never fetches, checks out, or applies patches. Missing mirrors,
parents, exact added lines, or current source remain explicit failures and
`pending-human-label`; its regression is
`bash evals/test-vcc-eval-verifier.sh`.

For private Vul4J CSV metadata, generate Java-only candidates without turning CVE/CWE metadata into labels:

```bash
python3 scripts/prepare-vul4j-candidates.py \
  /private/path/vul4j_dataset.csv \
  --output /private/path/vul4j-candidates.jsonl
```

The converter accepts GitHub commit patch URLs, skips compare links and duplicate repository/commit identities, preserves CWE/CVE provenance, and marks every record `pending-human-label`. It does not copy source or patch text; line-level findings must be independently verified before a record can enter a review scorecard.

For a locally downloaded NIST Juliet Java archive, extract a small private audit smoke set (the archive itself is not committed):

```bash
python3 scripts/prepare-juliet-java.py \
  /private/path/juliet-java-v1.3.zip \
  /private/path/juliet-java-audit-smoke.jsonl \
  --limit-per-cwe 2
```

The converter reads the archive manifest for CWE names and flaw lines, emits bad/good pairs, and keeps the generated JSONL outside this repository.
The runner also has narrow Java external-security preflights: it deterministically reports a literal password flowing into `DriverManager.getConnection` within one method, a non-empty literal flowing into `SecretKeySpec`, `readLine()` data flowing directly into `sendRedirect`, weak cryptographic algorithms, password fields submitted by GET forms, sensitive cookies without `Secure`, external counts used as unbounded loop bounds, modulo counters paired with provably-true `do/while` conditions, `HttpSession.setMaxInactiveInterval(-1)`, file resources closed only on the success path, `ReentrantLock`/`Lock` `lock()` or `lockInterruptibly()` acquisitions without a matching release for the same receiver in the same method, and a non-volatile static field used in a structurally nested double-checked initialization; fixed redirects, environment/secret injection, modern AES, POST forms, secured cookies, bounded loops, loops with reachable `break`, finite session timeouts, `finally`/try-with-resources or explicit lock-release protection, `volatile` DCL fields, method-synchronized initialization, and incomplete/non-nested null checks remain clean. The regression entry point is `evals/test-java-external-preflight.sh`; it neither downloads nor commits external source.
The DCL check requires nested braced conditions and a direct `field = new Type(...)` assignment; it handles same-line and next-line braces without joining evidence from adjacent blocks. Factory calls and unsupported syntax remain outside this deterministic check and still go through model review. Run `PYTHONDONTWRITEBYTECODE=1 python3 evals/test-java-dcl-scope.py` for fast parser-boundary tests. The external-security suite also exercises both globally installed entry points in an isolated directory, including relative symlinks and paths with spaces.
The Java command-injection preflight separately reports only a changed `Runtime.getRuntime().exec`/`ProcessBuilder` sink whose `command`/`cmd`/`args`/`script` variable is visibly assigned from request input in the same method; constant commands and environment-only configuration remain clean. Its positive/negative regression is `bash evals/test-java-command-injection-preflight.sh`, and it is also part of `test-preflight.sh`.
The runner also checks a narrow SQL delivery-upgrade boundary: when a standalone delivery script removes a parent menu ID that an older version deleted, but provides no scoped restoration for the menu and its tenant/role relations, it reports the existing-database migration risk; fresh-install bootstrap SQL is not treated as upgrade evidence. The regression entry point is `evals/test-sql-menu-delivery-preflight.sh`.

The XXL-JOB empty-token preflight corroborates the current API method's annotations and a supported first-matching `/api/**` permission rule before reporting a conditional candidate. It does not combine health-only `permitAll`, an earlier authentication/deny rule, or annotations from a neighboring method as authorization evidence, and recognizes supported top-level blank-token rejection guards. Effective environment/Nacos configuration, required request headers and actual network reachability still need independent verification; an empty fallback alone is not a confirmed deployment vulnerability. Unsupported security-chain structures are not used as permission proof. Run `bash evals/test-xxl-job-empty-token-preflight.sh` for synthetic positive/negative controls; native model candidates are not filtered by this check.

The personal profile also contains two narrow ERP fulfillment concurrency
preflights: stale aggregate rewrites after ordinary order/line reads, and
client-controlled line iteration order before row updates or stock reservation.
They require evidence from the changed `SalesFulfillmentApplication` and its
repository, emit complete P1 findings with impact/fix/verification/evidence
fields, and stay silent when lock/version/CAS protection or deterministic line
sorting is visible. These are deterministic safeguards, not claims that the
model itself learned the pattern. The regression entry point is
`evals/test-sales-fulfillment-preflight.sh`.

The `examples/` directory contains only the public format specification. Real few-shot examples belong in the local private file `~/.local/share/local-review/examples.md`.
Keep that private file concise: its contents are included in every prompt and are counted by the fail-closed input-budget check. If the examples grow beyond the default 16k context budget, reduce or curate them instead of silently increasing context or allowing truncation.

The tuning history and known failure modes are documented in [docs/tuning-process.zh-CN.md](docs/tuning-process.zh-CN.md).

## Privacy and GitHub

The public repository is [MintNiu/local-code-audit](https://github.com/MintNiu/local-code-audit) and uses Apache License 2.0. Do not commit business source code, real diffs, access tokens, model weights, or private review data.

## Commit convention

Use Conventional Commits such as `feat:`, `fix:`, `docs:`, and `perf:`. The type stays in English; the subject after the type is written in Chinese.
