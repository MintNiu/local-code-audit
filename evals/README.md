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
SQL 迁移预检还会识别删除版本化 `sql/migration`/`db/migration` 文件导致已有数据库升级路径中断，以及同一文件内 DROP/CREATE 触发器名称仅差前后缀的重放风险；前者要求被删文件明确标注服务已有数据库，后者要求同文件且至少一侧为新增行，均要求在同一数据库连续执行/升级验证。模型对确定性迁移候选的宽范围复述会按文件和行号去重，但同段独立 SQL、权限或并发根因仍会保留。
当前还会对新增代码中把 token/secret 直接拼进 URL 查询参数或路径的明确模式、通过 `TOKEN_HEADER`（含先赋给局部变量或大写类常量别名）从 URL 查询参数读取令牌的模式、新增配置中的硬编码凭据（含指向非本机 endpoint 的高置信配置项）、同一 hunk 中移除 `fileStorageService.delete(...)` 但仍删除 `fileRepository` 元数据的对象生命周期回归，以及同一 SQL 文件中唯一 `CREATE DATABASE/SCHEMA` 与唯一 `USE` 名称不一致的 schema 迁移回归做确定性预检；凭据值不会写入 finding。别名按当前源码的方法范围保存：同一文件跨 hunk 仍能召回，不同方法复用同名局部变量不会串线；支持多级直接别名和跨行赋值，多行 `getParameter(...)`、多行方法签名、下一行左花括号、Java text block 以及字符串/注释中的花括号不会破坏边界识别。预检证据会路由到同一文件的每个分片，避免大文件后续分片以不同措辞重复报告同一问题；最终聚合按文件/行号/高置信风险族做语义去重并保留严重度最高的条目，不只依赖字节相等。若模型段同时含有 URL/除法重复和租户、SSRF、并发等独立根因，会保留整段，不会为了去重隐藏其他问题。
对于同一提交中可直接证明的 Java `Integer` 除法空值拆箱和分母为零模式，也会执行窄范围确定性预检；普通 `int` 运算和带可见保护的代码不在该规则内。这样 `java-divide` 与 `java-token-url` 不再依赖模型某次采样是否恰好命中，模型仍负责发现其它上下文相关问题。
除法签名恢复按源码方法的花括号范围前向解析，不会从前一个方法借用 `Integer` 参数；复杂分母（例如三元表达式、成员访问和调用）不再把第一个标识符强行当作分母，交给模型结合上下文判断。简单标识符后继续出现 `+`、比较或调用表达式外层运算时，仍保留对实际分母的检测。
切换 profile 或模型后，建议使用新的 `--out-dir` 和 `--labels-dir`；不要把旧 profile 的人工标签直接套到新结果上。
如果评测的是删除或修改公共契约的提交，可重复传入 `--context <file>`，把下游仓库的调用方、POM 或测试作为只读证据；这些路径会记录在私有 `.meta.tsv` 中。未提供下游 context 时，结果只能按单仓库范围解释。

需要验证真实历史结果的重复稳定性时，使用 `./evals/run-history-repeat.sh --runs 3`。`--runs` 最少必须为 2；单轮不能证明稳定性，脚本会在创建输出目录或调用模型前拒绝。它为每一轮创建独立子目录，并逐提交比较完整 `.txt` 输出及模型/SYSTEM/脚本哈希、参数和退出状态；任一结果内容或运行配置漂移都会以非零状态失败。仅耗时和结果文件绝对路径不参与比较。

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

完成人工标注后，建议把每个提交去重为一行，并明确填写 `gold_p0_p1`（人工确认的 P0/P1 根因数）和 `p0_p1_found`（模型实际命中的 P0/P1 根因数）。可复制 [scorecard.template.tsv](scorecard.template.tsv) 开始填写；阶段一评测还必须填写 `split`、`feature_cluster`、`location_accurate` 和 `repeat_stable`。使用以下命令汇总，脚本会校验必需列（允许保留额外元数据列）、重复提交、非法数字、`p0_p1_found` 超过人工真值或未完成的输出：

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

如果要生成可提交阶段一门禁的评分卡，显式加上 `--stage1`：

```bash
./evals/build-scorecard.sh --stage1 \
  --labels-dir ~/.local/share/local-review/evals/platform-api-labels \
  --results-dir ~/.local/share/local-review/evals/platform-api-results \
  --out ~/.local/share/local-review/evals/platform-api-stage1-scorecard.tsv
```

`--stage1` 不会根据提交日期、主题、候选数量或运行是否成功猜测评测元数据；每个 complete 标签必须由人工填写 `# split`、`# feature_cluster`、`# location_accurate` 和 `# repeat_stable`，并且会校验字段格式及 `location_accurate <= p0_p1_found`。缺少或不可信的字段会 fail-closed。默认模式保持基础评分卡兼容，不附加这些阶段一列。

构建器只输出 `review_status=complete` 且运行成功的提交；它会校验标签中的 `# source_result_sha256` 与所选结果文件内容完全一致，要求每个标签文件内的 `finding_id` 唯一，并逐条校验 confirmed/false-positive 的文件和行号与结果候选重叠，允许安全搬迁同一结果，拒绝把旧 profile/旧运行的标签套到不同结果上。`missed` 是人工记录的 false negative，必须使用 P0/P1、真实路径、正数行号和证据备注，并且不能与所选结果中的任何候选范围重叠；否则标签与结果矛盾，构建器会 fail-closed。`uncertain` 不计入指标。缺少结果、元数据或字段不完整会 fail-closed；失败时不会留下半成品输出。输出仍应保存在私有目录，不要提交业务源码、模型响应或凭据。

对于跨事务/行锁风险，运行器会把受限的源码上下文送入 prompt，并额外执行一个窄范围的确定性反向锁序预检。预检只报告“候选”：它要求两个带 `@Transactional` 的源码段直接调用相同 `*ForUpdate` 接收者且顺序相反，并且至少一侧属于变更文件、且变更行本身触及事务/锁标记；它不证明相同数据库资源、调用可达性或真实死锁。候选在模型结果后合并，避免 prompt 重复；Prompt 证据会展示 `@Lock(PESSIMISTIC_WRITE)` 等声明式锁标记，但确定性配对暂不覆盖声明式锁、同文件 helper 或跨类 helper。锁文本索引和反向锁序扫描都有总超时；扫描超时或出错会让整次审查 fail-closed，不会把不完整的 prompt 证据当作 clean。请用人工调用链审计和真实数据库并发测试确认，不要把候选直接当作最终真值。

对象存储上传取消也有窄范围确定性预检：只有源码同时展示未过期预签名票据、取消先删除同一 `objectKey` 后标记终态、活动态过期清理，以及没有撤销/失效证据时，才补充一个 P1 重放/孤儿对象候选；普通上传、普通删除或存在撤销机制不会触发。该候选仍需人工确认票据版本化、调用可达性和真实对象存储行为。

阶段一门禁用于阻止“样本不足却宣称高可用” ：

```bash
./evals/stage1-gate.sh \
  --scorecard ~/.local/share/local-review/evals/stage1-scorecard.tsv
```

输入必须额外包含 `split`、`feature_cluster`、`location_accurate`、`output_complete` 和 `repeat_stable` 列。默认要求至少 20 个提交、至少 20 个 holdout P0/P1 根因、holdout 召回率和定位准确率不低于 90%、误报率不高于 10%，并拒绝不完整运行、重复提交和跨 split 功能簇泄漏。当前公开仓库的回归夹具会验证通过与失败路径；真实 scorecard 仍必须保存在私有目录并先完成人工标注。

1. 固定至少 20 个真实历史提交作为评测集，并按提交切分训练示例和留出评测集。
   不要随机打散相邻提交；优先按功能簇（例如同一接口迁移、同一安全修复链）整体分配到 train/dev/holdout，避免相邻提交泄漏。
2. P0/P1 真实问题召回率目标不低于 90%；如果样本不足，记录实际样本数，不得用主观印象替代指标。
3. 误报必须单独统计；每条输出都能定位到文件、行号和代码证据。
4. 审查输出不能静默截断。API 错误、空响应或 `done_reason=length` 必须以非零状态退出并明确提示。
5. 同一提交重复审查时，结果应基本稳定；固定 seed 只用于降低波动，不能代替人工复核。
6. 每次评测记录模型名、temperature、seed、num_ctx、提交、耗时和人工结论。个人高性能 `local-review-local` 默认请求 `num_ctx=32768`，通用 core `local-review` 保持 `16384`；大提交优先使用个人入口，若显式降低上下文，预算门禁仍会 fail-closed。

### 大差异分片

当 diff 超过 `OLLAMA_REVIEW_MAX_DIFF_BYTES` 时，运行器会按 `diff --git` 文件边界、再按 unified diff hunk 边界依次调用模型。分片不会使用向量检索或 Embedding，因此这不是 RAG；它只是为了降低单次输出截断和上下文超时的概率。每个分片失败都会使整次审查失败，已完成分片只保留为诊断材料，不能计入完整性通过。

预算按字节计算；无法继续拆分的单个 hunk 和 `diff --cc`/combined diff 必须显式失败。输出门禁还要求每个空行分隔的问题段首行带严重级别和真实的文件路径/行号，泛化的“文件路径”文字不能通过；如果目标文件或显式 `--context` 文件存在，还会按当前内容校验行号/行号范围，超出范围的模型结果会被拒绝。已删除文件因当前内容不存在而跳过该范围校验；删除类问题可以只给出真实删除路径，不强行虚构当前行号，只有在 basename 唯一时才接受省略目录的路径，但仍保留差异和构建预检证据。

该预算只针对 Git diff 本身，不代表完整请求一定能放入 `num_ctx`；项目规则、显式上下文和系统提示词仍需计入容量。

未跟踪文件收集也有 fail-closed 边界：对 Git 报告的路径只接受普通文件或符号链接（符号链接只审查链接自身的 diff，不跟随目标），普通文件默认单文件上限为
`OLLAMA_REVIEW_MAX_UNTRACKED_FILE_BYTES=10485760`，差异读取默认超时为
`OLLAMA_REVIEW_UNTRACKED_DIFF_TIMEOUT_SECONDS=30`；Git 已报告的 FIFO、设备、过大文件、读取错误或超时不会被静默当成无变更。Git 忽略或不报告的路径不在审查范围内。
`run-history.sh` 会冻结 manifest 并记录 SHA-256；没有匹配的 pending-human-label 行、单提交失败或 malformed reviewer 输出都会以非零状态结束。标签模板生成还会核对结果 metadata 中的
manifest SHA-256、commit 和 parent，防止清单漂移后把旧结果绑定到新标签；`run-history-repeat.sh` 只有在每轮 metadata 均为
`status=completed`、`exit_code=0`、`output_complete=true` 且结果/metadata 一一对应时，才允许报告 `repeat_stable`。

运行器的确定性构建和安全预检可用无模型回归测试验证：

```bash
./evals/test-preflight.sh
```

该入口同时运行独立的配置报告保留测试 `bash evals/test-config-findings.sh`。
证据相关输出过滤另有独立回归 `bash evals/test-filter-evidence.sh`，覆盖同一 Mapper 中不同查询、已删除租户条件、别名错误以及真实 token 日志写入，防止降噪规则把独立安全问题静默成 clean。
它使用独立临时仓库和固定假响应，验证真实端口反例不会因为“可能”一词被隐藏，
以及未知路径、越界行号和缺字段仍会显式失败。它检验输出链路，不证明模型能发现这些问题。
夹具必须在断言时仍有待审查变更，不能复用被前序测试提交过的配置文件来证明过滤安全。

该测试覆盖当前差异新增但仓库缺失的类型、显式 `--context` 仍引用当前提交删除类型的跨仓库候选、URL 查询令牌、Java 包装类型除法、跨 hunk SSRF、URL builder、URL 白名单前缀绕过、xxl-job 权限迁移遗漏、路径 API 别名和配置硬编码凭据；它使用假的 Ollama/Curl，验证预检证据注入、确定性结果合并、问题段字段完整性和输出门禁，不消耗模型推理。

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

路径门禁只允许变更文件和显式 `--context` 文件作为报告目标；`AGENTS.md`、README 只作为证据输入，不会被模型当成待审查文件。同名 basename 只有唯一时才算匹配，避免把泛化的“文件路径”当成证据。完整源码矛盾过滤还会拒绝加载当前变更路径中的符号链接组件，防止通过仓库内链接读取仓库外目标；符号链接本身仍可作为报告位置接受路径和差异定位校验。

路径安全补充：Git 变更路径使用 NUL 安全解析；含换行/回车、绝对路径或父目录组件的路径会直接 fail-closed，不进入后续源码索引。发现任一变更路径含符号链接时，依赖完整源码快照的确定性预检会跳过该快照读取，但差异本身仍继续审查。仓库内 `AGENTS.md`、README 或 `--context` 符号链接不会跟随读取目标，避免把仓库外内容注入 prompt 或源码过滤器。

## 样本原则

样本应保存提交或差异标识、必要上下文、人工确认的问题列表、严重级别、文件和行号、证据、影响、修复建议和验证方式。必须包含“无问题”和“容易误报但实际不是问题”的样本。

不要把未经人工确认的模型输出直接当作标准答案，也不要把整个仓库原样作为训练数据。

2026-09-27 稳定性记录：针对真实迁移/事务/字典误报补充了窄范围 SYSTEM 边界和 `java-generated-column-safe` clean 夹具。运行器还会移除没有具体风险证据的“标准库无需额外依赖”信息，避免非问题信息造成重复审查哈希漂移；带有缺少、冲突、编译失败或依赖版本证据的兼容性问题不会被该规则过滤。2026-09-28 又补充了合法生成列与无契约租户列的信息级 DDL 门禁，并将证据过滤回归扩展到 11 个用例，覆盖声明式权限注解回归、预签名长尾恢复、分片合并和维护性信息降噪。当前 tuned 模型的受控五轮合成门禁为 7 类正例 5/5、6 类 clean 30/30、预签名 5/5，截断显式失败。

声明式权限注解回归：差异把 `@PreAuthorize`、`@RequiresPermissions` 或等价注解注释/删除时，运行器会按控制器文件生成一条确定性 P1，列出全部证据行；大差异中该段只在最终合并阶段注入，避免占满每个模型分片的固定上下文预算。模型对同一证据的重复段和纯“可读性/维护性”信息会被过滤，但租户、SQL、并发、凭据等独立根因仍保留。真实 `platform-erp-service:4451b5b` 11/11 分片完整结束，4 个控制器 P1 全部定位；两轮重复 398/441 秒，结果文本与运行签名稳定。该预检只增加证据覆盖，不代表阶段 1 已满足 20 个 holdout 根因和 90% 生产门槛。

历史评测清单完整性：`run-history.sh` 与 `prepare-history-labels.sh` 在创建输出目录前拒绝控制字符、未转义 TAB/列数漂移、非法 commit/parent 和路径遍历值；`test-history.sh` 已覆盖这些 fail-closed 分支。新增 ERP 幂等候选 `0e6006b` 的完整复核被人工判为未命中/误报对照，不计入召回；会话重放候选因 Ollama 并行争用导致分片超时，也不计入指标。

预签名长尾恢复：单个 Java 文件且唯一确定性 P1 是取消后重放预签名票据时，模型长度截断或传输失败可以安全回退到该确定性 finding；存在第二个预检根因或独立租户/权限/SQL/SSRF/凭据证据时继续 fail-closed。该条件已加入 11 个证据过滤回归用例，避免把不完整模型输出伪装成完整审查。

受控稳定性记录：`num_ctx=16384`、`num_predict=2048`、关闭重试的 `SYNTHETIC_REVIEW_RUNS=5 ./evals/run-synthetic.sh` 已通过，7 类正例各 5/5、clean 30/30、预签名 5/5，输出哈希稳定；个人高性能入口仍默认 32K，资源不足时只对上述单文件单预检形状恢复。

中文路径回归：Git diff 使用 `core.quotePath=false`，使包含中文文件名的分片头与 NUL 安全路径索引保持一致；`evals/test-sharding.sh` 包含无模型中文文件名分片夹具。真实 `platform-hr-service:a8bf560` 复核中 28 个分片均成功，避免因路径显示编码差异把完整审查误判为失败。

租户子查询误报回归：当变更的 `EXISTS`/子查询已经显式比较内外层 `tenant_id` 时，确定性过滤器会移除泛化的“缺少租户隔离”段落，但保留别名错误、权限、SQL 注入等独立问题。该边界未写入 SYSTEM，因为实测会让预签名票据夹具超过请求超时；当前 tuned SYSTEM 规则保持上一版，证据门和回归测试独立承担该降噪职责。
