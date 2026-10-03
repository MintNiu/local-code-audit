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

需要验证真实历史结果的重复稳定性时，使用 `./evals/run-history-repeat.sh --runs 3`。`--runs` 最少必须为 2；单轮不能证明稳定性，脚本会在创建输出目录或调用模型前拒绝。它为每一轮创建独立子目录，并逐提交比较完整 finding signature（严重级别、文件/行号、风险族和 MyBatis 表达式）及模型/SYSTEM/脚本哈希、参数和退出状态；同一发现的自然语言措辞变化不会被误判为漏报，但新增/消失/移动发现仍以非零状态失败。完整 `.txt` 输出和 `result_sha256` 仍保留用于人工复核和标签绑定；仅耗时、诊断日志哈希和结果文件绝对路径不参与重复门禁。

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

冻结阶段一的私有 `independent-probe-results.tsv` 还应先通过独立表校验器。它把 `label_status` 作为唯一计分开关，防止把 `tuning-source` 或条件样本误算为 holdout，并同时检查 TSV 列数、提交号、重复根因、完整性和定位字段：

```bash
python3 ./scripts/validate-independent-scorecard.py \
  ~/.local/share/local-review/evals/stage1-freeze-20261003/independent-probe-results.tsv
```

该命令只读取文件并输出严格 gold、命中、召回率及各状态计数；可用 `bash evals/test-independent-scorecard-validator.sh` 做无模型回归。

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

Bafan 公开接口直接返回持久化实体的跨文件预检有独立正/负回归：

```bash
bash evals/test-bafan-public-entity-preflight.sh
```

无模型回归较多时，可用并行编排器缩短反馈回路；每个套件拥有独立的临时目录和 Ollama 锁路径，真实模型审查仍应串行执行：

```bash
python3 scripts/run-regression.py fast --jobs 2 \
  --test evals/test-preflight.sh \
  --test evals/test-system-role-permission-resource-scope-preflight.sh
python3 scripts/run-regression.py full --jobs 2
```

`fast` 只接受仓库 `evals/test-*.sh` 顶层套件，`full` 会排除编排器自身；失败套件会保留退出码并以非零状态结束。不要把 `run-synthetic.sh`、`run-history.sh` 或真实 Ollama 审查放入并行队列。

该入口同时运行独立的配置报告保留测试 `bash evals/test-config-findings.sh`。
证据相关输出过滤另有独立回归 `bash evals/test-filter-evidence.sh`，覆盖同一 Mapper 中不同查询、已删除租户条件、别名错误以及真实 token 日志写入，防止降噪规则把独立安全问题静默成 clean。`bash evals/test-concurrency-lock.sh` 验证同一台机器上的 Ollama 审查并发会 fail-closed，避免多个终端争用模型资源。
`bash evals/test-rename-evidence.sh` 验证 Git `R100` 精确重命名证据进入模型请求，内容不变的路径移动不会被误报为旧文件删除；它不豁免内容发生变化的改写型重命名。涉及 Ollama 的测试必须串行执行，否则并发锁会按设计拒绝后启动的请求。
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

2026-09-27 稳定性记录：针对真实迁移/事务/字典误报补充了窄范围 SYSTEM 边界和 `java-generated-column-safe` clean 夹具。运行器还会移除没有具体风险证据的“标准库无需额外依赖”信息，避免非问题信息造成重复审查哈希漂移；带有缺少、冲突、编译失败或依赖版本证据的兼容性问题不会被该规则过滤。2026-09-28 又补充了合法生成列与无契约租户列的信息级 DDL 门禁、MyBatis mapper 标量 `${...}` SQL 注入预检，并将证据过滤回归扩展到 16 个用例，覆盖声明式权限注解回归、预签名长尾恢复、分片合并、SQL 注入去重和维护性信息降噪。当前 tuned 模型的受控五轮合成门禁为 7 类正例 5/5、6 类 clean 30/30、预签名 5/5，截断显式失败。

声明式权限注解回归：差异把 `@PreAuthorize`、`@RequiresPermissions` 或等价注解注释/删除时，运行器会按控制器文件生成一条确定性 P1，列出全部证据行；大差异中该段只在最终合并阶段注入，避免占满每个模型分片的固定上下文预算。模型对同一证据的重复段和纯“可读性/维护性”信息会被过滤，但租户、SQL、并发、凭据等独立根因仍保留。真实 `platform-erp-service:4451b5b` 11/11 分片完整结束，4 个控制器 P1 全部定位；两轮重复 398/441 秒，结果文本与运行签名稳定。该预检只增加证据覆盖，不代表阶段 1 已满足 20 个 holdout 根因和 90% 生产门槛。

历史评测清单完整性：`run-history.sh` 与 `prepare-history-labels.sh` 在创建输出目录前拒绝控制字符、未转义 TAB/列数漂移、非法 commit/parent 和路径遍历值；`test-history.sh` 已覆盖这些 fail-closed 分支。ERP 幂等候选 `0e6006b` 的旧金标已纠偏：并发缺陷属于父版本，目标提交已通过 `FOR UPDATE`、`request_no` 唯一键和重复键处理补齐；当前两轮运行均为 clean 且结果稳定，因此不计入召回分母。存量数据库缺少迁移脚本是独立的升级风险，不能与该提交的业务并发金标混为一谈；会话重放候选因 Ollama 并行争用导致分片超时，也不计入指标。

预签名长尾恢复：单个 Java 文件且唯一确定性 P1 是取消后重放预签名票据时，模型长度截断或传输失败可以安全回退到该确定性 finding；存在第二个预检根因或独立租户/权限/SQL/SSRF/凭据证据时继续 fail-closed。该条件已加入证据过滤回归，当前共 16 个用例，避免把不完整模型输出伪装成完整审查。

受控稳定性记录：`SYNTHETIC_REVIEW_RUNS=5 ./evals/run-synthetic.sh` 已串行通过，11 类正例各 5/5、10 类 clean 对照共 50/50、预签名 5/5，输出哈希稳定；新增路径遍历、SSRF、命令注入和危险反序列化正/负夹具也纳入完整门禁，证据过滤回归保持 21 个用例，预检回归覆盖反序列化正负边界。个人高性能入口仍默认 32K，资源不足时只对单文件单预检形状恢复；传输超时、长度截断和不完整响应仍显式失败。

最近三组真实 clean holdout 也已记录：`platform-job:0885d7d8`（密码 CSRF 修复，2/2 分片、44 秒）、`platform-job:e5a84a1b`（bigint 兼容性修复，1/1 分片、34 秒）和 `platform-ai-service:ddc7b767`（SSE 错误内容协商修复，3/3 分片、27 秒）。三组均完整返回 clean，并经人工确认没有当前提交引入的 P0/P1；它们只用于跨功能簇精度与稳定性覆盖，不计入阶段一召回分母。

`platform-hr-service:6192b5e6` 的内部人员目录新增接口作为 clean holdout 完整通过（5/5 分片、82 秒）。全局 `GatewayAuthFilter`、租户上下文过滤器和 README 内部直连契约构成了当前证据范围，不能仅凭控制器缺少显式 `@PreAuthorize` 判定越权；该样本 `gold_p0_p1=0`，重复稳定性因资源争用未验证。

`platform-job:cb1bd548` 会话重放候选的串行重跑在第 31/59 分片触发行号越界（实际 `application.properties` 最后一行 74，模型报告到 76），因此结果保持失败和不完整。严格位置门禁在这里阻止了把确定性预检或前 30 个分片的半截结果伪装成完整审查。

真实 `platform-job:ae26cb0c` 暴露了模型对 RPC 出站 SSRF 的漏报：4/4 分片完整、130 秒却返回 clean；人工确认控制器把请求参数 `executorAddress` 直接传入 `NetComClientProxy`，后续提交已改为从数据库日志加载地址。运行器新增窄范围三元证据预检（请求映射 + `String executorAddress` + 新增 RPC sink），并将 `evals/test-filter-evidence.sh` 扩展为 14 个场景；重复模型段和同形状的长度截断只在无独立根因时恢复，只有这三项在同一变更 Java 控制器中同时可见时才输出 P1。

最新复跑已完成 5/5 分片、154 秒并准确输出单条 P1（`gold=1`、`found=1`、`predicted=1`、无误报、定位准确）；首片模型重复达到长度上限时由直接地址预检恢复，其他长度截断仍保持失败闭门。第二轮 186 秒结果文本与运行签名一致，正式 scorecard 标记 `repeat_stable=true`。

中文路径回归：Git diff 使用 `core.quotePath=false`，使包含中文文件名的分片头与 NUL 安全路径索引保持一致；`evals/test-sharding.sh` 包含无模型中文文件名分片夹具。真实 `platform-hr-service:a8bf560` 复核中 28 个分片均成功，避免因路径显示编码差异把完整审查误判为失败。

租户子查询误报回归：当变更的 `EXISTS`/子查询已经显式比较内外层 `tenant_id` 时，确定性过滤器会移除泛化的“缺少租户隔离”段落，但保留别名错误、权限、SQL 注入等独立问题。该边界未写入 SYSTEM，因为实测会让预签名票据夹具超过请求超时；当前 tuned SYSTEM 规则保持上一版，证据门和回归测试独立承担该降噪职责。
2026-09-29 扩展公开根因覆盖：新增 MyBatis 原始 `${...}` SQL 注入、默认 XML 解析 XXE、当前主体上下文下裸 `findById` 的 IDOR 正/负夹具；相应窄范围预检分别要求 SQL 标量赋值、HTTP XML 输入且缺少外部实体禁用、以及可见用户/租户上下文与对象级约束缺失。单轮验证确认模型对 XXE/IDOR 的漏报会被确定性 P1 补齐，SQL 模型重复会按具体表达式和文件/行去重；安全参数绑定、XML 硬化和 `findByTenantIdAndId` 负例保持 clean。最终五轮门禁为 14 类正例 70/70、13 类 clean 对照 65/65，哈希稳定、预签名 5/5、截断显式失败；仍不把合成结果外推为生产召回率。
2026-09-29 继续扩展公开根因覆盖：新增开放重定向、通配符 Origin + credentials 的 CORS 配置、MD5/SHA-1 弱密码哈希正/负夹具。模型对开放重定向漏报、CORS 只输出低等级泛化信息、弱哈希偶发格式不完整；新增窄范围确定性预检和严格单根因回退，安全 Origin 白名单、BCrypt/Argon2/PBKDF2 与固定内部跳转保持 clean。完整五轮门禁目标更新为 17 类正例、16 类 clean 对照；生产验收仍以独立人工 holdout 为准。
2026-09-29 再补充三组业务可靠性正/负夹具：授权异常 fail-open、Spring 单例共享布尔状态 check-then-act 竞态、事务内支付 gateway 先于本地订单保存的部分成功。模型对三类均有漏报或不稳定识别，加入窄范围确定性预检；异常拒绝、AtomicBoolean、pending + outbox 安全对照保持 clean。单轮全量门禁为 20 类正例、19 类 clean 对照，预签名和截断门通过；仍不把合成结果外推为生产召回率。

2026-09-30 扩展三组不同根因：MyBatis 标量 `${...}` 原始替换、URL `startsWith` 白名单前缀绕过、声明式权限注解删除/注释。个人 tuned profile 单轮全量门禁为 23 类正例、22 类 clean 对照；MyBatis 两个表达式分别保留，URL 前缀同文件/行号重复仅保留一条，独立根因不被去重；预签名回退和显式截断失败门均通过。新增 URL 去重回归 7/7、路径去重回归 3/3，无模型预检和其余 deterministic suites 均通过。该结果仍不替代至少 20 个独立真实 holdout 的人工标注与阶段一门禁。

2026-09-30 真实 MyBatis 金标纠偏：`platform-job:7687f3fc23715a59dd5c77c4c6c3c68bcce71528` 的 `XxlJobInfo.executorTimeout` 是请求绑定后的 primitive `int`，静态源码证据表明任意 SQL 片段无法进入该 Mapper；父提交已经存在同类 `${executeTimeout}` 形态，因此该提交没有新增可证实的 P1 SQL 注入。旧的 clean 结果应保留，不能把模型重复输出的旧启发式当作金标。运行器现只把完整 Mapper 参数类型和 Java 数值 getter 作为显式线索发给模型；未知类型仍 fail-closed，且不再静默删除模型自己的问题。两轮 typed rerun 均完整、结果稳定；该纠偏降低确定性预检误报，不扩大阶段一召回分母。

2026-09-30 重复稳定性门禁改为 finding signature：完整两轮合成门禁中，`java-tenant-leak` 两次都命中同一 P1 和同一行号，但模型标题/措辞不同，旧的字节哈希会误报漂移。新增 `evals/finding-signature.sh`，只用于比较严重级别、路径/行号、风险族和 MyBatis 表达式，绝不修改或隐藏用户看到的完整输出；两轮门禁现为 46 个正例和 44 个 clean 对照全部通过，截断故障仍显式失败。

2026-10-01 真实冻结留出暴露三组可靠性漏报：XXL-JOB 可空作业参数/结果消息、角色 API 授权未按租户应用范围校验、寻货入库绕过仓库供方归属。运行器新增窄范围确定性证据门：只有当前新增代码直接调用同仓库可见的 nullable `XxlJobHelper.getJobParam()`、对可空 `ReturnT.msg` 调用 `length()`，或同时满足角色/API 分配、全局 `activeApplicationIds(null)`、角色租户守卫且缺少租户授权 scope 时才追加 P1；其余 getter、应用查询和仓库校验不泛化推断。`evals/test-preflight.sh` 已加入对应正例与负边界。冻结样本双跑 finding signature 稳定，但原模型对 job/system/ERP 三组均漏报，说明该层属于运行器可验证性增强，不应冒充模型原生召回；完整输出、原始结果和人工标签仍保留在私有评测目录。

同日阶段一验收审计：此前用于调优 MyBatis、凭据、权限、迁移和并发预检的真实提交不能继续作为最终未见 holdout；它们只能作为开发/诊断证据。最终生产验收必须冻结当前运行器与 Modelfile 后，排除已用于规则设计的提交及同功能簇，重新选择至少 20 个跨仓库真实提交，完成双轮运行、人工 P0/P1 真值、行号核对和误报标注。未完成这次冻结前，不能从现有 scorecard 推导生产召回率。

2026-10-01 输出可见性契约收紧：确定性预检现在只作为带有“来源：确定性预检（代码证据，非模型原文）”标记的附加段落写入最终结果，不再用预检去覆盖、过滤或语义去重模型的具体问题。仍可移除的仅是明确的非问题说明、分片缺上下文提示和终端控制序列；遇到无法验证的位置或截断响应仍 fail-closed。`evals/test-output-visibility.sh` 与 `evals/test-filter-evidence.sh` 均验证模型 marker 和预检 marker 同时可见，确保“所有发现可见”优先于降噪。

随后补强 MyBatis 类型边界：数值属性必须由精确 `parameterType` FQN 和实际 Java 数值 getter 同时证明；字段类型、简单类名、注释 getter、嵌套表达式、`<bind>` 以及 `<foreach item/index>` 遮蔽均 fail-closed 保留候选。全仓扫描在每个 Java/XML 文件前后检查总超时，测试覆盖 10 个类型边界；模型段落只有在所有 `${...}` 表达式都被同一确定性证据覆盖时才视为同根因重复，未覆盖的第二个表达式继续完整可见，新增 MyBatis 去重回归为 6 个用例。模型发现仍需人工验证，类型线索不会静默删除模型问题。
