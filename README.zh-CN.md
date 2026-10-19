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

配置问题不会仅因含有“可能／如果”等措辞而被删除，这些词也可能描述真实缺陷的影响。
结构合法的候选会保留供独立核实；通过输出校验不等于问题已经确认。
虚构路径、越界行号和缺失必填字段仍应使审查失败，不能被过滤成 clean。

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

前置条件是 Ollama 服务正在运行、本地已有选定模型、Python 3、Git、`jq`、`rg`（ripgrep）和 Perl。macOS 通常自带 `curl`、`awk`、`tr`、`sort` 和 `/usr/bin/perl`；可以用 `command -v python3 ollama jq git curl awk tr sort rg perl` 检查。使用 Homebrew 时，缺少工具可执行 `brew install jq ripgrep`。

## 使用

在任意 Git 仓库中运行：

```bash
local-review
local-review --repo /path/to/repo --base origin/main
local-review --context src/main/java/path/to/RelatedService.java
local-review --examples /path/to/private/examples.md
```

每次收到可解析的模型 final 正文，都会在校验或重试前，完整保存在本地私有的
`final-candidates.jsonl` 报告中，包括被排除、重复、未确认和不完整的候选。
每次审查会在 stderr 公告一次绝对路径；使用
`jq -r '.final_text' /path/to/final-candidates.jsonl` 可查看全部候选正文。
stdout 仍是原有门禁处理后的工作流结果，不等于完整原始候选清单。

报告默认保存在 `~/.local/share/local-review/reports`，可以用
`--report-dir /private/absolute/directory` 或 `LOCAL_REVIEW_REPORT_DIR`
指定另一个私有绝对目录（目录权限 `0700`，文件 `0600`；拒绝符号链接）。
创建、写入或刷盘失败时，会把完整清洗后的 final 回退到 stderr，不能静默丢失。
仅保留 final 正文，不保存 API 整包或非正文内部字段。继续使用已有凭据脱敏，
但不承诺识别所有秘密：报告是明文，可能包含源码片段，仅留本地、不自动删除，
请按私有数据管理，勿提交。保存候选不等于确认问题，也不会把截断或无效输出改成审查成功。

工作流门禁不是语义认证：即使退出码为 `0`，也不能证明根因、等级、修复建议正确，
或代码没有缺陷。独立核验仍然必要。

不再用源码关键词启发式删除模型段落。所有完整候选，包括信息和无依据建议，
都经过相同的必需字段、路径和行号校验；非法输出必须失败，不能被删空改成 clean。
只有模型原本的规范 clean 响应才能表示模型 clean。预检发现一个问题，不能让未完成的
模型审查变成成功；已知证据仍完整保留在失败诊断中。

需要实证证据时，先用已有可信测试任务或经人工审阅的固定探针，再通过现成的
`--context /private/absolute/review-evidence.txt` 传入私有文本/JSON 观测。
记录匹配的源码/差异身份、准确命令、相关运行时与配置、输入、输出和失败，
确认仍对应被审查的版本；保留反证和完整私有日志，少量通过不能证明所有输入安全。
不要为了核验模型说法直接执行模型生成代码或不可信仓库代码。
命令只读取证据，不执行它，也不自动认证结论；无需新增模型、依赖或自动裁决阶段，
目前也没有证据证明这种输入方式带来普遍质量提升。

如果当前提交删除、重命名或修改了对外 API、DTO 或声明式客户端，审查主仓库不会自动读取其他仓库。请先从与目标提交匹配的下游 Git ref 提取消费者接口、配置、调用方或测试文件，再逐个用 `--context` 传入（该参数可重复），否则只能得到当前仓库范围内的结论。历史评测可使用 `scripts/extract-context-snapshot.sh` 生成私有快照：

```bash
local-review --repo /path/to/platform-api \
  --context /path/to/platform-file/src/main/java/.../InternalFileController.java \
  --context /path/to/platform-file/pom.xml
```

这是个人高性能审查中检查跨仓库兼容性的必要步骤；上下文文件只作为证据输入，不会被修改。

当下游服务上下文明确展示事件数据的 `tenantId`、`ignoreTenant`/`supplyWithIgnoreTenant`，而新增内部 claim/ack 客户端只带 `X-Gateway-Token` 时，运行器会额外执行严格的跨上下文租户预检；没有这些服务端证据时不会仅凭客户端签名报告租户问题。

个人高性能模式使用单独命令：

```bash
local-review-local
local-review-local --repo /path/to/repo --base origin/main
```

它保留证据、权限和安全检查，默认使用近期可重复验证的 16k/4096 个人高性能预算，并在连续审查时保留模型。当前继续固定 16K，已经否定的慢速 32K 路线不再重试；大型审查优先组织必要的完整证据并拆分任务。仍可用同一组 `OLLAMA_REVIEW_*` 环境变量临时覆盖。`local-review` 是保守基线，`local-review-local` 提供个人本地高性能默认值；两者都可使用本机私有 few-shot 数据。

实测同一个 clean 样例：保留模型 5 分钟时连续两次约 23 秒、4 秒；每次卸载时约 20 秒、21 秒。因此本地高性能版默认保留模型用于连续审查；更关注电量时可设置 `OLLAMA_REVIEW_KEEP_ALIVE=0`。

可以通过环境变量做单次 A/B 测试：

```bash
OLLAMA_REVIEW_MODEL=devstral-small-2-review \
OLLAMA_REVIEW_NUM_CTX=16384 \
OLLAMA_REVIEW_NUM_PREDICT=4096 \
local-review --repo /path/to/repo
```

默认上下文为 16k。大型变更优先按文件或模块分片；32k 只是显式实验覆盖，不作为解决耗时或漏报的推荐方法。默认输出上限为 4096 tokens。如果输出达到上限，命令会明确报告截断并失败，不会把半截审计结果当作成功。

对显式选择的已安装实验模型，可用 `OLLAMA_REVIEW_THINK` 请求 `false`、`true`、`low`、`medium`、`high` 或 `xhigh`。本机同一 Ollama 的 `/api/show` 必须公布严格匹配的 JSON 值及类型；空值、无效、不支持或元数据无法验证时，在推理前明确失败。未设置变量时不新增 `think` 字段或能力探测；布尔 `false` 不等于省略，也不等于字符串 `"false"`。请求 trace 留存实际发送设置，但此选项不会下载模型、切换默认值或放宽格式与质量门禁。

当收集到的 diff 超过 `OLLAMA_REVIEW_MAX_DIFF_BYTES`（通用命令默认 `3000`，个人高性能 profile 默认 `6000`）时，`local-review` 会按文件边界、再按 unified diff hunk 边界自动进行确定性分片。每个分片独立审查，最后完整拼接模型段落，跨分片重复段落也保留。分片默认使用 `OLLAMA_REVIEW_CHUNK_TIMEOUT_SECONDS=180`；通用命令输出预算为 `2048`，个人高性能 profile 为 `4096`。任何分片超时、截断或输出格式不合格都会使整次审查失败，已完成分片只作为诊断输出。全部分片完成后，统一合并一次整次审查的确定性预检，包括定位在未变更引用文件的证据；提示词路由不能决定最终候选是否存在，也不能扩大模型分片的允许路径。

每个分片还会收到本次提交全部变更文件的路径清单。清单只作为范围元数据，不附加其他文件源码；它帮助模型区分“实现在另一个分片”与“确实缺失”，但当前分片未展示的内容仍不能作为问题证据。

Java 缺失 import 的确定性预检仅对常规 `src/main/java`、`src/test/java`
路径生效，支持模块前缀。自定义或旧式源码目录不能单凭路径确定构建 classpath，
因此不据此自动报告编译阻断；相应 diff 仍交给模型审查。
这条预检不是编译器，也不解析任意构建配置。

Java 审查可以在私有 A/B 评测中选择性启用有界的方法上下文 sidecar：

```bash
OLLAMA_REVIEW_JAVA_METHOD_SIDECAR=true \
local-review --repo /path/to/repo
```

它默认关闭。启用后只读取当前工作树中、且当前差异存在新增行的 Java 方法，把它们作为“仅供理解”的证据上下文发送；不会跟随符号链接，也不会把源码内容写入 trace。单方法或总字节预算容纳不下时会省略整个方法；加入 sidecar 后若实际输入预算不足，运行器会回退到原始的有界提示词。只有在私有 A/B 对照确认没有误报和延迟回归后才应长期启用，并且 sidecar 结果在独立验证前不能计入模型原生召回率。可调参数为 `OLLAMA_REVIEW_JAVA_METHOD_SIDECAR_MAX_BYTES`、`OLLAMA_REVIEW_JAVA_METHOD_SIDECAR_MAX_METHOD_BYTES` 和 `OLLAMA_REVIEW_JAVA_METHOD_SIDECAR_MAX_METHODS`。

如果单个 hunk 仍然超过字节预算，或检测到 Git combined diff（`diff --cc` / `diff --combined`），命令会明确拒绝，不会把超预算内容作为不安全的完整提示词发送给模型。

字节预算只约束收集到的 Git diff；项目规则、显式上下文文件、README 和系统提示词还会额外占用上下文。它们较大时，应选择必要的完整证据并进一步拆分审查，不静默裁掉证据或放宽输入保护。

Ollama 请求遇到瞬时传输失败时，默认在整次审查总超时内最多重试 2 次；个人高性能入口默认给多分片串行审查预留 2400 秒，也可显式设置 `OLLAMA_REVIEW_TOTAL_TIMEOUT_SECONDS` 让它更快失败。可用 `OLLAMA_REVIEW_RETRY_ATTEMPTS=0` 关闭重试，或按本机稳定性调整。脚本还会按保守字节估算检查系统规则、上下文和 diff 的输入预算；可用 `OLLAMA_REVIEW_INPUT_RESERVE_TOKENS` 调整预留空间。

小差异先按完整初始提示词估算，能容纳时保留示例和预检上下文，仅在实际估算超预算时移除可选内容；确定性发现仍完整合并到最终结果。初始请求失败后会重新计算分片预算，不沿用初始请求的预算结论。评测元数据通过 `budget_mode=initial|shard` 区分两种估算方式。

仅在诊断/A-B 评测时，可设置 `OLLAMA_REVIEW_SPECIALIST_CHANNEL=auth-tenant`、`concurrency-state` 或 `external-io`。审查器会在基础审查后串行追加一次窄范围专项复核，并合并两次完整结果；默认值为空，因此日常审查仍只发一个请求。专项超时、截断或格式无效时整次 fail-closed；在独立验证前，专项合并结果不计入模型原生严格召回率。

输出门禁验证结构，不裁定问题真实性：每个问题段都必须包含严重级别、能匹配变更文件或显式上下文文件的文件/行号，以及明确的“影响：”“修复建议：”“验证方式：”字段；只有在当前审查集合中唯一时才接受单独的文件名。

已删除通用的整文件 `token`/`currentToken` 空值抑制：删除行、另一个方法、注释/字符串或错误操作之后的保护文本，不能推翻具体的解引用问题。该类候选继续进入正常校验，不再因这一文本匹配被改写为 clean。`bash evals/test-token-guard-filtering.sh` 覆盖五种错误 clean 和三个协议控制，旧代码 3/8、修复后 8/8，八份请求逐字相同且使用固定替身响应。这证明工作流保留候选，不证明模型原生召回、整体误报改善或候选一定真实。

证据、影响、修复或验证字段里的日志措辞不再导致整条候选被删除，原有结构和位置校验仍然执行。泛化的“建议补日志”因此也可能重新出现，需要独立复核，不能当作已确认缺陷。`bash evals/test-logging-word-retention.sh` 包含五份源码支持的候选变体、一份明确非金标的噪声可见性控制和四个协议控制，旧过滤 2/10、删除后 10/10，十份请求与固定响应逐字相同；这是候选保留和协议检查，不是独立根因或模型质量成绩。

DTO 三元式或 `TOKEN_HEADER` 赋值不再作为整段候选的删除依据：三元式返回值仍可能被随后解引用，常量也可能被定义为违反契约的值。这些候选继续经过原有必需字段和行号检查。`bash evals/test-guard-scope-retention.sh` 以两个普通功能性 P2 根因覆盖单项／混合保留、非法协议、clean 和截断；固定十场景从 3/10 到 10/10，只证明流程留存，不是模型召回提高或其他过滤全部可靠。

如果问题带有可解析的文件行号，脚本还会对照当前文件或显式 context 的实际行数；越界定位会使本次审查失败，避免把不存在的行号当成可信证据。删除文件不按当前工作树强行校验。

默认采样参数为 `top_k=40`、`top_p=0.9`；除非在评测记录中明确记录覆盖值，否则不要随意修改。

默认温度为 `0`，用于提高本地审查的可重复性；它不能替代人工复核。

保守基线命令 `local-review` 默认 `keep_alive=0`，每次审查后释放模型；个人高性能命令 `local-review-local` 默认保留 5 分钟。更关注电量时可设置 `OLLAMA_REVIEW_KEEP_ALIVE=0`。
更新规则或参数后，可运行 `./scripts/verify-runtime.sh` 只读检查 Ollama 中的 tuned 模型是否与当前 `config/Modelfile` 一致；失败时按脚本提示手动重建模型。

## 评测

建立至少 20 个经过人工确认的历史提交作为私有评测集，并按照 [evals/README.md](evals/README.md) 记录召回率、误报、行号准确率、完整性和耗时。

修改提示词或运行参数前，先运行公开的合成回归门槛：

```bash
./evals/run-synthetic.sh
```

需要单独验证 Git 路径迁移语义时运行 `bash evals/test-rename-evidence.sh`；它只对内容完全相同的 `R100` 重命名提供防误报证据，改写型重命名仍按普通差异审查。涉及 Ollama 的回归请串行执行，本机并发锁会按设计拒绝同时启动的第二个审查。

仓库还会在 GitHub Actions 的 macOS 环境中，对每次 push 和 Pull Request 自动运行不依赖 Ollama 的回归套件，覆盖预检、分片、聚合、标签迁移和运行态校验；不会上传模型输出或私有审计数据。这样解析器规则变更不会等到本地再次使用时才暴露回归。

`scripts/run-regression.py` 为每个套件分配独立的临时私有报告目录，覆盖继承的
`LOCAL_REVIEW_REPORT_DIR`，不让替身模型输出进入用户的持久报告。
夹具报告随套件临时目录清理；日常审查报告仍然保留。

合成门禁对 23 个正例、22 个 clean 开发夹具各运行五轮，另验收显式截断处理。clean 夹具拒绝问题段，正例检查已知风险族，但不能排除所有额外误报；13 个安全 clean 夹具使用 512 输出预算和 greedy 解码，预签名票据夹具也使用 greedy。结果仍包含确定性预检追加和结构校验，但不再包含语义过滤或仅靠预检的成功回退；因此全绿仍不代表模型原生召回达标或零误报。独立验收目标和当前状态见 [evals/goal.md](evals/goal.md)。

最新本地锁预检修复（2026-10-19）：可严格识别的 `finally → 同类私有释放叶 → 同一 final 标准锁` 不再被追加方法内漏释放候选。冻结替身工作流测试从 11/14 到 14/14，59 项结构／词法单元也通过；完整本地无模型回归 94/94（567.04 秒），前后 191 个运行时／测试／夹具文件校验值一致，shell 语法及运行器自测通过。未知情况继续原预检，不获得安全证书，模型段落始终保留。这些检查不认证原生模型质量，权重、SYSTEM、示例与 16K/4096 未变。详见[过程记录](docs/tuning-process.zh-CN.md)。

最新温度对照（2026-10-19）：按作者生成配置的温度值，在现有权重、完整日常输入与16K/4096下只比较0和0.15。一个普通P2开发根因的四格全部HTTP200/stop且身份匹配：0.15正确例规范clean，0基线承认功能等价却输出非问题信息并附clean；两种温度的缺陷例都漏报。候选不采用，不扫温度或重试；全部四份原文私有完整保留。单例输出更规范不认证召回、稳定性或一般误报率。详见[过程记录](docs/tuning-process.zh-CN.md)。

上一轮原生示例对照（2026-10-19）：保留日常完整 SYSTEM、同一正确 Java 实现、完整契约和 16K/4096，只将原规则式示例替换为四份完整输入／输出参考。两次调用均正常完成、身份匹配，但原示例版输出六条无依据 P1，候选版输出一条错误 P2 和一条无需修复的信息项；后者仍未通过正确实现门槛。剩余六次未运行、未评分，候选不采用，八个原始段落完整私有可见。段落减少不认证误报率、召回、稳定性或一般提速；未下载模型、改权重或默认。详见[过程记录](docs/tuning-process.zh-CN.md)。

上一轮工作流验证（2026-10-19）：已移除整段语义抑制层。所有候选，包括信息和无依据建议，都进入相同的必需字段及定位检查；非法输出不能被删成成功 clean，未完成的模型调用不能靠预检转为成功。全部分片完成后统一合并全局预检，不扩大模型许可路径；普通分片聚合保留重复模型段落。

固定响应保留测试从 4/15 到 15/15，八项预检／排序／完整性检查从 1/8 到 8/8；这些是协议场景，不是独立模型质量样本。最终冻结代码通过全部 92/92 项本地无模型回归（596.16 秒），包含两套新增测试；运行前后的运行时代码、测试和夹具校验值一致，shell 语法及运行器自测也通过。这里只认证工作流，不认证原生召回、误报率、级别或整体验收；权重、SYSTEM、示例和 16K/4096 默认未变，正式质量指标仍未核准。详见[过程记录](docs/tuning-process.zh-CN.md)。以下较早记录中的控制仅描述当时行为，不代表当前仍保留语义抑制。

原定五轮模型门禁在第 21 次调用停止：内部 header 的 clean 夹具被报为无依据的 P1。前四组各五次调用已完成，其余 204 次常规调用及显式截断未尝试，不评分。全部 21 份 final 均私有完整留存。该模型门禁仍判失败，不能由 92 项工程测试代替或豁免。

该公开工作流版本对应的 [GitHub 完整工程回归](https://github.com/MintNiu/local-code-audit/actions/runs/39241316611)也已成功。随后八格原生开发对照仅通过现成 `--context` 补充完整目标源码，原 SYSTEM、示例和 16K/4096 保留；它减少一条 Java 误报，却丢掉基线已指出的 Java 根因，Python 根因两边均未报告。八次均完整返回且身份／实际上下文匹配，但仅涉及两个普通 P2 根因，不是八个独立根因或正式 holdout。候选不采用，六份 clean 和两个原始候选段均完整私有留存。

另一次原生只读工具往返成功，但随后一个 Java 根因的四格开发对照未改善审计质量。两边同用现存通用 SYSTEM 和完整示例，不等价日常长 SYSTEM；工具版确实读到两份完整源码，却仍误报正确实现，缺陷例还定位到未修改文件并写错验证字节端序。四份原文完整保留，不给默认入口增加工具循环；协议可用不等于质量通过。

前一轮针对性工作流验证（2026-10-19）：保护范围保留测试从 3/10 到 10/10。两条宽泛抑制把三份具体候选响应（两个根因，其中一份混合响应）及四份非法响应误变成成功 clean；移除后分别完整保留、恢复字段／行号拒绝，规范 clean、严格纯缺上下文和截断控制不变。十组实际请求、源码、固定响应和归档逐字相同；原始 final 在修复前已有保存。完整本地无模型回归 90/90（592.18 秒）、shell 语法及运行器自测通过。这只证明流程修复，不代表模型原生质量、所有过滤可靠或整体验收。

前一轮针对性工作流验证（2026-10-19）：分片限定句保留测试从 5/12 到 12/12，十二份实际请求和固定响应逐字相同。有具体证据的问题，不再仅因同时说明“当前分片未展示调用方”而整段删除。旧版五份含具体问题的响应（仅两个源码根因，其中一份响应同时含两根因）及两份格式无效响应被错误改成成功 clean；修复后前者完整保留，后者由原有缺字段、行号检查拒绝，纯缺上下文、正常 clean 和截断控制仍有效。原始 final 在修复前就已归档，不是本次才补救留存。完整本地无模型回归 89/89（549.51 秒）、shell 语法及运行器自测均通过。这不代表模型原生质量、其他过滤全部可靠或整体验收；无依据建议仍可能可见。

前一轮无模型验证（2026-10-19）：日志措辞候选保留修复通过 10/10 针对性场景和完整 88/88 套件，耗时 529.03 秒；shell 语法检查与运行器自测也通过。这修正了已复现的工作流错误 clean，并恢复缺字段和越界定位的拒绝；泛化补日志噪声仍明确可见，不代表模型原生质量或整体验收通过。前一项 token 空值候选修复通过 8/8 针对性场景和 87/87 套件（525.67 秒），修正了五个错误 clean；更早的 Java 源码根边界修复通过 10/10 针对性场景和 86/86 套件（550.18 秒），修正了四个确定性误报。

最新真实源码核验（2026-10-19）：只读检查 26 个本地仓库的限定时间窗口，找到同一功能的三个提交，不当作三个独立评测组。源审保留一个带条件的静态 P2 和另一个依赖实际绑定行为的 P2 候选，均不增加正式 P0/P1 金标或核准 holdout。人工标注本身不是训练或提示词调优，但历史曝光未知不能等同未见。完整关联证据包 18,481 字节加原 SYSTEM 24,118 字节，按现行方法估算 14,201 个输入 token，超过可用 11,264，因此在 HTTP 前拒绝，没有裁源码或扩大上下文。本次独立诊断未附可选示例，不是完整日常入口 A/B 或去示例效果试验。这不是实际分词／渲染证明，也不是模型漏报；源码、差异与裁定只留本机，默认和权重不变。

最新固定开发对照（2026-10-19）：两个已核验的条件性 Java P2 根因及私有修复控制，配对现有长短 SYSTEM，共八格，权重和 16K/4096 不变。五次新生成均 HTTP 200/stop、身份与 resident 16K 匹配；一格逐字复用历史结果，两格长规则容量拒绝、未推理或语义评分。短规则能容纳较大的完整材料，却仍漏掉两个指定根因；输出共 25 个原始候选段落（含重复），主角色及独立 AI 辅助源审未确认其中有成立的可修复问题，其中一条建议会恢复已移除的长度缺陷。长规则的校验修复控制未报额外候选。全部原文私有可见，不采用短规则；已曝光根因和派生控制不认证正式召回、误报率、稳定性、一般速度或整体验收，详见[调优过程](docs/tuning-process.zh-CN.md)。

前一轮原生诊断（2026-10-19）：另一个限定范围的真实 Java 校验候选保留原 SYSTEM、现有模型及 16K/4096，5,382 字节源码包估算 9,834 个输入 token，不附示例、不冒称日常入口等价。首次尝试仅访问元数据，私有客户端误判存储 SYSTEM 的边界换行，在生成前停止；保留原失败，披露前瞻修订，只修精确边界比较，6 项离线比较控制通过并重新批准，请求字节完全不变。唯一一次生成在 97.49 秒 HTTP 200/stop、1,084 输出 token，身份及 resident 16K 匹配。它输出四条 P1 和一条信息项，源审未找到成立的可修复问题：忽略可见校验，并凭空要求额外元数据、错误码细分和日志；也未指出限定单元契约下的空元素路径。完整原文不经删改私有留存。单个已知候选、无 clean 对照和重复，不认证召回、误报率、稳定性、实际 HTTP 行为或整体验收；没有采用新模型、规则、默认或示例。

前一轮原生诊断（2026-10-19）：单段证据门槛 A/B 保留现有模型、完整材料和 16K/4096，仅改变最终证据充分性的措辞，其余 SYSTEM 字节和请求字段不变，不改输出协议。同一正确 Java 源码上，A 在 96.151 秒正常结束，却把“复制不可变列表会抛异常”的同一虚假 P1 重复三次；B 在 34.495 秒正常结束，却误称共享不可变 Integer 引用会让调用者的列表元素替换影响独立副本。两角色核对源码及本机 JDK 后一致否定该机制。按预登记正确实现门槛，剩余六项未尝试、未评分，候选不采用。全部收到的 final 私有保留，不过滤；不能据两次调用认证召回、重复稳定性、一般提速或质量改善。模型、权重和默认配置不变，详见[调优过程](docs/tuning-process.zh-CN.md)。

前一轮原生诊断（2026-10-19）：新的 JSON 结果协议组合候选保留完整材料与现有模型、16K/4096。四份开发输入均通过保守字节估算，完整额外 API schema 成本也计入，最小余量仅 9 个估算 token。第一份正确 Java 实现在 47.114 秒正常结束，JSON 合规，却误报 P1 导入错误，建议的替换语句与原句完全相同；该确切源码此前已编译通过。正确实现门槛失败，余下三项未运行、未评分，候选不采用。全部候选私有保留，不过滤；不能认定召回、稳定性、一般提速或质量因果收益，详见[调优过程](docs/tuning-process.zh-CN.md)。

前一轮原生诊断（2026-10-19）：完整材料的来源分帧 A/B 已准备，但第一份原格式 Java 正确实现请求在 332.301 秒后达到 4096 输出 token 上限而截断。它误报导入语法和缺少 JDK 依赖，后者同段重复 29 次；实际目标源码已由现有 JDK 编译通过。按预登记规则关闭其余七项，没有发送任何 typed 请求或缺陷控制。全部接收到的 final 原文私有保留，未过滤；分帧收益、召回和稳定性均未测量，默认配置和权重不变，详见[调优过程](docs/tuning-process.zh-CN.md)。

前一轮原生开发检查（2026-10-19）：候选合并重复的输出指令，节省 585 字节 SYSTEM，其余规则、示例、完整源码和契约保持不变。四份冻结的 Java/Python 请求均完整返回，模型身份和实际 16K 运行态匹配。两个正确实现均为 clean，但两个缺陷实现也被判 clean，分别漏掉构造器数组引用泄漏和同前缀兄弟目录越界。候选未通过四例门槛，不采用；这些已曝光的功能样例不是正式 P0/P1 holdout 成绩，也没有同输入的原指令推理基线可证明质量或速度的因果变化。默认配置和权重不变，详见[调优过程](docs/tuning-process.zh-CN.md)。

候选留存改动已通过当时全部 84/84 项本地无模型回归（545.66 秒）；随后 synthetic 的 stdout/stderr 分流改动通过 4/4 项针对性回归（17.63 秒），包含新增九场景无模型测试、history、finding signature 和 runner 隔离。当时 CI 自动发现完整 85 个套件；这些是工程检查，不是模型质量验收。synthetic 只对 stdout 评分，完整 stderr 独立保留并展示；即使未设置 `SYNTHETIC_KEEP_RESULTS=1`，失败结果也会自动保留。前置替身预检使用隔离临时报告目录，真实模型阶段仍保留日常私有候选报告。

此前验证（2026-10-16，`49293e3`）：在 `GITHUB_ACTIONS=true` 下，本地完整无模型工程回归通过 83/83 个套件，耗时 534.18 秒，包含 sidecar 回退、提示预算、缺依赖诊断、原生 canary 采集器及 27 个 thinking 参数场景。阶段一门禁补齐命中/候选计数约束和大小写重复提交检查，正向余量测试保留合法的未分类候选。[同一提交的远端完整 CI](https://github.com/MintNiu/local-code-audit/actions/runs/38771203542) 也已通过。此前 `88ca8a6` 的远端失败没有复现，根因仍未知；新增 CI-only 安全失败摘要只改善诊断，不改变套件集合或验收阈值。thinking 选项加入前，[`ad9920a` 的远端 CI](https://github.com/MintNiu/local-code-audit/actions/runs/38757857910) 通过当时全部 82/82，耗时 670.79 秒。旧轮远端 80/82 保留在调优记录中；其中预检失败的首因尚未确认，不能归因于 locale 或某个生产过滤修复。真实模型五轮门禁**尚未通过**：前 60 次执行通过，随后在 `java-command-safe` 的资源所有权误报处停止。实验提示候选没有替换默认配置；失败记录及原始模型输出与包装器结果的区别见[调优过程](docs/tuning-process.zh-CN.md)。

独立评分表也尚待核准：复核发现根因记录数与提交数混用，以及身份、计数冲突。校验器现在拒绝这些冲突并分别报告记录数和提交数；人工标签与运行版本重新核准前，旧召回数字不作为当前验收依据。

比较不经过工作流预检和输出过滤的模型原生表现时，使用 Java/Python/JavaScript 成对开发 canary：

```bash
python3 scripts/run-native-canary.py \
  --model devstral-small-2-review-tuned:latest \
  --out-dir /private/path/new-native-canary-results
```

模型必须已安装，结果目录必须新建且位于公开仓库之外。工具只发送共享契约与完整源码差异，固定安装模型 digest，并保留每条原始回答；API 完整性、审查格式、人工语义判断分别记录，接口成功不等于质量通过。16 份原创程序只用于开发诊断，不是独立 holdout。可选 `--thinking` 必须使用本机模型公布的值；不会下载模型或修改默认配置。本机服务无法按 digest 只读解析已安装模型时会拒绝，不会退回可变 tag。人工核验流程见 [evals/README.md](evals/README.md)。

真实历史提交评测请按照 [evals/README.md](evals/README.md) 使用，并将清单、原始输出和人工标签保存在公开仓库之外。

可以用 `evals/prepare-history-labels.sh` 生成不会覆盖已有标签的私有 TSV 标注模板，再人工确认召回率和误报率。

多语言外部数据应以规范化 JSONL 和许可元数据保存在公开仓库之外。进入 few-shot 或微调候选前先执行：

```bash
python3 scripts/validate-external-dataset.py /path/to/private/review-dataset.jsonl
```

校验器会检查来源/许可信息、正例问题完整性、文件行号，以及 `train`、`dev`、`holdout` 之间的仓库/提交泄漏；它不会自动下载数据，也不会输出源码片段。

当前数据集优先级、许可证边界、切分规则，以及“模型原生发现”和“确定性预检补齐”的指标口径，见[外部数据集使用边界](docs/external-datasets-plan.zh-CN.md)。

对于 AACR-Bench 的审查表达 smoke 数据，下载的 JSON 仍放在仓库之外，只转换人工评论：

```bash
python3 scripts/prepare-aacr-review-dataset.py \
  /private/path/positive_samples.json /private/path/negative_samples.json \
  --limit-per-language 4 \
  --output /private/path/aacr-human-external-smoke.jsonl
python3 scripts/validate-external-dataset.py /private/path/aacr-human-external-smoke.jsonl
```

转换器默认排除 LLM 增强评论，也不会把 AACR 评论当作 Platform 的 P0/P1 金标。

对于 ReviewBench 的真实 PR 语境和跨语言 smoke，下载的 manifest 与引用仓库仍放在公开仓库之外，只规范化固定版本的元数据：

```bash
python3 scripts/prepare-reviewbench-candidates.py \
  /private/path/reviewbench/corpus/manifest.json \
  --revision 66df3f322d0d85ea133ea9fa777f5d1a8c933c4e \
  --output /private/path/reviewbench-candidates.jsonl
```

输出只包含仓库、PR、base/head、语言和变更规模；每条记录保持 `pending-human-label`，并写入 `golden_status=not-loaded`。不会复制源码、diff、评论或 golden finding。ReviewBench 当前只有 7 条 Java PR，不能作为 Java P0/P1 严格召回门禁，只用于真实 PR 语境、定位格式、多语言 smoke 和误报分析。对应无模型回归为 `bash evals/test-reviewbench-candidates.sh`。

对于 SWE-PRBench，先只规范化 `prs.jsonl` 的元数据，不复制 diff、上下文或评论正文：

```bash
python3 scripts/prepare-swe-prbench-candidates.py \
  /private/path/swe-prbench/dataset/prs.jsonl \
  --revision b87f5797aef3ed2c3153bb1304ea4d801d36ba6e \
  --language java \
  --output /private/path/swe-prbench-java-candidates.jsonl
```

每条记录保持 `pending-human-label` 和 `golden_status=not-loaded`；适配器保留原始 `task_id`，从中解析候选 PR 号，并保留难度、RVS 和人工评论数量等元数据。SWE-PRBench 的 Java 占比较低，Java 筛选只用于小规模 external-smoke，全语言样本也必须先核对引用仓库许可、文件/行号和严重度。对应无模型回归为 `bash evals/test-swe-prbench-candidates.sh`。

对于 VCC-Eval 的 Java 漏洞引入提交元数据，先生成不含源码和补丁的私有候选索引：

```bash
python3 scripts/prepare-vcc-eval-candidates.py \
  /private/path/tool_assisted_manual_dataset.json \
  --output /private/path/vcc-eval-candidates.jsonl
```

该转换器会按 canonical 仓库、CVE 和引入提交谱系去重，解析引入/修复行范围，并把记录标成 `pending-human-label`。VCC-Eval 数据仓库未声明可复用许可证；没有引入行号、没有父提交差异复核或没有触发证据的记录不能进入严格 gold，也不会自动写成 `positive`。对应回归为 `bash evals/test-vcc-eval-candidates.sh`。

准备好本地只读 Git 镜像后，可用私有 JSON map 验证父提交和新增行：

```bash
python3 scripts/verify-vcc-eval-candidates.py \
  /private/path/vcc-eval-candidates.jsonl \
  --repo-map /private/path/vcc-eval-repo-map.json \
  --output /private/path/vcc-eval-verified.jsonl
```

验证器不会 fetch、切换分支或应用补丁；缺少本地仓库、父提交、精确新增行或当前源码时保留失败状态和 `pending-human-label`。对应无模型回归为 `bash evals/test-vcc-eval-verifier.sh`。

对于本机已下载的 NIST Juliet Java 压缩包，可以生成私有 Java 审计 smoke 集（压缩包和生成的源码 JSONL 都不提交）：

```bash
python3 scripts/prepare-juliet-java.py \
  /private/path/juliet-java-v1.3.zip \
  /private/path/juliet-java-audit-smoke.jsonl \
  --limit-per-cwe 2
```

转换器从 manifest 读取 CWE 名称和缺陷行号，生成 bad/good 对照样本，并将结果保留在公开仓库之外。
运行器还包含窄范围 Java 外部安全预检：对同一方法内字面量密码流入 `DriverManager.getConnection`、非空字面量流入 `SecretKeySpec`、`readLine()` 数据直接进入 `sendRedirect`、弱加密算法、GET 表单提交密码、敏感 Cookie 未设置 `Secure`、外部计数直接控制无上限循环、取模计数器配合永真 `do/while`、`HttpSession.setMaxInactiveInterval(-1)`、文件资源只在成功路径关闭、`ReentrantLock`/`Lock` 的 `lock()` 或 `lockInterruptibly()` 获取后同一方法没有同一接收者释放，以及非 `volatile` 的 static 字段形成结构化嵌套双重检查初始化的证据先给出确定性 finding；固定字符串重定向、环境/密钥注入、现代 AES、POST 表单、已设置 `Secure` 的 Cookie、有明确上限的循环、带可达 `break` 的循环、有限会话超时、`finally`/try-with-resources 或显式释放锁的保护、`volatile` 双重检查字段、方法级同步和不完整/非嵌套空判断保持 clean。回归入口为 `evals/test-java-external-preflight.sh`，不会下载或提交外部源码。
DCL 预检要求带大括号的嵌套空判断与直接 `field = new Type(...)` 赋值；同行或下一行的大括号均按结构判断，不把相邻代码块拼成证据。工厂调用和暂不支持的语法仍交由模型审查，不直接产生本项确定性发现。快速解析回归为 `PYTHONDONTWRITEBYTECODE=1 python3 evals/test-java-dcl-scope.py`。外部安全集成套件还会在隔离目录实际安装并调用两个全局入口，覆盖相对符号链接和带空格路径。
Java 命令注入预检单独检查变更中的 `Runtime.getRuntime().exec`/`ProcessBuilder`：只有当同一方法内的 `command`/`cmd`/`args`/`script` 变量明确来自请求参数、请求头、查询串或路径参数时才报告；常量命令和仅来自环境配置的命令保持 clean。正负回归为 `bash evals/test-java-command-injection-preflight.sh`，并已接入 `test-preflight.sh`。
运行器还检查一个窄范围 SQL 交付升级边界：独立 delivery 脚本从旧版本的软删除父菜单列表移除 ID，但没有同时按应用、租户和角色范围恢复菜单及关系时，报告已有库升级风险；新库初始化脚本不能替代该升级证据。回归入口为 `evals/test-sql-menu-delivery-preflight.sh`。
XXL-JOB 空令牌预检要求当前 API 方法的注解与受支持的首匹配 `/api/**` 放行规则共同提供证据，才报告条件性候选；不把健康检查的 `permitAll`、在先的认证/拒绝规则或相邻方法的注解拼成授权证据，并识别受支持的顶层空令牌拒绝保护。有效环境/Nacos 配置、必填请求头和实际网络可达性仍需独立验证，空回退本身不等于确认部署漏洞；暂不支持的安全链结构不作为放行证明。合成正负对照入口为 `bash evals/test-xxl-job-empty-token-preflight.sh`，本检查不会过滤模型原生候选。
个人高性能入口还包含两条窄范围 ERP 履约并发预检：普通查询读取订单/明细后整行回写旧订单聚合，以及客户端明细顺序直接决定逐行更新或库存占用顺序。规则要求变更的 `SalesFulfillmentApplication` 与仓储实现同时提供代码证据，输出完整的 P1、影响、修复建议、验证方式和证据行；当可见锁/版本/CAS 保护或确定性明细排序时保持静默。这是确定性工程保护，不代表模型已经学会该模式。回归入口为 `evals/test-sales-fulfillment-preflight.sh`。
每个模板先填写 `# verdict`（`clean` 或 `findings`）和 `# review_status`（完成后填 `complete`），再逐条标记发现；未完成或 `uncertain` 的记录不应计入汇总指标。

`examples/` 目录只保存公开的格式说明。真实 few-shot 示例放在本机私有文件 `~/.local/share/local-review/examples.md`。
该私有文件会进入每次请求并计入 fail-closed 输入预算，应保持短小并定期去重；如果示例过大导致默认 16K 上下文无法容纳，应先精简示例，而不是允许静默截断或盲目提高上下文。

完整调优过程和期间遇到的问题记录在 [docs/tuning-process.zh-CN.md](docs/tuning-process.zh-CN.md)。

## 隐私与 GitHub

公开仓库是 [MintNiu/local-code-audit](https://github.com/MintNiu/local-code-audit)，许可证为 Apache License 2.0。不要提交业务源码、真实 diff、访问令牌、模型权重或私有 Review 数据。

## 提交说明规范

使用 `feat:`、`fix:`、`docs:`、`perf:` 等 Conventional Commits 类型。类型保留英文，类型后面的具体说明使用中文。
