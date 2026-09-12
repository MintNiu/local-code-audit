# 本地代码审计模型调优过程

本文记录 `devstral-small-2-review-tuned` 从可运行基线到当前版本的完整调优过程、遇到的问题、修复方式和仍然存在的限制。

## 1. 最终目标

目标不是让模型输出更多，而是让它成为一个可高频使用、可重复验证的代码审计模型：

- 尽量提高 P0/P1 真实问题召回率；
- 每条发现都能定位到文件、行号和代码证据；
- 降低风格建议、无依据边界和重复汇总造成的误报；
- API 错误、空响应和输出截断必须明确失败；
- 适用于多个 Git 仓库，并且真实业务数据不进入公共仓库。

## 2. 初始状态

最初的本地模型是 `devstral-small-2-review`，后来已有一个 `devstral-small-2-review` 的 Ollama 派生模型。检查其 Modelfile 后确认：

- `temperature=0.15`；
- `num_ctx=32768`；
- 没有专门的代码审计系统规则和人工确认示例；
- 全局 `local-review.sh` 主要把 Git diff 和审查要求拼接成一次普通请求。

因此没有直接做 LoRA 微调，而是先优化输入、系统指令、示例、运行边界和评测方式。原始模型没有被覆盖。

## 3. 调优过程与遇到的问题

### 3.1 把稳定规则从普通提示词提升为系统指令

原脚本把审查规则放在 diff 后面，规则和待审查内容处在同一个用户输入中。改为通过 Ollama `/api/generate` 的 `system` 字段发送稳定规则，用户输入只承载仓库状态、规则文件、示例和 diff。

同时增加：

- `--context <file>`，允许显式加入相关接口、调用方、DTO、测试等上下文；
- `--examples <file>` 和 `LOCAL_REVIEW_EXAMPLES_FILE`，支持本机私有 few-shot 示例；
- `temperature`、`seed`、`num_ctx`、`num_predict`、`keep_alive` 的环境变量覆盖。

### 3.2 建立派生模型

创建了 `devstral-small-2-review-tuned:latest`，基础模型仍然是本地已有的 `devstral-small-2-review:latest`。当前 Modelfile 参数为：

```text
num_ctx 16384
temperature 0.15
seed 42
top_k 40
top_p 0.9
num_predict 4096
```

派生模型增加了证据驱动的代码审计系统规则，但没有重新下载或训练基础权重。

### 3.3 发现并修复脚本可用性问题

第一次端到端测试时，在没有传 `--context` 的情况下，Bash 严格模式因为空数组展开直接退出：

```text
context_files[@]: unbound variable
```

修复为只有在上下文数组非空时才遍历。这个问题说明高可用性必须用真实命令链路验证，而不能只做 `bash -n`。

### 3.4 抑制低价值误报

初始测试中模型正确发现了除零和空值风险，但还报告了：

- `final` 类可能影响未来扩展；
- 缺少 Javadoc；
- 没有足够证据的泛化可维护性问题。

随后加入规则：除非项目规则或当前差异证明了具体行为、兼容性、安全或维护风险，否则不报告风格、命名、Javadoc、`final` 或泛化建议。

### 3.5 发现无限输出导致的长时间请求

在加入 few-shot 示例后，一次小 diff 审查曾经超过 5 分钟没有返回。原因不是请求没有发出，而是没有设置最大生成长度，模型持续生成过多解释。

修复方式：

- 设置 `num_predict=4096`；
- 检查 Ollama 返回的 `done_reason`；
- 如果返回 `length`，命令以非零状态失败，并明确提示“模型输出被截断”；
- 不把半截审计结果伪装成成功结果；
- 关闭长时间自动重试，避免单次故障拖延几十分钟。

### 3.6 修正 Java 整数除法语义

模型一度错误地把普通 Java 整数除法报告为“可能溢出”，并声称 `Integer.MIN_VALUE / -1` 会抛出 `ArithmeticException`。

加入 Java 语义约束和负例后，当前规则明确：

- 关注包装类型为 `null`；
- 关注除数为 `0`；
- `int` 的 `Integer.MIN_VALUE / -1` 不应被描述为会抛出 `ArithmeticException`；
- 不把同一根因的具体问题再次汇总成重复问题。

在固定临时路径的一轮合成测试中，模型曾只保留两个有证据的问题：`Integer` 空值和除零。但随后把同一夹具复制到不同临时仓库并重复调用时，模型又生成了整数除法截断、`final`、Javadoc 和重复汇总等误报，因此这次结果不能作为稳定性验收。

### 3.7 发现采样和服务稳定性问题

重复测试发现固定 `seed` 并不能保证这个本地模型在不同请求中完全一致：

- `top_k=1` 会让完整审计请求长时间无响应；改回 `top_k=40`、`top_p=0.9` 后，短审计请求可在约 20 秒返回；
- 同一差异有时返回 2 条 P1，有时返回 5 条（额外包含 P2/P3 误报）；
- 只看退出码不足以验收，因此 `evals/run-synthetic.sh` 现在严格检查正例必须恰好 2 条、负例不能有任何 P0～P3，并单独检查截断故障；
- 连续测试可临时使用 `OLLAMA_REVIEW_KEEP_ALIVE=5m`，但这只减少模型反复加载，不能替代稳定性验证。

因此当前模型仍未达到阶段 0 回归门槛，不能宣称已经具备高可用审计质量。

## 4. 当前运行链路

```text
Git 状态和 diff
    ↓
项目规则 + 可选上下文 + 本机人工确认示例
    ↓
local-review 的 system 指令与 Ollama options
    ↓
devstral-small-2-review-tuned
    ↓
校验 response、done_reason 和截断状态
    ↓
输出完整审计结果或明确失败
```

全局命令位于：

```text
~/.local/bin/local-review
```

源代码位于本项目的 `bin/local-review.sh`。真实 few-shot 数据默认位于：

```text
~/.local/share/local-review/examples.md
```

该文件不在公开仓库中。

## 5. 已完成的验证

- `bash -n` 通过；
- `ollama create` 成功创建 tuned 模型；
- 最小 Ollama 请求返回 `done=true`、`done_reason=stop`；
- 空 `--context` 参数的端到端问题已修复；
- 输出达到上限时会明确失败，不返回半截结果；
- 严格回归脚本能够捕获合成样例中的 P2/P3 误报、矛盾输出和截断故障；阶段 0 当前仍为未通过；
- 本地项目已使用 SSH 推送到公开仓库 `MintNiu/local-code-audit`；
- 公开仓库使用 Apache License 2.0。

## 6. Codex 接入过程中遇到的问题

调优期间也验证了 Codex 与 Ollama 的两种接入方式，这些问题影响的是接入稳定性，不是基础模型权重：

- 直接使用 Codex OSS/Ollama 路径时，模型列表刷新曾因为客户端期待的响应字段与 Ollama 兼容接口返回的 OpenAI 风格列表结构不一致而报错；这不应通过反复下载模型来解决。
- `devstral-small-2` 不支持 thinking。Codex 默认推理强度会触发重连，改为 `model_reasoning_effort="none"` 后，profile 调用成功返回。
- `codex exec review --commit <sha>` 不接受额外的普通提示词参数。提交审查应按该子命令的参数约定调用，避免把 CLI 用法错误误判成模型故障。

最终保留两条互补链路：Codex profile 用于交互式探索，`local-review` 用于可复现的批量审计、输出完整性检查和跨仓库使用。两条链路共享同一个 Ollama 派生模型，但不把交互式成功误认为审计质量已经经过量化验证。

## 7. 当前限制与下一阶段

当前仍然没有完成真正的 20～30 个历史提交评测，因此还不能声称已经达到 90% 的 P0/P1 召回率目标。下一阶段应：

1. 从真实项目挑选至少 20 个历史提交；
2. 人工确认每个提交的真实问题、误报和无问题结果；
3. 按提交切分 few-shot 示例和留出评测集；
4. 记录召回率、误报率、行号准确率、输出完整性和耗时；
5. 只有 Prompt、上下文和 few-shot 仍然不足时，才评估 LoRA/QLoRA。

未经人工确认的模型输出不能直接作为训练标签，业务源码和真实 diff 不能提交到这个公开仓库。
