# 外部数据集使用边界

本文定义个人本地代码审计模型如何使用外部数据。外部数据的作用是补充语言覆盖、审查表达和安全根因回归，不替代 Platform 真实提交的独立 holdout，也不直接改变正式召回率。

## 推荐顺序

| 优先级 | 数据集 | 主要用途 | 当前处理方式 |
| --- | --- | --- | --- |
| 1 | [AACR-Bench](https://github.com/alibaba/aacr-bench) | 真实 PR 的评论、定位、类别和多语言审查表达 | 先抽取少量 Java/TS/SQL/配置样本做 external-smoke；原始 PR 和引用仓库许可证逐项记录 |
| 2 | [Vul4J](https://github.com/tuhh-softsec/Vul4J) | 真实 Java 漏洞、修复补丁和 PoV 测试 | 优先使用有 PoV 的子集；PoV 与仅静态告警样本分层统计，不混成一个金标 |
| 3 | [JavaVFC](https://zenodo.org/records/13731781) | 人工核验的 Java 修复提交 | 784 条人工集用于 train/dev 候选；extended 启发式集只能做 smoke，按仓库和提交谱系去重 |
| 4 | [NIST Juliet/SARD](https://www.nist.gov/publications/juliet-11-cc-and-java-test-suite) | CWE 正负对照、行号和输出协议回归 | 只抽取小型 Java 子集；合成样本不代表真实世界召回率 |

暂缓 OWASP BenchmarkJava、MegaVul、PrimeVul、GitBug-Java 和 Defects4J：前几项存在 GPL/数据许可或标签质量边界，后几项体量大、偏通用缺陷或下载成本高。任何重新引入都必须先完成许可证和磁盘成本复核。

## 数据隔离

原始压缩包、源码、完整 diff、评论和规范化 JSONL 均放在本机私有目录，例如：

```text
~/.local/share/local-review/datasets/<dataset>/
```

公开仓库只保留处理脚本、字段规范和不含源码的来源 manifest。manifest 至少记录：数据集版本、来源 URL、抓取日期、许可证、归档 SHA-256、样本数量、语言、仓库标识、提交标识和处理脚本版本。

每条规范化记录至少包含：

```text
id, source_url, source_commit, license, language, framework,
repo_id, task_type, cwe, severity, files, changed_lines,
before, after, comments, tests, split, provenance, verification
```

按 `repo_id + commit`、漏洞/CVE/CWE 谱系和时间切分 train/dev/holdout。同一仓库的相邻修复、同一漏洞的不同语言改写和后续修复提交不得跨 split。holdout 不进入 few-shot，也不参与规则设计。

## 采样和指标

目标是 Java 深度优先、语言不设硬限制。第一阶段 external-smoke 的建议配比为：Java/Spring/MyBatis 55%–65%，JavaScript/TypeScript/Vue 约 15%，SQL/迁移 10%–15%，YAML/JSON/CI/容器配置 5%–10%，Python/Go/C++/Rust 等合计 5%–10%。每一类都要保留 clean 或容易误报的负例。

few-shot 每次只检索 2–4 条短、脱敏、行号稳定的示例，优先用于输出格式、根因解释和跨语言术语对齐；不能把整库拼入提示词，也不能通过提高上下文上限掩盖容量问题。私有示例仍须经过 `scripts/validate-external-dataset.py`，并受默认 16K fail-closed 预算约束。

外部数据分别记录：模型原生命中、确定性预检补齐、root-cause 召回、行号准确率、误报率、输出完整、双轮稳定、超时和截断。只有包含可定位 diff、变更文件和人工/可复现证据的样本才可进入代码审计召回统计。只有自然语言评论而没有稳定代码位置的数据，只能用于表达和排序实验，不能冒充 P0/P1 金标。

Platform 真实提交仍是最终独立 holdout。评测时间线审计后，4451 的权限注解预检和 f895 的路径穿越预检均从独立表移入 tuning-source；截至 2026-10-08，新增 HR/幼教、配置和小程序身份样本后，严格 scorecard 为 17 个 gold P0/P1、模型命中 3 个、召回 17.6%，输出完整与双轮稳定 20/20。外部数据的改善不能直接写入这个分母。

当前已将 AACR-Bench 两个原始 JSON 按人工评论转换为 40 条 `external-smoke` 记录（10 种语言各 4 条），并通过 `validate-external-dataset.py`；转换器默认剔除 `is_ai_comment=true` 的 LLM 增强评论。该集只用于评论格式、定位和多语言覆盖实验，不直接写入 few-shot，也不进入 Platform 召回分母。
