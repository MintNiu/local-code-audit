# Local Code Audit

一个面向个人开发者的本地代码审计闭环：

`Git diff → 项目规则/相关上下文 → Ollama 本地模型 → 完整审计结果 → 人工验证 → 固定评测集`

当前默认模型是 `devstral-small-2-review-tuned`。它是基于本地已有 `devstral-small-2-review` 的 Ollama 派生配置，不会重新下载或修改基础模型权重。

## 设计目标

- 优先保证 P0/P1 问题召回率；
- 每条问题必须有文件、行号和代码证据；
- 不过滤、合并、去重或截断模型输出；
- API 失败、空响应和长度截断必须显式失败；
- 真实业务样例和评测结果保留在本机，不进入公共仓库；
- 同一套命令可用于多个 Git 项目。

## 安装或更新全局命令

```bash
ollama create devstral-small-2-review-tuned:latest -f config/Modelfile
./scripts/install-global.sh
```

安装脚本只安装本地脚本，不自动下载模型。

## 使用

在任意 Git 仓库中运行：

```bash
local-review
local-review --repo /path/to/repo --base origin/main
local-review --context src/main/java/path/to/RelatedService.java
local-review --examples /path/to/private/examples.md
```

可通过环境变量临时做 A/B 测试：

```bash
OLLAMA_REVIEW_MODEL=devstral-small-2-review \
OLLAMA_REVIEW_NUM_CTX=16384 \
local-review --repo /path/to/repo
```

默认 `keep_alive=0`，一次审查结束后释放模型，减少长期占用内存和电量。需要连续审查时可以临时设置 `OLLAMA_REVIEW_KEEP_ALIVE=5m`。

默认上下文为 16k，优先保证 Mac 上的响应时间和稳定性；大型变更可临时设置 `OLLAMA_REVIEW_NUM_CTX=32768`，但应配合分文件审查并观察内存和耗电。

## 评测

先把 20 个以上人工确认的历史提交整理到本机私有目录，再按 [evals/README.md](evals/README.md) 记录召回率、误报、行号准确率、完整性和耗时。

`examples/` 只保存格式说明。真实 few-shot 示例默认放在：

`~/.local/share/local-review/examples.md`

## 隐私与 GitHub

这个仓库已发布到 GitHub；请确认后续只提交脚本、配置模板和评测规范，不要提交业务源码、真实 diff、访问令牌、模型权重或私有 Review 数据。当前远程仓库为 `git@github.com:MintNiu/local-code-audit.git`。
