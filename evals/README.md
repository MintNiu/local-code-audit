# 评测目标

目标是把本地模型调成可重复、可验证的代码审计模型，而不是只追求输出更长。

## 初始验收标准

公开的合成回归入口是 `./evals/run-synthetic.sh`，目标、夹具和当前状态记录在 [goal.md](goal.md)。它用于每次调参后的快速回归，但不能替代真实历史提交评测。

真实历史提交使用 `./evals/run-history.sh`。它默认调用个人高性能 `local-review-local`，只读取本地仓库，在临时目录展开父提交并应用目标 diff，把原始结果和元数据写入你指定的私有目录；不要把该目录指向本公开仓库。需要对比保守基线时，追加 `--profile baseline`。
准备历史 diff 时同样会禁用仓库配置的 `textconv` 和 fsmonitor，确保评测过程不会执行目标仓库的可配置 Git 命令。
每个提交的 `.meta.tsv` 会记录 profile、模型选择、temperature、seed、top-k/top-p、上下文/输出预算、diff 字节预算和 `keep_alive`，避免个人版与基线结果混用。

```bash
./evals/run-history.sh \
  --repo /path/to/local/repo \
  --manifest ~/.local/share/local-review/evals/platform-api-20.tsv \
  --out-dir ~/.local/share/local-review/evals/platform-api-results \
  --limit 1
```

运行结果仍需人工确认真实问题、误报、行号和无问题提交，不能把模型输出直接当作标注。

完成人工标注后，建议把每个提交去重为一行，并明确填写 `gold_p0_p1`（人工确认的 P0/P1 根因数）和 `p0_p1_found`（模型实际命中的 P0/P1 根因数）。使用以下命令汇总，脚本会拒绝重复提交或缺少严格指标列：

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

模板是私有 TSV。逐条阅读 `source_result` 后填写 `finding_id`、严重级别、仓库相对路径、行号、`confirmed`/`false-positive`/`uncertain` 和备注；脚本不会覆盖已有人工标签。

1. 固定至少 20 个真实历史提交作为评测集，并按提交切分训练示例和留出评测集。
   不要随机打散相邻提交；优先按功能簇（例如同一接口迁移、同一安全修复链）整体分配到 train/dev/holdout，避免相邻提交泄漏。
2. P0/P1 真实问题召回率目标不低于 90%；如果样本不足，记录实际样本数，不得用主观印象替代指标。
3. 误报必须单独统计；每条输出都能定位到文件、行号和代码证据。
4. 审查输出不能静默截断。API 错误、空响应或 `done_reason=length` 必须以非零状态退出并明确提示。
5. 同一提交重复审查时，结果应基本稳定；固定 seed 只用于降低波动，不能代替人工复核。
6. 每次评测记录模型名、temperature、seed、num_ctx、提交、耗时和人工结论。

### 大差异分片

当 diff 超过 `OLLAMA_REVIEW_MAX_DIFF_BYTES` 时，运行器会按 `diff --git` 文件边界、再按 unified diff hunk 边界依次调用模型。分片不会使用向量检索或 Embedding，因此这不是 RAG；它只是为了降低单次输出截断和上下文超时的概率。每个分片失败都会使整次审查失败，已完成分片只保留为诊断材料，不能计入完整性通过。

预算按字节计算；无法继续拆分的单个 hunk 和 `diff --cc`/combined diff 必须显式失败。输出门禁还要求每个空行分隔的问题段首行带严重级别和真实的文件路径/行号，泛化的“文件路径”文字不能通过。

该预算只针对 Git diff 本身，不代表完整请求一定能放入 `num_ctx`；项目规则、显式上下文和系统提示词仍需计入容量。

运行器的确定性构建预检可用无模型回归测试验证：

```bash
./evals/test-preflight.sh
```

该测试覆盖当前差异新增但仓库缺失的类型，以及显式 `--context` 仍引用当前提交删除类型的跨仓库候选；它使用假的 Ollama/Curl，仅验证发送给模型的证据，不消耗模型推理。

路径门禁允许变更文件、`AGENTS.md`、README 和显式 `--context` 文件；同名 basename 只有唯一时才算匹配，避免把泛化的“文件路径”当成证据。

## 样本原则

样本应保存提交或差异标识、必要上下文、人工确认的问题列表、严重级别、文件和行号、证据、影响、修复建议和验证方式。必须包含“无问题”和“容易误报但实际不是问题”的样本。

不要把未经人工确认的模型输出直接当作标准答案，也不要把整个仓库原样作为训练数据。
