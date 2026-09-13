# Local Code Audit（本地代码审计）

[English README](README.md)

这是一个面向个人开发者的本地代码审计闭环：

`Git diff → 项目规则和相关上下文 → Ollama 本地模型 → 完整审计结果 → 人工验证 → 固定评测集`

默认模型是 `devstral-small-2-review-tuned`。它基于本机已有的 `devstral-small-2-review` 创建 Ollama 派生配置，不会重新训练或替换基础模型权重。

## 目标

- 优先提高 P0/P1 问题召回率；
- 每条问题都必须有文件、行号和代码证据；
- 不静默丢弃或截断问题；同一根因只有在完整保留所有受影响文件/行号范围时才可以合并表示；
- API 错误、空响应或输出长度超限时明确失败；
- 业务源码、真实 diff 和私有 Review 示例不进入公开仓库；
- 同一套全局命令可用于多个 Git 仓库。

## 安装或更新全局命令

```bash
./scripts/sync-modelfile.sh
ollama create devstral-small-2-review-tuned:latest -f config/Modelfile
./scripts/install-global.sh
```

安装脚本只安装本地命令，不会自动下载模型。
如果安装后终端提示找不到命令，请将 `export PATH="$HOME/.local/bin:$PATH"` 写入
`~/.zprofile`（或当前 shell 的启动文件），然后重新打开终端。
审计边界以 `bin/local-review.sh` 为来源；`scripts/sync-modelfile.sh` 会把它同步到 `config/Modelfile`，供直接 Ollama 使用。`local-review` 链路还会额外执行确定性的输出门禁。修改规则后，请先同步并重新创建 tuned 模型。

前置条件是 Ollama 服务正在运行、本地已有选定模型、Git、`jq`、`rg`（ripgrep）和 Perl。macOS 通常自带 `curl`、`awk`、`tr`、`sort` 和 `/usr/bin/perl`；可以用 `command -v ollama jq git curl awk tr sort rg perl` 检查。使用 Homebrew 时，缺少工具可执行 `brew install jq ripgrep`。

## 使用

在任意 Git 仓库中运行：

```bash
local-review
local-review --repo /path/to/repo --base origin/main
local-review --context src/main/java/path/to/RelatedService.java
local-review --examples /path/to/private/examples.md
```

如果当前提交删除、重命名或修改了对外 API、DTO 或声明式客户端，审查主仓库不会自动读取其他仓库。请先从与目标提交匹配的下游 Git ref 提取消费者接口、配置、调用方或测试文件，再逐个用 `--context` 传入（该参数可重复），否则只能得到当前仓库范围内的结论。历史评测可使用 `scripts/extract-context-snapshot.sh` 生成私有快照：

```bash
local-review --repo /path/to/platform-api \
  --context /path/to/platform-file/src/main/java/.../InternalFileController.java \
  --context /path/to/platform-file/pom.xml
```

这是个人高性能审查中检查跨仓库兼容性的必要步骤；上下文文件只作为证据输入，不会被修改。

个人高性能模式使用单独命令：

```bash
local-review-local
local-review-local --repo /path/to/repo --base origin/main
```

它保留证据、权限和安全检查，默认沿用已在真实提交上验证过的 16k/4096 预算，并在连续审查时保留模型；真实跨仓库大 diff 曾证明盲目使用 32k/8192 会增加超时。仍可用同一组 `OLLAMA_REVIEW_*` 环境变量临时覆盖。`local-review` 是保守基线，`local-review-local` 提供个人本地高性能默认值；两者都可使用本机私有 few-shot 数据。

实测同一个 clean 样例：保留模型 5 分钟时连续两次约 23 秒、4 秒；每次卸载时约 20 秒、21 秒。因此本地高性能版默认保留模型用于连续审查；更关注电量时可设置 `OLLAMA_REVIEW_KEEP_ALIVE=0`。

可以通过环境变量做单次 A/B 测试：

```bash
OLLAMA_REVIEW_MODEL=devstral-small-2-review \
OLLAMA_REVIEW_NUM_CTX=32768 \
OLLAMA_REVIEW_NUM_PREDICT=4096 \
local-review --repo /path/to/repo
```

默认上下文为 16k；机器内存充足且变更较大时可设置 `OLLAMA_REVIEW_NUM_CTX=32768`。默认输出上限为 4096 tokens。如果输出达到上限，命令会明确报告截断并失败，不会把半截审计结果当作成功。大型变更应按文件或模块拆分审查。

当收集到的 diff 超过 `OLLAMA_REVIEW_MAX_DIFF_BYTES`（默认 `3000`）时，`local-review` 会按文件边界、再按 unified diff hunk 边界自动进行确定性分片。每个分片独立审查，最后完整拼接结果；只删除字节完全相同的重复段落，不同问题都会保留。分片默认使用 `OLLAMA_REVIEW_CHUNK_TIMEOUT_SECONDS=180` 和 `OLLAMA_REVIEW_CHUNK_NUM_PREDICT=2048`；任何分片超时、截断或输出格式不合格都会使整次审查失败，已完成分片只作为诊断输出。

每个分片还会收到本次提交全部变更文件的路径清单。清单只作为范围元数据，不附加其他文件源码；它帮助模型区分“实现在另一个分片”与“确实缺失”，但当前分片未展示的内容仍不能作为问题证据。

如果单个 hunk 仍然超过字节预算，或检测到 Git combined diff（`diff --cc` / `diff --combined`），命令会明确拒绝，不会把超预算内容作为不安全的完整提示词发送给模型。

字节预算只约束收集到的 Git diff；项目规则、显式上下文文件、README 和系统提示词还会额外占用上下文。它们较大时，应提高 `OLLAMA_REVIEW_NUM_CTX` 或进一步拆分审查。

输出门禁会拒绝泛化或不完整总结：每个问题段都必须包含严重级别、能匹配变更文件或显式上下文文件的文件/行号，以及明确的“影响：”“修复建议：”“验证方式：”字段；只有在当前审查集合中唯一时才接受单独的文件名。

默认采样参数为 `top_k=40`、`top_p=0.9`；除非在评测记录中明确记录覆盖值，否则不要随意修改。

默认温度为 `0`，用于提高本地审查的可重复性；它不能替代人工复核。

保守基线命令 `local-review` 默认 `keep_alive=0`，每次审查后释放模型；个人高性能命令 `local-review-local` 默认保留 5 分钟。更关注电量时可设置 `OLLAMA_REVIEW_KEEP_ALIVE=0`。

## 评测

建立至少 20 个经过人工确认的历史提交作为私有评测集，并按照 [evals/README.md](evals/README.md) 记录召回率、误报、行号准确率、完整性和耗时。

修改提示词或运行参数前，先运行公开的合成回归门槛：

```bash
./evals/run-synthetic.sh
```

当前门槛故意设置得严格：出现额外 P0～P3 问题、矛盾输出、API 错误、超时或截断都会失败。验收目标和当前状态见 [evals/goal.md](evals/goal.md)。

真实历史提交评测请按照 [evals/README.md](evals/README.md) 使用，并将清单、原始输出和人工标签保存在公开仓库之外。

可以用 `evals/prepare-history-labels.sh` 生成不会覆盖已有标签的私有 TSV 标注模板，再人工确认召回率和误报率。
每个模板先填写 `# verdict`（`clean` 或 `findings`）和 `# review_status`（完成后填 `complete`），再逐条标记发现；未完成或 `uncertain` 的记录不应计入汇总指标。

`examples/` 目录只保存公开的格式说明。真实 few-shot 示例放在本机私有文件 `~/.local/share/local-review/examples.md`。

完整调优过程和期间遇到的问题记录在 [docs/tuning-process.zh-CN.md](docs/tuning-process.zh-CN.md)。

## 隐私与 GitHub

公开仓库是 [MintNiu/local-code-audit](https://github.com/MintNiu/local-code-audit)，许可证为 Apache License 2.0。不要提交业务源码、真实 diff、访问令牌、模型权重或私有 Review 数据。

## 提交说明规范

使用 `feat:`、`fix:`、`docs:`、`perf:` 等 Conventional Commits 类型。类型保留英文，类型后面的具体说明使用中文。
