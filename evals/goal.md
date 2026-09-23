# 高可用代码审计模型目标

## 目标定义

把 `devstral-small-2-review-tuned` 调成可重复、可验证的本地代码审计模型，而不是只让它输出更长的分析。验收需要同时覆盖召回、误报、定位、完整性、稳定性和故障处理。

## 阶段目标

### 阶段 0：合成回归门槛

每次修改 `config/Modelfile`、`bin/local-review.sh`、私有 few-shot 示例或审计规则后，先运行：

```bash
./evals/run-synthetic.sh
```

每个正例和负例夹具默认运行 5 次。正例覆盖以下已知问题族：

1. `Integer` 参数可能为空；
2. 除数可能为零；
3. 凭证被拼接进 URL 查询参数；
4. 租户隔离查询遗漏 `tenantId` 约束；
5. 删除版本化迁移导致已有库升级路径中断；
6. 配置中的字面量凭据泄漏；
7. 终态预签名票据仍可重放。

阶段 0 必须满足：

- 5/5 次成功返回；
- 所有已配置的正例问题族全部被发现，P0/P1 召回率为 100%；
- 不报告 `final`、Javadoc 或 Java 整数溢出等已知误报；
- 5 次输出内容一致或差异可解释；
- 负例不产生 P0/P1/P2/P3 问题；包括“令牌放入内部请求 header”的安全边界负例。
- `OLLAMA_REVIEW_NUM_PREDICT=1` 时以非零状态失败，并明确提示输出截断。

阶段 0 只是回归门槛，不能替代真实项目评测。

### 阶段 1：真实历史提交评测

建立至少 20 个经过人工确认的历史提交，按提交切分人工确认示例和留出评测集。每次记录：

- P0/P1 召回率，目标不低于 90%；
- 误报数量及误报率；
- 文件和行号准确率；
- 输出是否完整；
- 耗时、模型名、temperature、seed、num_ctx、num_predict；
- 同一提交重复运行的稳定性。

在阶段 1 达标前，不宣称模型已经达到高可用生产标准。

## 2026-09-22 进展：稳定根因聚合

构建预检现在按变更文件聚合同一编译阻断：同一 Java 文件缺少多个仓库内类型时只计一条 P1 根因，但首行保留全部行号，正文保留每个缺失类型及其行号。这样不会隐藏用户必须修复的任何位置，也不会把一次编译失败错误计成多条独立问题。`evals/test-preflight.sh` 的 `MultipleMissing.java` 夹具和逗号行号分片路由回归均已通过；真实 `420ae70c` 复核确认最终只输出 1 个 P1 根因，保留 5 个 DTO 类型和 `3,4,5,6,7` 全部位置。

## 当前状态（2026-09-14）

- 阶段 0：已通过。默认门禁完成 5/5 正例、5/5 负例；除法、URL 拼接凭证、URL 查询参数令牌、租户隔离、迁移删除、字面量凭据和预签名票据等正例每次全部命中，4 个 clean 负例没有 P0～P3，重复运行输出哈希保持一致，截断故障路径显式失败。无模型 `test-preflight.sh` 另外覆盖构建完整性、跨 hunk SSRF、URL builder、路径 API 别名、多处 Java 除法、配置凭据和 guard 边界；`run-synthetic.sh` 会先执行该门禁。
- 阶段 1：未完成。已从本地 `platform-api` 历史建立 20 个候选提交清单，保存在 `~/.local/share/local-review/evals/platform-api-20.tsv`；20 个提交都已完成首轮私有运行和人工初判，但仍需重复运行、补充跨仓库 context 样本并完善行号准确率统计。
- 当前首轮证据：`91bff253` 和 `2f6c3934` 的模型候选均被人工判定为误报；`39955c8` 在默认 3000 字节门禁下记录为基础设施失败，提高预算后完整返回但 29 条候选仍均为误报；`cbe47ea0`、`501ad5a1`、`ccea445b`、`a1284658`、`f1a093a3` 以及剩余文件管理/Swagger/策略提交均完整返回 clean。`420ae70c` 的旧基线漏报了当前提交树缺失 DTO 的 P1 构建阻断；增加确定性 import 预检后复测识别出该根因。`f6fc2f89` 在提供 `platform-file` context 并启用删除类型预检后识别出跨仓库 P1 兼容性阻断。以上仍不足以计算高可信召回率，不能宣称已达到高可用生产标准。
- 当前模型参数：`temperature=0`、`seed=42`、`top_k=40`、`top_p=0.9`、`num_ctx=16384`、`num_predict=4096`。通用 `local-review` 在超过 3000 字节时按文件、再按 hunk 分片，默认 `chunk_timeout=180s`、`chunk_num_predict=2048`；个人 `local-review-local` 为了减少复杂分片截断将 `chunk_num_predict` 覆盖为 4096。大变更也可显式提高 `num_ctx`，但必须重新评测耗时和超时率。
- 合成门禁默认使用个人 `local-review-local`，因此连续运行会保留模型 5 分钟；可通过 `SYNTHETIC_REVIEW_SCRIPT` 显式切换到其他入口做对照，但稳定性验收默认以个人日常入口为准。一次冷启动基线曾在 clean 对照上出现 180 秒超时，切换后完整 5 轮恢复通过且未放宽超时/截断失败条件。
- 构建完整性预检：审查器会从新增/修改的 Java import 中提取同仓库前缀类型，并检查当前源码索引；可确定的缺失类型、以及当前仓库/显式 `--context` 仍引用当前提交删除类型的证据，会作为带完整字段的 P1 结果确定性合并到最终输出，不再只依赖模型是否采纳提示。分片只接收自身文件的预检证据，最终按风险族语义去重；外部依赖、生成源码、通配符 import 和无法确认的候选仍必须结合构建上下文人工确认，不能把路径预检单独当作完整编译器。
- 当前去重 scorecard（20 个提交）记录 2 个已确认 P0/P1 根因，均被当前预检链路命中，暂时为 2/2（100%）召回；同时有 55 条模型候选、46 条人工误报。这个分母只有两个真实高优先级根因，统计显著性不足，不能据此宣称达到 90% 生产验收目标。scorecard 汇总现在会拒绝缺列、重复提交、非法数字和超出人工真值的记录。
- 最新个人高性能 profile 已重新运行全部 20 个历史提交：20/20 成功，实际模型均为 `devstral-small-2-review-tuned`，总耗时 480 秒、平均 24 秒；除 `420ae70c` 的确定性构建预检输出 5 条受影响引用外，其余结果均为 clean。该轮结果保存在私有目录，尚未替换人工标签或计算新的召回/误报指标；因此仍不能宣称达到 90% 生产验收目标。
- 在 `162a35a` 的风险族去重修复后，20 个历史提交再次全部完成且无超时/截断；除已知的 `420ae70c` 构建阻断外，`63d520b` 与 `a1284658` 新出现了各 1 条“从 URL 查询参数读取 x-token”的确定性 P1 候选。回看差异后两处均有明确的 `getParameter("x-token")` 回退路径，但其是否应计入项目真值仍需人工结合契约确认；本轮候选不会自动改写旧 scorecard。
- 运行入口一致性：`scripts/install-global.sh` 将 `local-review`、`local-review-local` 及带 `.sh` 后缀入口链接到当前工作流；`scripts/verify-runtime.sh` 会校验全局脚本哈希、Modelfile SYSTEM 和 Ollama 运行态。确定性预检只存在于这两个 wrapper，直接 `codex`/`ollama run` 不包含该层保证。
- 最新真实回归：`platform-file:7b62671` 在当前 wrapper 下连续两次均命中三份配置中的 6 个硬编码凭据行；两次结果 SHA-256 相同，且分片聚合没有残缺 finding。该样本用于验证凭据预检与分片完整性，不替代阶段 1 的多提交人工标注。
- 2026-09-14 完成一次完整 5 轮合成门禁：`java-divide`、`java-token-url`、租户隔离、迁移删除、硬编码凭据和预签名票据正例均 5/5 命中且哈希稳定；20 次 clean 负例全部通过；`num_predict=1` 截断路径按预期失败。真实 `platform-file:2e33eaf` 还验证了非法 UTF-8 响应归一化和自然语言凭据脱敏，结果以 0 退出并保留完整问题字段。
- 同日复测真实 `platform-file:5a9a19b`：新增 Nacos 配置中的可预测 `${NACOS_PASSWORD:nacos}` 默认凭据被确定性预检完整定位为 6 条 P1（3 个配置文件各 2 处），模型输出未回显凭据值。该结果已写入私有评测目录，仍待人工确认后才能进入阶段 1 真值统计。
- 2026-09-15 修复 Java 除法预检对字符串/字符字面量和跨行块注释中 `/` 的误识别：扫描器现在跳过字面量、行注释和块注释后再定位运算符，新增回归样例；预检、历史、运行态校验和完整 5 轮合成门禁均通过，`java-divide` 仍为 5/5 且输出哈希稳定。
- 同日补充 URL 凭据局部别名预检：从已知 token/secret 变量直接赋值到普通局部变量、再拼入 URL 的路径会被确定性识别；别名状态在同一文件的多个 diff hunk 间保留，普通 ID 别名保持 clean。专门回归和完整 5 轮合成门禁均通过。
- 同日对 `platform-api-20.tsv` 使用个人 profile 做两轮真实历史复测：20/20 提交均 completed，完整输出和运行配置签名逐提交一致；非 clean 仍仅为 `420ae70c` 的 5 条构建阻断引用，以及 `63d520b`、`a1284658` 各 1 条待人工确认的查询 token 候选。
- 评测标签链路新增按结果内容 SHA-256 的安全迁移和 scorecard 自动构建：结果路径变化但内容完全一致、且标签条目数量不超过最终候选数、文件/行号与候选重叠时才迁移 complete 标签，内容变化、候选计数不一致、定位不一致或运行元数据缺失时均 fail-closed；相关回归测试已通过。
- 2026-09-15 对迁移后的真实标签运行 scorecard 构建时，`2f6c3934` 和 `91bff253` 被安全拒绝：标签分别记录了 12 条和 5 条误报，但对应的最终 `source_result` 都只有“未发现阻塞问题”，候选数为 0。构建器没有把这些历史标签强行计入统计，也没有留下半成品输出；这说明剩余阻塞是标签与最终结果内容的语义不一致，必须重新阅读原始审查过程并将标签改为与最终结果一致后，才能继续计算真实误报率/召回率。
- 同日 `test-scorecard-builder.sh`、`test-label-migration.sh`、`test-history.sh` 和 `scripts/verify-runtime.sh` 均通过；重建 SQL 规则后的运行态 tuned 模型 SYSTEM SHA-256 为 `9aa021f8c50feaac17ab2556bbe4485e18d87a726ff0b848e3a5451e9f6c0274`。因此当前不是运行器或模型规则漂移，而是阶段 1 人工标签尚未完成一致性复核。
- 重新从原始历史标签迁移到当前个人 profile 结果时，位置/数量双重门禁仅接受 14 份标签，拒绝 6 份；对这 14 份生成的 scorecard 为 14 个 clean、0 个 confirmed P0/P1，因此 `p0_p1_recall=n/a` 是正确结果，不能把“全是 clean”误报成 100% 召回。剩余 6 份必须重新绑定到对应最终结果并人工确认后，阶段 1 才有可测分母。
- 在同日完成这 6 份重新绑定后的人工复核：`2f6c3934`、`91bff253`、`39955c8` 标为 clean，`420ae70c` 确认 5 条缺失 DTO 的 P1 编译阻断，`63d520b` 与 `a1284658` 各确认 1 条从查询参数读取 `x-token` 的 P1。私有标签集 `platform-api-labels-final-20260915` 生成 20 行 scorecard：7 个 confirmed P0/P1、7 个命中、0 个误报，当前为 7/7（100%）；分母仍只有 7 个真实高优先级根因，且未分离 holdout，因此这只是阶段 1 的当前证据，不是生产级验收结论。
- 同日补充评测了仓库中原 20 提交清单之外的 4 个非合并业务提交：`b4ea10fc`、`12a1aeb0`、`6dc87ecf` 标为 clean，`89ea7d8d` 对工作流事件 claim/ack 未显式携带租户上下文标为 uncertain，等待服务端实现复核。扩展私有标签/结果集 `platform-api-labels-final-extended-20260915` 共 24 个提交，scorecard 仍为 7/7（100%）、0 误报、1 个 uncertain 未计入；新增样本增加了 clean 覆盖，但尚未增加已确认 P0/P1 分母。
- 对这 4 个补充提交使用个人 profile 做两轮完整重复审查，`run-history-repeat.sh` 通过，4 个提交的最终文本和运行配置签名均无漂移；稳定性证据保存在私有目录 `platform-api-results-supplemental-repeat-20260915`，不提交到公开仓库。
- 2026-09-15 开始引入 `platform-file` 独立安全 holdout（OSS 明文凭据、默认 Nacos 凭据和多配置变更）。复核 `d984778` 时发现其新增 JDBC/Redis 远端地址下的默认密码未被旧预检识别；已将远端 endpoint 识别扩展到 `jdbc://`、`server-addr` 和非本机 `host/endpoint`，并加入 `application-credential-remote-default.yml` 回归。该修复后的 holdout 结果必须重新运行后才能计入正式 scorecard，旧运行结果不复用。
- 当前规则版本已重新运行 `platform-file` 的 3 个较快 holdout：`273887de`、`7b626716`、`5a9a19b` 共 17 个 confirmed P1，17 个全部命中、0 误报；两轮完整重复审查的文本和运行签名均稳定。独立 holdout scorecard 保存在私有目录 `platform-file-holdout-scorecard-20260915.tsv`，不与 `platform-api` 的 7 个根因混合计算。`d984778` 的大差异结果另行标注，避免把约 10 分钟的单提交样本混入快速 holdout 的耗时结论。
- 对真实 `d984778` 提交快照做无模型预检验证后，当前规则稳定补出 4 条确定性 P1：`platform-file-dev.yml:11`、`:23` 的远端数据库/Redis 默认密码，以及 `platform-file-localhost.yml:65-66` 的 OSS 明文凭据；该输出只验证预检，不计入模型 scorecard，完整模型重跑仍需单独完成。
- `dd46734`（查询令牌参数别名预检）之后，个人 profile 对 `platform-api-20.tsv` 的 20 个历史提交再次全部成功，无超时或截断；17 个结果为 clean，非 clean 仅为 `420ae70c` 的 5 个缺失 DTO 引用、`63d520b` 和 `a1284658` 各 1 个查询令牌候选。对后两提交各追加 2 次复测，三次完整输出 SHA-256 均分别稳定为 `5bb7f0d8c8e90a9abedd9c0e0ed0872dc13cdfec590077f2459548c484b3d207` 和 `c5d1b2f4da7040638ce8b88c7cb0e50368c41e5416db0e1a39a40f76737f1719`；这些结果仍不能替代人工真值或证明 90% 生产召回率。
- 2026-09-15 对 `platform-file:d984778` 先尝试 `num_ctx=32768`、9000 字节大分片；三次 Ollama 请求均在 180 秒内没有返回任何字节，整次耗时 587 秒并按失败处理。该结果证明单纯增大上下文和分片会降低可用性，不能作为默认优化方向。
- 同一提交随后用 `num_ctx=16384`、3000 字节分片、`chunk_num_predict=4096` 完整完成，耗时 627 秒，结果 SHA-256 为 `8f31da2aa9bda2e90bd0d7ceba78b9c0b7f798dc444423fd7c38fab1d7d5736a`，与此前同配置运行的结果逐字节一致。当前完整结果保留 4 条确定性预检凭据问题（dev 数据库密码、dev Redis 密码、localhost OSS AccessKey 和 Secret），模型另输出 1 条覆盖 `localhost.yml:40-52` 的 OSS 汇总；该汇总根因基本一致但行号范围未覆盖真实新增凭据行，人工标注为定位误报。独立 d984 scorecard 为 4 个 confirmed P1、4/4 命中、5 个候选、1 条定位误报；大提交的推荐路径仍是较小分片和 16384 上下文，不能把 32768 失败运行或半截输出计入指标。
- 同日新增两个不同根因的 `platform-file` holdout：`896dca8` 删除版本化迁移脚本，人工确认 1 个 P1 根因，模型 1/1 命中但重复报告 3 条（2 条按重复/同根因定位误报）；`937c577` 的内部后台上传与租户上下文改造经公共 `GatewayAuthFilter`、服务层租户/用户交叉校验和差异复核后标为 clean。两个提交均完成两轮重复审查，完整文本和运行配置签名稳定。加上已有 3 个快速配置 holdout，当前 `platform-file` 私有 scorecard 分开记录了 22 个 confirmed P1，22 个全部命中，3 条重复或定位误报；该汇总仍覆盖有限的真实提交和根因族，不能替代跨项目生产验收。
- 2026-09-16 修复分片预算边界：运行器现在无论差异大小都会先估算固定系统规则、项目上下文、变更路径和确定性预检的输入开销；当有效预算小于配置阈值时按有效值分片，避免“小 diff + 大上下文”仍直接发送超预算请求。历史评测通过 sidecar 将 `configured_max_diff_bytes`、`effective_max_diff_bytes`、预算探测 token 数和调整标志写入 `.meta.tsv`，普通本地审查不产生额外文件。预检、scorecard、标签迁移、历史和运行态校验均通过；当前全局 `local-review` 哈希与仓库脚本一致。
- 2026-09-18 修复两类重复/漏报边界：`java-divide` 预检不再把 unified diff 上下文中的既有除法当作新增问题；大文件跨多个分片时，确定性预检证据现在路由到每个相关分片，避免后续分片用不同措辞重复报告同一 URL/除法风险。过滤器同时保留混合了租户、SSRF、并发等独立根因的模型段。新增既有除法、跨分片 URL 变体和混合根因回归均通过。
- 2026-09-18 继续收紧预检与聚合：`java-token-url` 现在要求完整参数名并兼容大小写 `X-Token`，不再把 `tokenizer`/`authorizationCode` 等前缀误报；别名状态跨同文件 hunk 保留。`java-divide` 只接受拒绝 `null`/`0` 的 guard 方向，忽略注释、反向比较和同一行后置检查，并覆盖链式除法。最终分片聚合按风险族语义去重，新增低严重度先于高严重度、不同措辞分片重复和多分母回归；`test-preflight.sh`、`test-sharding.sh` 均通过。
- 同日进一步把 token/secret alias 绑定到当前源码的方法范围，修复不同方法复用同名局部变量时的跨 hunk 误报；新增跨 hunk 正例与同名局部变量负例通过，真实 Ollama 合成门禁仍保持全部正例命中、clean 负例通过。
- 同日补齐方法作用域解析边界：支持多行方法签名、左花括号换行，并在计算 Java 大括号深度前剥离字符串、字符字面量和块/行注释；新增 wrapped-signature、同名局部变量和大写类常量别名回归，避免 `java-token-url` 因代码排版变化反复误报或漏报。
- 随后补齐 Java text block 与多级别名边界：作用域扫描忽略跨行 `"""..."""` 内容中的 JSON/SQL 花括号，token/secret 直接别名可连续传播但不会把普通变量扩大为凭据；对应回归覆盖两级 token 查询别名和两级 URL 凭据别名。
- 同日继续收紧除法词法边界：新增行位于 Java text block 内容时，即使所在方法有 `Integer` 参数也不再把文本中的 `/` 误报为 `java-divide`；上下文行只用于推进 text block/块注释状态，不会被归因为本次新增问题。
- 同日补齐跨 hunk 词法状态：除法预检从当前源码快照恢复每个 hunk 起始行之前的 text block/块注释状态，新增 `SplitTextBlockDivide` 和 `SplitBlockCommentDivide` 负例验证分隔符不在当前上下文时仍不误报。
- 同日补齐 token/url 别名中的行内注释边界：`TOKEN_HEADER` 或凭据变量赋值行带 `//`/`/*...*/` 注释时，别名仍能跨行传播并进入预检；对应普通参数负例继续保持 clean。
- 同日补齐源码快照别名恢复：别名赋值未改动且位于 diff 上下文之外时，新增 `getParameter(alias)` 或 URL 拼接仍能按当前 Java 方法作用域命中；新增 `PreExistingQueryTokenAlias`、`PreExistingUrlSecretAlias`，并保持同名局部变量不跨方法串线。
- 同日统一 token 别名的 header 大小写语义：源码快照和 diff 内的 `"x-token"`/`"X-Token"` 直接别名均进入同一查询参数风险规则，新增大写别名回归通过。
- 同日用当前运行器和 `devstral-small-2-review-tuned` 复核真实 `platform-api` 提交 `91bff253`、`63d520b`、`a1284658`：三次均 exit=0；前者保持 clean，后两者各保留唯一的 `getParameter("x-token")` P1（58、81 行），结果字段完整且使用已校验的 tuned SYSTEM 规则。
- 同日用当前 tuned 运行态对 `platform-api` 的真实提交 `63d520b`、`a1284658` 和 `39955c8` 做定向复核：前两个提交各只保留一个对应文件/行号的 `x-token` 查询参数 P1，后一个提交为 clean，三次均完成且 exit=0；这说明前两个是不同业务位置的真实重复模式，不是同一次分片聚合重复制造的 finding。
- 同日继续收紧 `java-divide`：源码签名恢复改为按当前方法花括号范围前向解析，新增“前一方法为 `Integer`、当前方法为 `int`”负例；复杂三元分母不再被截断成第一个变量，新增安全负例，原有方法调用表达式和链式除法正例仍通过。
- 同日补充 token/url 多行语法回归：跨行直接别名赋值、两级 URL 凭据别名以及跨行 `getParameter(...)` 参数现在都会进入同一确定性预检；普通 ID、内部请求头和未完成别名仍保持 clean。
- 同日补齐完全限定 Java 返回类型边界：作用域/签名解析现在识别 `java.lang.String`、`java.lang.Integer` 等含 `.`/`$` 的类型名；新增完全限定返回类型除法正例和跨方法 token 别名负例，避免漏报或文件级作用域串线。
- 同轮又补齐同一行注解边界：`@Deprecated(...) java.lang.Integer divide(Integer a, Integer b)` 的参数提取现在选择最后一个顶层方法括号，不会误取注解参数；新增 `InlineAnnotatedDivide` 正例，完整合成门禁哈希保持稳定。
- 随后补齐注解数组花括号边界：方法作用域只在参数列表后紧跟方法体或 `throws` 方法体时建立，新增同一行 `@SuppressWarnings({...})` 的 token 别名跨方法负例，避免注解 `{}` 让作用域退化到文件级。
- 随后用该解析器版本重新定向复核真实 `platform-api` 提交 `63d520b` 与 `a1284658`：两次均 exit=0、输出完整且各只保留唯一一条 `getParameter("x-token")` P1，分别定位到文件客户端第 58 行和字典客户端第 81 行；结果仍使用 `devstral-small-2-review-tuned` 与固定 SYSTEM SHA-256。
- 同日对 `platform-file:a9a1d4a` 做独立安全留出：初始模型返回 clean，人工复核确认单删和批量删除都移除了 `fileStorageService.delete(...)`，导致 OSS/本地对象残留；初始私有 scorecard 为 0/1，作为真实漏报对照。新增对象生命周期确定性预检、同文件同根因聚合和 `missed` 人工标签状态后重跑，单删/批删合并为 `99-108` 行一条 P1，scorecard 恢复为 1/1、0 误报；原始与修复后结果均保留在私有目录。
- 2026-09-18 对补充提交 `89ea7d8` 的 workflow claim/ack 做服务端上下文复核：服务端事件表含 `tenantId`，claim/ack 使用 `ignoreTenant` 且查询/更新未携带租户条件；个人 tuned 模型即使收到三份显式 context 仍返回 clean。新增严格 opt-in 的跨上下文租户预检，只有内部客户端新增 claim/ack 方法携带 `X-Gateway-Token`、缺少 `X-Tenant-Id`，且 context 同时证明事件租户字段与 `ignoreTenant` 时才报告 P1；claim/ack 双正例和无绕过证据负例已加入 `test-preflight.sh`。
- 2026-09-18 对 `platform-workflow-service:65de399` 复核时，模型把移除本地默认凭据、改为必须注入运行时环境变量误报成启动/连接失败 P1。新增严格的 fail-closed 配置误报过滤，并用“同一配置变更 + 独立跨租户根因”回归确认只过滤前者；逗号分隔行号的证据解析也已覆盖。真实提交复跑为 clean，独立安全根因仍保持可见。
- 2026-09-18 增加四个跨服务探索性留出：`platform-gateway:052b848`、`platform-publishing-service:6e24286`、`platform-integration:fd0f1c4`、`platform-hr-service:51709d1` 均用个人 profile 完整结束并返回 clean；publishing 的版本化产物接口另经代码语义复核，确认保留历史版本是契约行为。这四条尚未完成独立人工真值标注，不计入正式召回率或误报率。
- 同日完成大提交 `platform-system:57475a8` 的个人 profile 复核：约 4,000 行迁移/权限 SQL 在 535 秒内完整结束、无截断，结果为 clean；模块 SQL 合约测试 16/16 通过。该样本只记录为高成本探索性证据，不计入正式 scorecard 或性能承诺。
- 同日为历史评测增加私有分片追踪：`.meta.tsv` 现在记录分片总数、每片文件路径、diff/提示词字节数、估算输入 token、状态和耗时，正常 `local-review` 输出保持不变；分片、历史、预检、scorecard 和运行态回归均通过。
- 同日用追踪复跑 `platform-file:7b62671` 两次：14 片中 README、dev/localhost 配置和主配置+Java 三片耗时最高（29/45/43 秒），其余为 3–6 秒；完整结果哈希保持一致。没有因为这组数据盲目扩大默认分片，后续优化需保持 fail-closed 和完整输出门禁。
- 同日隔离配置文件对照 `chunk_num_predict=2048/4096`：两次都完整保留 6 条凭据问题，结果哈希一致，耗时 123/125 秒；降低输出预算没有收益，因此保持个人 profile 的 4096 设置，不以速度换取截断风险。
- 同日全局禁用 few-shot 的 A/B 作为负面对照：`java-token-header` clean 样本耗时 197 秒且哈希变化，`java-tenant-safe` 连续 3 次 180 秒无响应，整次审查失败；因此保留 examples，不采用看似更快但破坏 clean 稳定性的方案。
- 2026-09-19 修复“预检证据较多时首片预算低估”的可用性边界：真实 `platform-file:f6ce8f6` 首次因固定探测 9,095/11,264 token、实际首片 11,367 token 而在请求前失败；现在按分片路径和路由预检证据的实际增量动态提高 reserve，将有效分片预算从 3,000 调整为 2,004 字节。复跑后 8 个分片全部完成，309 秒内保留 8 条确定性凭据 P1；完整预检、分片、运行态校验通过，未改变默认 few-shot 或截断失败策略。
- 同一 `f6ce8f6` holdout 还确认 `sql/platform_file.sql` 新增的 `CREATE DATABASE platform_file_db` 与保留的 `USE platform_db_file` 不一致；新增窄范围 SQL schema 预检，仅在单一 CREATE/USE 且至少一条为新增行时报告 P1，多 schema、同名、CREATE-only 和行尾注释负例保持 clean，回归已加入 `test-preflight.sh`。
- 2026-09-19 将同一条 SQL schema 边界同步进 `config/Modelfile` 并重建 tuned 模型（复用已有基础层）；`SYNTHETIC_REVIEW_RUNS=1 ./evals/run-synthetic.sh` 通过，除法、URL token、租户、迁移、凭据、预签名和 4 个 clean 负例均完成，截断故障仍按预期显式失败。运行态 SYSTEM SHA-256 为 `9aa021f8c50feaac17ab2556bbe4485e18d87a726ff0b848e3a5451e9f6c0274`。
- 2026-09-20 在同一运行态上重新执行 5 轮完整合成门禁：`java-divide`、`java-token-url`、查询参数令牌、租户隔离、迁移删除、字面量凭据和预签名票据均 5/5 命中，20 个 clean 对照全部通过，所有样例的输出哈希在 5 轮内一致，截断路径按预期显式失败。另加入重复共享 token 的 5 处配置位置回归，确认预检不会因同一根因去重而隐藏受影响行；结果已提交为 `85e25ad` 并推送到公开仓库。阶段 1 的真实人工标签分母仍未扩大，不能据此宣称达到生产级召回目标。
- 2026-09-21 对真实 `platform-file:cf6a214` 做配置误报留出复核：5 条确定性共享 token 凭据问题全部保留；对普通 `${ENV:default}` 具体化的 5 组条件式配置推测采用窄范围输出过滤后全部移除。此前尝试把这条边界写进 SYSTEM 提示词会造成迁移正例输出漂移，已撤回；当前仅保留运行器门禁，并以无模型回归、两轮合成门禁和真实提交复跑验证不影响 `java-divide`、`java-token-url`、租户、迁移等独立根因。该结果用于降噪，不扩大人工真值分母。
- 同日补充真实 `platform-workflow-service:beab22f3` 配置/SQL 合约留出，个人 profile 39 秒完整返回 clean；该结果只作为待人工确认的探索性样本，不计入正式召回率或误报率。
- 同日补充真实 `platform-file:bc14e16` 配置留出，个人 profile 30 秒完整返回 clean；`${COMPUTERNAME:NY-TEST-LOCAL}` 在非 Windows 环境的共享集群名风险暂标为待人工确认 P2，不据此修改规则或统计正式召回率。
- 同日修复 URL builder/别名状态边界：`.queryParam("token", userId)`、`String.format("...?token=%s", userId)` 等普通 ID 不再因为整行关键词被误报；令牌别名重赋为普通值后会清除旧状态。四个负例已接入 `test-preflight.sh`，不改变高置信 `java-token-url` 正例的覆盖范围。
- 同日修复同一 hunk 内的 Java 方法串线：每个新增除法现在按当前源码快照独立绑定包含方法的 `Integer` 参数和 guard；`SameHunkMethodScopeDivide` 确认前一个 boxed 方法的 P1 不会复制到后一个同名 primitive 方法。
- 同日补齐定位与跨行表达式回归：问题段第一行必须同时携带已变更路径和有效行号，逗号分隔的多个行号逐段校验；Java 除法覆盖 `a /` 与 `/ b` 跨行，URL 凭据覆盖跨行 `+` 和 `StringBuilder.append`。`test-preflight.sh`、完整确定性回归和 `SYNTHETIC_REVIEW_RUNS=1 ./evals/run-synthetic.sh` 均通过，未改变 fail-closed、全量展示和截断失败门禁。
- 2026-09-22 修复历史重复评测把 `initial_status`/`chunk_status` 耗时误判为配置漂移的问题；现在只忽略耗时，仍比较退出码、分片差异字节数、路径、模型、规则和参数签名。回归夹具刻意制造两轮耗时差异后通过；当前 tuned 运行态对 `91bff253` clean、`63d520b` 的查询 token P1、`420ae70c` 的聚合构建阻断 P1 均完整复核，后者保留全部 5 个缺失 DTO 位置，`63d520b` 两轮真实重复审查也通过。
- 2026-09-23 在 `5cb0efe` 推送后重新执行 5 轮合成门禁：7 类正例均 5/5 命中，20 个 clean 对照全部通过，所有样例五轮输出哈希一致，截断路径显式失败。该结果验证聚合与分片路由修复未改变既有高置信规则，但不扩大真实人工 holdout 的召回率分母。

## 失败处理原则

2026-09-21 更正：上述 `f0b3bcb` 配置措辞过滤已撤回。独立回归发现“端口 70000 + 可能启动失败”等完整报告被静默转为 clean，非法路径/行号/缺字段也被过滤绕过校验；修复前 7 个用例中 6 个失败，移除过滤后 7/7 通过。此前过滤后候选减少不能证明精度提升，真实样本中的配置推测仍待独立核实。该组回归通过 `test-preflight.sh` 进入 CI 和合成门禁，不扩大模型召回真值分母。

任何 API 错误、空响应、超时或 `done_reason=length` 都算本次审查失败，不能把半截结果计入召回率，也不能用模型输出替代人工确认。
