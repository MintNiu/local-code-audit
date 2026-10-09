# 外部数据集使用边界

本文定义个人本地代码审计模型如何使用外部数据。外部数据的作用是补充语言覆盖、审查表达和安全根因回归，不替代 Platform 真实提交的独立 holdout，也不直接改变正式召回率。

## 推荐顺序

| 优先级 | 数据集 | 主要用途 | 当前处理方式 |
| --- | --- | --- | --- |
| 1 | [AACR-Bench](https://github.com/alibaba/aacr-bench) | 真实 PR 的评论、定位、类别和多语言审查表达 | 先抽取少量 Java/TS/SQL/配置样本做 external-smoke；原始 PR 和引用仓库许可证逐项记录 |
| 2 | [ReviewBench](https://github.com/review-bench/ReviewBench) | 真实 PR 语境、定位、排序和跨语言审查格式 | 只做 metadata-only external-smoke；仓库当前 219 条、Java 7 条，不能作为 Java P0/P1 严格召回金标 |
| 3 | [SWE-PRBench](https://huggingface.co/datasets/foundry-ai/swe-prbench) | 真实人工 PR 评论、难度类型和多语言 review 结构 | 只读取 `prs.jsonl` 做 metadata-only 候选；CC BY 4.0，Java 约 4%，先做 Java smoke，再做全语言定位/误报实验，不能作为 Java P0/P1 门禁 |
| 4 | [VCC-Eval](https://github.com/tuhh-softsec/VCC-Eval-A-Manually-Curated-Dataset-of-Vulnerability-Introducing-Commits-in-Java) | Java 漏洞引入提交、CVE/CWE 和精确引入行 | 先做 metadata-only 候选；数据仓库未声明可复用许可证，必须人工核对 intro parent、diff、触发证据和引用仓库许可后才能进入训练/holdout |
| 5 | [Vul4J](https://github.com/tuhh-softsec/Vul4J) | 真实 Java 漏洞、修复补丁和 PoV 测试 | 优先使用有 PoV 的子集；PoV 与仅静态告警样本分层统计，不混成一个金标 |
| 6 | [JavaVFC](https://zenodo.org/records/13731781) | 人工核验的 Java 修复提交 | 784 条人工集用于 train/dev 候选；extended 启发式集只能做 smoke，按仓库和提交谱系去重 |
| 7 | [NIST Juliet/SARD](https://www.nist.gov/publications/juliet-11-cc-and-java-test-suite) | CWE 正负对照、行号和输出协议回归 | 只抽取小型 Java 子集；合成样本不代表真实世界召回率 |

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

2026-10-08：新增 `scripts/prepare-reviewbench-candidates.py` 和 `evals/test-reviewbench-candidates.sh`。规范化器读取 ReviewBench 固定 revision 的 `corpus/manifest.json`，只输出仓库、PR、base/head、语言、变更规模、来源和许可证元数据；所有记录标记为 `pending-human-label`，明确 `golden_status=not-loaded`，不复制源码、diff、评论或 golden finding。实际 revision `66df3f3` 转换为 219 条候选，其中 Java 7 条；Java 数量不足以构成独立高危门禁，ReviewBench 仅用于真实 PR 语境、行号格式、跨语言 smoke 和误报分析。仓库虽为 MIT，引用项目和评审内容仍需逐项审查许可证。

2026-10-08：新增 `scripts/prepare-vul4j-candidates.py` 和 `evals/test-vul4j-candidates.sh`。规范化器读取 Vul4J CSV，只接受 GitHub `commit/<sha>` 修复链接，跳过 compare 链接和重复仓库/提交，保留 CVE/CWE、受影响模块、PoV 测试名和许可证来源，并将所有记录标记为 `pending-human-label`。Vul4J 的漏洞类别和修复提交不能直接证明 review 文件/行号，因此不自动生成 `positive`、不复制源码或补丁文本，也不写入 Platform 严格 holdout；人工确认后才可进入 external-smoke 或独立评测。该回归已接入完整 `test-preflight.sh`，用于防止数据标签泄漏。

同日对 `VUL4J-6`（CWE-835，Commons Compress）做了方向性 smoke：修复提交把 `int` 循环计数器改为 `long`，但它是漏洞修复本身，不是引入漏洞的 review diff；因此不能据此计算代码审计召回。个人高性能 profile 返回 clean，而保守 baseline 对同一修复 diff 给出无效的类型不匹配 P2，按 profile 不一致 fail-closed，不计入任何外部指标。针对该根因新增的 `ZipLong` 外部 long 值与变更 `int` 循环组合预检，只用合成正/负夹具验证，避免把修复补丁或模型误报写成金标。

2026-10-08：新增 `scripts/prepare-vcc-eval-candidates.py`，读取 VCC-Eval 的 100 条 Java 元数据，规范化引入/修复 SHA、CVE/CWE、仓库镜像和 `172`/`172-177;181` 行范围，按 canonical repo+CVE 谱系切分并全部标记 `pending-human-label`。没有引入行的记录保留为不可进入逐行评测的候选；工具不复制源码/补丁，也不把 introducing commit 自动标成 positive。GitHub/Apache 镜像去重、行范围解析、缺失/非法引入行和无源码输出均由 `evals/test-vcc-eval-candidates.sh` 覆盖，并接入完整 `test-preflight.sh`。

同日对 external-smoke 中 3 条有引入行的候选做了本地 Git 对象方向性核验：Armeria 的 1 行和 Undertow 的 2 行均落在引入提交相对 parent 的真实新增行，且引入提交是修复提交祖先；JSPWiki 的元数据路径在引入提交不存在，实际历史路径属于批量 trunk 同步，因此保留为路径/谱系不匹配，不自动修正、不计入 gold。该核验只证明 parent/diff 方向，尚未完成触发验证、许可证审核或人工严重度标注，3 条记录继续保持 `pending-human-label`。

同轮只提取 Armeria 和 Undertow 的标注文件构造窄差异模型 smoke，个人 tuned profile 均完整返回 clean；整仓库 archive 因 promisor blob 网络断开而 fail-closed，未把失败解释为 clean。两条 clean 结果只用于诊断当前模型对外部 Java 引入差异的原生可见性，不进入 Platform 严格 scorecard 或外部 gold。

同日修正 Juliet Java 预处理器的 manifest 关联：优先使用归一化的相对路径，只有 basename 全局唯一时才允许回退。这样可以避免不同 CWE 目录中的同名测试文件共享错误的缺陷行号或标签；Windows 风格路径也会先统一为 `/`。重复 basename、路径分隔符和精确行号均由回归夹具覆盖，数据质量错误不得进入训练或外部 smoke。

2026-10-09：在同一 Java 在线会话提交上做了普通 personal profile 与 `auth-tenant` 专项复核 A/B。两轮都完整结束，均为 5 个分片，最终结果哈希一致；专项复核耗时约 280 秒，普通审查约 102 秒，未增加模型原生问题。该结果只作为专项通道诊断证据，说明确定性租户预检已覆盖该样本的主要风险；`auth-tenant` 继续保持默认关闭，不把额外耗时当作能力提升，也不将该样本写入严格 scorecard。

同日新增 `scripts/prepare-swe-prbench-candidates.py` 和 `evals/test-swe-prbench-candidates.sh`。适配器只读取 SWE-PRBench 的 `prs.jsonl` 元数据，按 `task_id` 解析候选 PR 号，保留语言、难度、RVS 和评论数量，丢弃 diff、上下文和评论正文；每条记录均为 `pending-human-label`、`golden_status=not-loaded`。固定 revision 的数据卡约 350 条 PR、Java 约 4%，因此 Java-first 只作为小规模 external-smoke，不能把该集当作 Java 高危门禁；全语言样本也必须先完成引用仓库许可证和文件/行号人工核对。

同日按固定 revision 实际生成私有索引：`prs.jsonl` 共 350 条，Java 15 条；全语言分布为 Python 242、JavaScript 37、Go 35、TypeScript 21、Java 15。输入文件 SHA-256 为 `a58e1f713533f6bc260a93f6e234b85acd16a77f55a756893694b96495eb43cd`；输出索引不含 diff、评论、上下文或 findings 字段，未进入模型提示词或 Platform 严格 scorecard。

随后只在本机私有目录提取这 15 条 Java 的 `config_A` 上下文和人工标注结构做诊断：15/15 请求完整结束且均返回 clean；人工标注含 56 条发起评论，其中 53 条位于变更行、18 条明确标记为需要修改。对 3 条需要修改评论较多的样本追加 `config_C` 对照，仍为 3/3 clean。该结果说明当前模型对真实外部 review 反馈存在系统性漏报，增加上下文层级没有带来收益；它不代表 18 条评论都是 P0/P1，也不进入 Platform 严格 scorecard，后续应先做结构化根因路由和人工严重度核验。
