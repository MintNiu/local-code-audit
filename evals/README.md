# 评测目标

目标是把本地模型调成可重复、可验证的代码审计模型，而不是只追求输出更长。

## 初始验收标准

公开的合成回归入口是 `./evals/run-synthetic.sh`，目标、夹具和当前状态记录在 [goal.md](goal.md)。它用于每次调参后的快速回归，但不能替代真实历史提交评测。
合成门禁默认调用个人高性能 `local-review-local`，与日常本地入口一致并保持模型 5 分钟；需要专门验证保守冷启动路径时，可通过 `SYNTHETIC_REVIEW_SCRIPT=/path/to/local-review.sh` 覆盖。

真实历史提交使用 `./evals/run-history.sh`。它默认调用个人高性能 `local-review-local`，只在本地读取主仓库和显式提供的只读 context，在临时目录展开父提交并应用目标 diff，把原始结果和元数据写入你指定的私有目录；不要把该目录指向本公开仓库。需要对比保守基线时，追加 `--profile baseline`。
清单中同一提交若重复出现，运行器只处理第一次并明确在 stderr 记录跳过，避免复用临时快照导致补丁二次应用失败；不同评测范围应使用不同输出目录或单独清单。
该行为由 `./evals/test-history.sh` 做无模型回归验证。
准备历史 diff 时同样会禁用仓库配置的 `textconv` 和 fsmonitor，确保评测过程不会执行目标仓库的可配置 Git 命令。
每个提交的 `.meta.tsv` 会记录 profile、配置的模型选择、实际解析到的 `resolved_model`、temperature、seed、top-k/top-p、上下文/输出预算、diff 字节预算、`keep_alive`，以及 `diff_sha256`、`result_sha256`、workflow/脚本/SYSTEM 哈希，避免个人版与基线结果混用并支持严格复现。确定性构建预检命中时，结果会直接合并到最终问题清单，不依赖模型是否复述；该来源仍只覆盖脚本能证明的同仓库/显式 context 类型引用。
当前还会对新增代码中把 token/secret 直接拼进 URL 查询参数或路径的明确模式、通过 `TOKEN_HEADER`（含先赋给局部变量或大写类常量别名）从 URL 查询参数读取令牌的模式、新增配置中的硬编码凭据（含指向非本机 endpoint 的高置信配置项），以及同一 hunk 中移除 `fileStorageService.delete(...)` 但仍删除 `fileRepository` 元数据的对象生命周期回归做确定性预检；凭据值不会写入 finding。别名按当前源码的方法范围保存：同一文件跨 hunk 仍能召回，不同方法复用同名局部变量不会串线；支持多级直接别名，多行方法签名、下一行左花括号、Java text block 以及字符串/注释中的花括号不会破坏边界识别。预检证据会路由到同一文件的每个分片，避免大文件后续分片以不同措辞重复报告同一问题；最终聚合按文件/行号/高置信风险族做语义去重并保留严重度最高的条目，不只依赖字节相等。若模型段同时含有 URL/除法重复和租户、SSRF、并发等独立根因，会保留整段，不会为了去重隐藏其他问题。
对于同一提交中可直接证明的 Java `Integer` 除法空值拆箱和分母为零模式，也会执行窄范围确定性预检；普通 `int` 运算和带可见保护的代码不在该规则内。这样 `java-divide` 与 `java-token-url` 不再依赖模型某次采样是否恰好命中，模型仍负责发现其它上下文相关问题。
切换 profile 或模型后，建议使用新的 `--out-dir` 和 `--labels-dir`；不要把旧 profile 的人工标签直接套到新结果上。
如果评测的是删除或修改公共契约的提交，可重复传入 `--context <file>`，把下游仓库的调用方、POM 或测试作为只读证据；这些路径会记录在私有 `.meta.tsv` 中。未提供下游 context 时，结果只能按单仓库范围解释。

需要验证真实历史结果的重复稳定性时，使用 `./evals/run-history-repeat.sh --runs 3`。它为每一轮创建独立子目录，并逐提交比较完整 `.txt` 输出及模型/SYSTEM/脚本哈希、参数和退出状态；任一结果内容或运行配置漂移都会以非零状态失败。仅耗时和结果文件绝对路径不参与比较。

更新规则或参数后，可用 `./scripts/verify-runtime.sh` 只读检查 Ollama 中的 tuned 模型是否仍与当前 `config/Modelfile` 一致。校验失败时按脚本提示同步并执行 `ollama create`；脚本不会自动重建模型。
历史评测运行器不会替下游仓库切换 Git ref，也不会替外部文件推断目标版本；请先在下游仓库检出匹配快照，或用 `scripts/extract-context-snapshot.sh` / `git show <ref>:<path>` 提取私有快照后再传入。为避免把主仓库当前工作树误当成历史证据，`run-history.sh` 会拒绝指向主仓库的 context，并在每个提交开始前把外部 context 冻结到临时快照，模型只读取该快照。私有 `.meta.tsv` 会记录原始路径和快照 SHA-256，便于复核版本是否被意外替换。

```bash
./evals/run-history.sh \
  --repo /path/to/local/repo \
  --manifest ~/.local/share/local-review/evals/platform-api-20.tsv \
  --out-dir ~/.local/share/local-review/evals/platform-api-results \
  --limit 1
```

跨仓库契约评测示例：

```bash
./evals/run-history.sh \
  --repo /path/to/platform-api \
  --manifest ~/.local/share/local-review/evals/platform-api-20.tsv \
  --out-dir ~/.local/share/local-review/evals/platform-api-results-cross-repo \
  --commit <sha> \
  --context /path/to/platform-file/src/main/java/.../Consumer.java \
  --context /path/to/platform-file/pom.xml
```

运行结果仍需人工确认真实问题、误报、行号和无问题提交，不能把模型输出直接当作标注。

完成人工标注后，建议把每个提交去重为一行，并明确填写 `gold_p0_p1`（人工确认的 P0/P1 根因数）和 `p0_p1_found`（模型实际命中的 P0/P1 根因数）。可复制 [scorecard.template.tsv](scorecard.template.tsv) 开始填写。使用以下命令汇总，脚本会校验必需列（允许保留额外元数据列）、重复提交、非法数字、`p0_p1_found` 超过人工真值或未完成的输出：

```bash
./evals/summarize-scorecard.sh ~/.local/share/local-review/evals/platform-api-labels/stage1-consolidated-scorecard.tsv
```

可以先生成不覆盖已有标签的人工标注模板：

```bash
./evals/prepare-history-labels.sh \
  --manifest ~/.local/share/local-review/evals/platform-api-20.tsv \
  --results ~/.local/share/local-review/evals/platform-api-results \
  --labels-dir ~/.local/share/local-review/evals/platform-api-labels
```

模板是私有 TSV。逐条阅读 `source_result` 后填写 `finding_id`、严重级别、仓库相对路径、行号、`confirmed`/`missed`/`false-positive`/`uncertain` 和备注；`missed` 用于记录人工确认但模型没有输出的 P0/P1 根因，脚本不会覆盖已有人工标签。
模板同时记录 `source_result_sha256`；如果结果目录搬迁，只要内容哈希完全一致即可安全复用，结果内容改变则必须重新人工复核。
旧版本模板没有该字段时，构建器会拒绝汇总；应重新运行模板生成器，不要手工猜测或补写哈希。

如果只是结果目录搬迁，可用 `migrate-labels.sh` 做内容哈希验证迁移。它不会覆盖已有标签目录，只迁移结果文本完全相同、标签条目数量不超过最终结果候选数且文件/行号能与最终候选重叠的 complete 标签；疑似来自另一份/原始模型响应的标签会被跳过，其余提交保留在原目录等待重新标注：

```bash
./evals/migrate-labels.sh \
  --labels-dir ~/.local/share/local-review/evals/platform-api-labels-old \
  --from-results-dir ~/.local/share/local-review/evals/platform-api-results-old \
  --to-results-dir ~/.local/share/local-review/evals/platform-api-results-new \
  --out-labels-dir ~/.local/share/local-review/evals/platform-api-labels-new
```
模板中的 `# verdict` 还需要填写为 `clean` 或 `findings`：前者表示整次提交人工确认无问题，后者表示至少有一个已确认问题。`# review_status` 填写为 `pending` 或 `complete`；只有标为 `complete` 的提交才应进入汇总。若一次提交有多个模型发现，先逐条记录，再在汇总表中按根因去重为一行，避免把同一问题重复计算。

标签完成后，可用 `build-scorecard.sh` 从 `.labels.tsv`、`.meta.tsv` 和结果文本自动生成汇总 TSV，避免手工抄录运行参数和候选数量：

```bash
./evals/build-scorecard.sh \
  --labels-dir ~/.local/share/local-review/evals/platform-api-labels \
  --results-dir ~/.local/share/local-review/evals/platform-api-results \
  --out ~/.local/share/local-review/evals/platform-api-scorecard.tsv
./evals/summarize-scorecard.sh \
  ~/.local/share/local-review/evals/platform-api-scorecard.tsv
```

构建器只输出 `review_status=complete` 且运行成功的提交；它会校验标签中的 `# source_result_sha256` 与所选结果文件内容完全一致，并逐条校验 confirmed/false-positive 的文件和行号与结果候选重叠，允许安全搬迁同一结果，拒绝把旧 profile/旧运行的标签套到不同结果上。`missed` 是人工记录的 false negative，必须使用 P0/P1、真实路径、正数行号和证据备注，并且不能与所选结果中的任何候选范围重叠；否则标签与结果矛盾，构建器会 fail-closed。`uncertain` 不计入指标。缺少结果、元数据或字段不完整会 fail-closed；失败时不会留下半成品输出。输出仍应保存在私有目录，不要提交业务源码、模型响应或凭据。

1. 固定至少 20 个真实历史提交作为评测集，并按提交切分训练示例和留出评测集。
   不要随机打散相邻提交；优先按功能簇（例如同一接口迁移、同一安全修复链）整体分配到 train/dev/holdout，避免相邻提交泄漏。
2. P0/P1 真实问题召回率目标不低于 90%；如果样本不足，记录实际样本数，不得用主观印象替代指标。
3. 误报必须单独统计；每条输出都能定位到文件、行号和代码证据。
4. 审查输出不能静默截断。API 错误、空响应或 `done_reason=length` 必须以非零状态退出并明确提示。
5. 同一提交重复审查时，结果应基本稳定；固定 seed 只用于降低波动，不能代替人工复核。
6. 每次评测记录模型名、temperature、seed、num_ctx、提交、耗时和人工结论。

### 大差异分片

当 diff 超过 `OLLAMA_REVIEW_MAX_DIFF_BYTES` 时，运行器会按 `diff --git` 文件边界、再按 unified diff hunk 边界依次调用模型。分片不会使用向量检索或 Embedding，因此这不是 RAG；它只是为了降低单次输出截断和上下文超时的概率。每个分片失败都会使整次审查失败，已完成分片只保留为诊断材料，不能计入完整性通过。

预算按字节计算；无法继续拆分的单个 hunk 和 `diff --cc`/combined diff 必须显式失败。输出门禁还要求每个空行分隔的问题段首行带严重级别和真实的文件路径/行号，泛化的“文件路径”文字不能通过；如果目标文件或显式 `--context` 文件存在，还会按当前内容校验行号/行号范围，超出范围的模型结果会被拒绝。已删除文件因当前内容不存在而跳过该范围校验，但仍保留差异和构建预检证据。

该预算只针对 Git diff 本身，不代表完整请求一定能放入 `num_ctx`；项目规则、显式上下文和系统提示词仍需计入容量。

运行器的确定性构建和安全预检可用无模型回归测试验证：

```bash
./evals/test-preflight.sh
```

该测试覆盖当前差异新增但仓库缺失的类型、显式 `--context` 仍引用当前提交删除类型的跨仓库候选、URL 查询令牌、Java 包装类型除法、跨 hunk SSRF、URL builder、路径 API 别名和配置硬编码凭据；它使用假的 Ollama/Curl，验证预检证据注入、确定性结果合并、问题段字段完整性和输出门禁，不消耗模型推理。

scorecard 汇总器也有独立的输入校验回归：

```bash
./evals/test-scorecard.sh
```

标签到 scorecard 的构建器也有回归测试：

```bash
./evals/test-scorecard-builder.sh
```

运行态规则校验也有独立回归测试：

```bash
./evals/test-runtime-verify.sh
```

它验证完整 SYSTEM 规则一致时通过、规则发生漂移时 fail-closed。

路径门禁只允许变更文件和显式 `--context` 文件作为报告目标；`AGENTS.md`、README 只作为证据输入，不会被模型当成待审查文件。同名 basename 只有唯一时才算匹配，避免把泛化的“文件路径”当成证据。

## 样本原则

样本应保存提交或差异标识、必要上下文、人工确认的问题列表、严重级别、文件和行号、证据、影响、修复建议和验证方式。必须包含“无问题”和“容易误报但实际不是问题”的样本。

不要把未经人工确认的模型输出直接当作标准答案，也不要把整个仓库原样作为训练数据。
