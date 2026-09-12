# Local Code Audit（本地代码审计）

[English README](README.md)

这是一个面向个人开发者的本地代码审计闭环：

`Git diff → 项目规则和相关上下文 → Ollama 本地模型 → 完整审计结果 → 人工验证 → 固定评测集`

默认模型是 `devstral-small-2-review-tuned`。它基于本机已有的 `devstral-small-2-review` 创建 Ollama 派生配置，不会重新训练或替换基础模型权重。

## 目标

- 优先提高 P0/P1 问题召回率；
- 每条问题都必须有文件、行号和代码证据；
- 不静默过滤、合并、去重或截断模型输出；
- API 错误、空响应或输出长度超限时明确失败；
- 业务源码、真实 diff 和私有 Review 示例不进入公开仓库；
- 同一套全局命令可用于多个 Git 仓库。

## 安装或更新全局命令

```bash
ollama create devstral-small-2-review-tuned:latest -f config/Modelfile
./scripts/install-global.sh
```

安装脚本只安装本地命令，不会自动下载模型。

## 使用

在任意 Git 仓库中运行：

```bash
local-review
local-review --repo /path/to/repo --base origin/main
local-review --context src/main/java/path/to/RelatedService.java
local-review --examples /path/to/private/examples.md
```

可以通过环境变量做单次 A/B 测试：

```bash
OLLAMA_REVIEW_MODEL=devstral-small-2-review \
OLLAMA_REVIEW_NUM_CTX=32768 \
OLLAMA_REVIEW_NUM_PREDICT=4096 \
local-review --repo /path/to/repo
```

默认上下文为 16k；机器内存充足且变更较大时可设置 `OLLAMA_REVIEW_NUM_CTX=32768`。默认输出上限为 4096 tokens。如果输出达到上限，命令会明确报告截断并失败，不会把半截审计结果当作成功。大型变更应按文件或模块拆分审查。

默认采样参数为 `top_k=40`、`top_p=0.9`；除非在评测记录中明确记录覆盖值，否则不要随意修改。

默认温度为 `0`，用于提高本地审查的可重复性；它不能替代人工复核。

默认 `keep_alive=0`，每次审查后释放模型。连续审查时可以设置 `OLLAMA_REVIEW_KEEP_ALIVE=5m`。

## 评测

建立至少 20 个经过人工确认的历史提交作为私有评测集，并按照 [evals/README.md](evals/README.md) 记录召回率、误报、行号准确率、完整性和耗时。

修改提示词或运行参数前，先运行公开的合成回归门槛：

```bash
./evals/run-synthetic.sh
```

当前门槛故意设置得严格：出现额外 P0～P3 问题、矛盾输出、API 错误、超时或截断都会失败。验收目标和当前状态见 [evals/goal.md](evals/goal.md)。

真实历史提交评测请按照 [evals/README.md](evals/README.md) 使用，并将清单、原始输出和人工标签保存在公开仓库之外。

`examples/` 目录只保存公开的格式说明。真实 few-shot 示例放在本机私有文件 `~/.local/share/local-review/examples.md`。

完整调优过程和期间遇到的问题记录在 [docs/tuning-process.zh-CN.md](docs/tuning-process.zh-CN.md)。

## 隐私与 GitHub

公开仓库是 [MintNiu/local-code-audit](https://github.com/MintNiu/local-code-audit)，许可证为 Apache License 2.0。不要提交业务源码、真实 diff、访问令牌、模型权重或私有 Review 数据。

## 提交说明规范

使用 `feat:`、`fix:`、`docs:`、`perf:` 等 Conventional Commits 类型。类型保留英文，类型后面的具体说明使用中文。
