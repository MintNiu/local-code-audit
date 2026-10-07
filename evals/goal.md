# 高可用代码审计模型目标

## 目标定义

把 `devstral-small-2-review-tuned` 调成可重复、可验证的本地代码审计模型，而不是只让它输出更长的分析。验收需要同时覆盖召回、误报、定位、完整性、稳定性和故障处理。

### 当前进展（2026-09-27）

### 2026-10-04：效率优先的发布票据泄露预检

针对 `platform-publishing-service:0ae0ffb` 的漏报，新增窄范围 `collect_publishing_external_ticket_token_preflight`：只有差异新增下载请求的 `X-Gateway-Token`，且当前票据解析接受未做主机 allowlist 的绝对 HTTPS 地址时才报告 P1；带主机校验的负例保持 clean。正负 fixture 和完整 `test-preflight.sh` 已通过。真实长提交首轮 16 个分片完整结束并返回 clean，确认该样本作为 tuning-source；后续优先使用静态证据预筛和窄化差异，减少重复长提交双跑。

同轮对 ERP `8a2c1e1` 做真实父子快照验证：通用 schema-migration 预检在 `sql/platform_erp.sql:2407` 准确发现新增 `request_no` 没有既有库 migration。该样本按机制族转为 tuning-source，未再启动昂贵模型双跑，证明静态预筛能有效减少重复评测。

同轮新增 PDF 预览资源边界预检，真实 `platform-publishing-service:0ae0ffb` 快照稳定定位 `TypesetEvidenceApplication.java:143` 的无像素面积上限渲染，作为 P2 tuning-source 记录；带 MediaBox/CropBox 上限的负例保持 clean。

### 2026-10-01：真实冻结留出补强可空值与租户/仓库边界

阶段一冻结留出新增并完成双跑：`platform-auth:9dbcc0c` 模型命中查询参数令牌 P1、漏掉在线会话对象中的原始 token；`platform-job:5dfc6a1` 与 `c071a63` 分别漏掉可空 `XxlJobHelper.getJobParam()` 和可空 `ReturnT.msg.length()`；`platform-system:ecc8d75` 漏掉角色 API 绑定未按租户应用范围校验；`platform-erp-service:5592758` 漏掉寻货入库绕过仓库/供方归属检查。五个样本的重复 finding signature 均稳定，job/system/ERP 原模型均返回 clean，不能把合成 100% 结果外推为真实召回率。

针对三组可由当前源码直接证明的漏报，运行器增加窄范围确定性预检：仅识别同仓库 `XxlJobHelper.getJobParam()` 的 null 返回、`ReturnT.msg` 字段的直接 `length()` 解引用，以及完整角色/API/租户 scope 证据链；不把任意 getter、应用查询或仓库选择泛化为问题。预检正负边界已加入 `evals/test-preflight.sh`，并保持 fail-closed、完整输出和原始模型结果可见。下一步是冻结这版运行器后重跑阶段 0 五轮门禁，并继续扩大至少 20 个未用于调优的人工 holdout；在该分母完成前，生产级召回率仍为未验收。

运行器新增受限的跨事务/行锁文本证据：变更 Java 文件命中 `@Transactional`、`find*ForUpdate` 或 `FOR UPDATE` 时，把变更文件及相同锁接收者的关联 Java 文件摘要放入 prompt。现在摘要同时保留源码行号、锁调用上下文窗口和完整的锁调用顺序；它仍只是模型核验用文本，不自动证明同表、同事务或可达并发，证据有上限，预算不足时可降级跳过。

在该文本证据之外，运行器新增了一个更窄的确定性反向锁序预检：仅当两个带 `@Transactional` 的 Java 源码段包含相同直接 `*ForUpdate` 接收者、且顺序相反，并且至少一侧属于变更文件时，才追加一个标为“候选”的 P1。它不会把候选伪装成已确认死锁；finding 明确要求人工确认资源映射、调用可达性和并发前提。该候选不注入模型 prompt，而是在模型结果合并后加入，避免长上下文让模型重复或截断。预检是保守的源码文本分析，不是数据库锁图或完整 Java 调用图，复杂间接调用仍需人工/集成测试确认。

为避免既有锁序被无关改动触发，确定性候选还要求变更文件的新增/删除行本身触及事务或锁标记；仅改注释、字段或其他普通代码不会追加锁序 finding。Prompt 证据另外展示 `@Lock(PESSIMISTIC_WRITE)` 等声明式锁标记，但当前确定性候选仍只对直接 `*ForUpdate` 调用建序，声明式锁和 helper 封装继续交给模型与人工核验。

ERP 留出曾因私有 manifest 使用错误 parent 而无效，已修正且未把旧超时结果计入统计。正确 parent 下的 `736ef17845a9a45e55a262d6d64ea81738773059` 运行完整结束但模型 clean；人工代码审计确认存在销售订单/退货单反向锁序的 P1 候选，因此该次作为真实漏报证据保留，目标仍未完成。

正确 parent 下的 `7fee9f1a2af94fdc6d47769a7e93f2d7a493f140` 也已用冻结脚本、32768 context 和 12 个分片完整结束（151 秒、exit=0、clean）。人工确认退款草稿与退款确认存在带前提的退款单/退货单反向锁序 P1 候选；模型漏报，作为第二条并发漏报证据保留，不计入通过统计。

本轮后续诊断显示：确定性预检能够从该类 ERP 差异中补出反向锁序候选，但在 32768 context 的完整模型复跑中出现分片超时并按失败处理；较小上下文的诊断也曾因模型超时/截断失败。因此这部分只能说明“漏报有可观测的确定性候选”，不能宣称 ERP 历史审查已经完整通过。

评测链路新增 `output_complete`、`# verdict` 一致性门禁，以及 `./evals/stage1-gate.sh`。阶段一门禁现在会拒绝不完整运行、`clean` 与 finding 标签矛盾、跨 split 的功能簇泄漏，并要求至少 20 个提交、20 个 holdout P0/P1 根因、召回率/定位准确率/误报率和重复稳定性达到阈值。当前公开仓库只有门禁和合成夹具；真实评测数据仍在私有目录，尚未满足这些阶段一条件。

### 2026-09-28 增量

权限类真实留出 `platform-job:a2dc901` 的首次修复后运行曾因 Ollama 超时/截断失败；继续诊断确认模型在权限迁移分片中重复输出“若服务层未校验”的无证据段落。现在系统规则明确禁止这类条件式猜测，输出过滤器只在当前差异已展示权限迁移证据时移除重复/分片猜测；若模型因重复文本触发长度上限，且过滤后没有任何独立 finding，则仅保留确定性权限预检，其他截断仍 fail-closed。无模型过滤回归扩展为 8 个用例；运行态 tuned SYSTEM 已重建并校验。该真实留出在 16K context、3KB 分片、1,024 token 分片预算下 13/13 分片完整结束，耗时 124 秒；两轮重复为 123/128 秒，结果哈希与 finding 集合一致，私有 scorecard 标记 `output_complete=true`、`repeat_stable=true`、1 个确认 P1 命中。该证据改善了一个真实权限漏报和尾延迟边界，但阶段一仍未达到至少 20 个独立 holdout P0/P1 根因的门槛。

同轮五轮合成还覆盖了合法 MySQL 生成列和无租户契约 DDL 的信息级误报；窄范围证据门与 8 个过滤回归用例均通过，五轮结果恢复为 7 类正例 5/5、6 类 clean 30/30，未放宽截断或问题可见性门禁。

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

### 2026-09-24 最新增量：安全修复误报的证据门

真实 `platform-file:2e33eaf` 证明模型会把“删除旧字面量并改用环境变量”的安全修复稳定误报为 P1。系统提示词补充了统一 diff 语义；曾尝试加入对应私有 few-shot，但长提示词会增加部分样例超时，已撤回该示例。模型仍可能输出正文自承认“旧凭据已移除、无需修复”的 P1 段落，因此运行器增加了窄范围证据门：只有配置当前/上下文凭据字段全部为环境占位符、没有当前字面量、且段落明确无需修复时才视为 clean；任何新增/保留字面量或独立问题线索继续完整输出。`test-config-findings.sh` 现为 11 个用例，并额外验证同一配置仍保留另一份字面量时 finding 不会被隐藏；真实字面量凭据 `platform-file:7eb92a1` 仍命中 P1；`2e33eaf` 复跑为 clean。本次人工复核结论为 `gold_p0_p1=0`、`predicted_candidates=0`、`false_positive=0`，对应新结果没有覆盖先前旧 scorecard。该规则属于证据矛盾修正，不是通用关键词过滤，仍需更多安全修复反例和真实 P0/P1 holdout。

### 2026-09-25：迁移大提交复测

`platform-hr-service:a8bf560` 在 `num_ctx=32768`、9KB 分片下重新完整运行：28 个分片、554 秒、无截断。个人 tuned profile 命中两个经人工确认的 P1：配置中的字面量内部/OSS 令牌，以及 `sql/hr_assignment_history_integrity_upgrade.sql:33` 的触发器 DROP/CREATE 名称不一致。12 个候选中 8 个被人工确认误报，2 个因删除文件聚合和跨文件生成列定位不足标为 uncertain；新 scorecard 为 `gold_p0_p1=2`、`p0_p1_found=2`、`predicted_candidates=12`、`false_positive=8`、`output_complete=true`，该提交自身的 P0/P1 召回为 100%。这不是通用生产指标，且 554 秒延迟不适合日常默认审查；15KB 分片超时和旧 scorecard 继续保留作失败对照。

同日重新复核对象生命周期漏报提交 `platform-file:a9a1d4a`：当前 tuned profile 两次完整运行结果 SHA-256 一致，均命中删除元数据但移除对象存储清理的 P1；人工 scorecard 为 `gold_p0_p1=1`、`p0_p1_found=1`、`predicted_candidates=1`、`false_positive=0`。该证据补充独立对象生命周期根因族，但仍不足以替代更大规模的跨项目人工 holdout。

随后复核迁移兼容性提交 `platform-file:896dca8`：在 `04d325c` 干净工作树上两轮完整运行结果 SHA-256 一致，确定性迁移预检准确命中删除版本化 `V20260725__file_upload_session.sql` 导致已有数据库升级路径中断的 P1；README 与 SQL 删除是同一根因，正式 scorecard 为 `gold_p0_p1=1`、`p0_p1_found=1`、`predicted_candidates=1`、`false_positive=0`、`repeat_stable=true`。该样本补充迁移兼容性根因族，但没有迁移集成测试，仍只作为人工差异证据和稳定性留出。

### 2026-09-25 最新真实 clean 留出

新增 `platform-system:3b90a2e` 租户/批量查询留出：模型完整返回 clean，两轮重复稳定；人工确认输入上限、去重、租户条件和逻辑删除条件均有直接证据，私有 scorecard 为 `gold_p0_p1=0`、`predicted_candidates=0`、`false_positive=0`。该样本扩展了非凭据类 clean 覆盖，但阶段 1 仍需要更多真实 P0/P1 根因，不能据此宣称达到生产级高可用。

另新增 `platform-erp-service:2c12dc9` 资金充值幂等/并发 clean 留出：重复请求、唯一键异常分支和事务顺序经人工核对无可证实问题；两轮模型输出稳定 clean，scorecard 为 `gold_p0_p1=0`、`predicted_candidates=0`、`false_positive=0`。该仓库缺少充值专用并发集成测试，作为评测限制记录，不计作模型 finding；阶段 1 仍需继续增加真实 P0/P1 分母。

同一 ERP 服务的 `e5c6aab` 串码替换/库存占用留出也两轮稳定 clean，人工确认旧占用释放、新串占用和预览/确认事务边界没有直接可证实问题；scorecard 为 `gold_p0_p1=0`、`predicted_candidates=0`、`false_positive=0`。该提交缺少串码替换集成测试，仍只作为验证限制记录。

- 阶段 0：已通过。默认门禁完成 5/5 正例、5/5 负例；除法、URL 拼接凭证、URL 查询参数令牌、租户隔离、迁移删除、字面量凭据和预签名票据等正例每次全部命中，4 个 clean 负例没有 P0～P3，重复运行输出哈希保持一致，截断故障路径显式失败。无模型 `test-preflight.sh` 另外覆盖构建完整性、跨 hunk SSRF、URL builder、路径 API 别名、多处 Java 除法、配置凭据和 guard 边界；`run-synthetic.sh` 会先执行该门禁。
- 阶段 1：未完成。已从本地 `platform-api` 历史建立 20 个候选提交清单，保存在 `~/.local/share/local-review/evals/platform-api-20.tsv`；20 个提交都已完成首轮私有运行和人工初判，但仍需重复运行、补充跨仓库 context 样本并完善行号准确率统计。
- 当前首轮证据：`91bff253` 和 `2f6c3934` 的模型候选均被人工判定为误报；`39955c8` 在默认 3000 字节门禁下记录为基础设施失败，提高预算后完整返回但 29 条候选仍均为误报；`cbe47ea0`、`501ad5a1`、`ccea445b`、`a1284658`、`f1a093a3` 以及剩余文件管理/Swagger/策略提交均完整返回 clean。`420ae70c` 的旧基线漏报了当前提交树缺失 DTO 的 P1 构建阻断；增加确定性 import 预检后复测识别出该根因。`f6fc2f89` 在提供 `platform-file` context 并启用删除类型预检后识别出跨仓库 P1 兼容性阻断。以上仍不足以计算高可信召回率，不能宣称已达到高可用生产标准。
- 当前 core 模型参数为 `temperature=0`、`seed=42`、`top_k=40`、`top_p=0.9`、`num_ctx=16384`、`num_predict=4096`；个人 `local-review-local` 默认请求 `num_ctx=32768`、`chunk_num_predict=4096`，以容纳真实大提交的固定规则和分片证据。通用 core 入口仍保持 16K，调用方可显式提高上下文，但必须重新评测耗时和超时率。
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
- 同日对真实 `platform-api:420ae70c` 做两轮完整重复审查：两轮均 8 个分片、exit=0，文本 SHA-256 同为 `0d1da3ce59fd07e72b6c6370a99082b7738e807af919a4695b8c0f83d3ed07fe`，且每轮只有一个聚合 P1 并保留五个 DTO 位置；重复评测门禁通过，耗时差异未造成结果漂移。
- 同日修复评测层对逗号行号的解析：scorecard 构建与标签迁移现在支持候选 `:3,4,5` 和人工单行/范围的交集判断；新增聚合候选回归后，稳定根因可以按一个人工 finding 计数而不丢失位置证据。
- 同日为真实 `420ae70c` 建立本机聚合标签并生成 scorecard：`gold=1`、`found=1`、`candidates=1`、`false_positive=0`；旧五行标签保留为历史证据，不覆盖原始人工记录，私有标签和结果不提交公开仓库。

## 2026-09-23 进展：第二仓库配置 holdout 复核

真实 `platform-file:cf6a214` 已使用当前个人 profile 独立重跑：8 个分片、exit=0、耗时 204 秒、结果 SHA-256 为 `37535a8313cbb463efef560e7e87c36e60f528cc3e0263bf23fcd89f3a24b186`。当前运行器没有使用已撤回的配置措辞过滤，完整保留了 11 条候选；人工复核确认其中 5 条是新增共享内部令牌字面量 P1，另外 6 条是基于部署拓扑或未改变有效默认值的配置推测误报。

该提交的独立 scorecard 为 `gold=5`、`found=5`、`candidates=11`、`false_positive=6`、P0/P1 召回 100%。这只代表一个配置/凭据根因族，不能当作通用生产召回率；所有 11 条模型候选仍可在私有结果中查看，误报通过人工标签记录而不是静默过滤。下一步优先补充并发、权限、租户和对象生命周期等不同根因族的真实 holdout。

同一提交随后完成两轮重复审查：每轮 5 个分片、exit=0，耗时分别为 223 秒和 261 秒；两轮文本 `result_sha256` 都是 `37535a8313cbb463efef560e7e87c36e60f528cc3e0263bf23fcd89f3a24b186`。这只证明该配置留出的结果在耗时波动下稳定，不扩大通用代码审计的召回率分母。

同日补复核 `platform-file:bc14e16`：原始模型 32 秒返回 clean，但人工确认 `COMPUTERNAME` 在 macOS/Linux 上可能回退固定集群名，破坏本机 Nacos 集群隔离。新增窄范围跨平台配置预检后，复跑以 exit=0 输出唯一一条 P2（`src/main/resources/application-localhost.yml:16`），结果 SHA-256 为 `580c568d367cc5b22b1c32bcd99dba509f22afa5540b81aa89fd9fec11840896`；同一预检与模型的重复段落也已归一化去重。该样本只有 P2，故不进入 P0/P1 召回分母，但作为真实模型漏报和兼容性回归保留。

该规则变更后的 `SYNTHETIC_REVIEW_RUNS=1 ./evals/run-synthetic.sh` 通过：7 类正例全部命中、4 个 clean 对照通过，截断路径显式失败；预检、分片、scorecard、标签迁移和运行态校验快速门禁也全部通过。

同时完成跨服务 `platform-gateway:052b848` clean holdout 人工复核：workflow 路由绑定和租户授权测试与现有 Nacos 路由契约一致，当前结果完整 clean，scorecard `gold=0`、`candidates=0`。该样本只增加跨服务 clean 覆盖，不增加 P0/P1 召回分母。

另完成人员状态同步提交 `platform-hr-service:51709d1` 的人工 clean holdout：`active` 到 `ACTIVE/INACTIVE` 的变更与现有 `active(null)=true` 兼容语义一致，新增测试及 `mvn -q -Dtest=DirectoryImportTransactionServiceTest test` 通过，模型结果 clean，scorecard `gold=0`、`candidates=0`。该样本补充状态生命周期覆盖，不增加 P0/P1 召回分母。

再完成 `platform-integration:fd0f1c4` 重试/限流 clean holdout：新增 QPS/暂时限制文本判定与 HTTP 429、指数退避和权限错误不可重试的现有契约一致，`mvn -q -Dtest=HttpDingTalkApiTest test` 通过，模型结果 clean，scorecard `gold=0`、`candidates=0`。该样本补充外部调用可靠性覆盖，不增加 P0/P1 召回分母。

同日继续复核发布服务更近的提交 `platform-publishing-service:129a244`：该提交新增印刷页标、重复表头配置，并同步质量报告、问题证据和页级复核链路。当前个人 profile 连续两次完整结束（均 exit=0，均返回 clean），未出现截断、空响应或路径定位失败；人工逐文件检查确认新增字段在确定性执行器、持久化同步、查询 VO 和示例契约之间保持一致。`TypesetEvidenceApplicationTest`、`DeterministicTypesetExecutionHandlerTest`、`TypesetProfileApplicationTest` 和 `ProfileExamplesContractTest` 均通过（仅有 Mockito/Byte Buddy 动态 agent 警告）。该样本补充了跨服务、跨时间的 clean 稳定性证据，但没有新增已确认 P0/P1 根因，不计入召回率分母。

文档提交 `2bf483b` 推送后又执行一次完整合成门禁：7 类正例均 exit=0 且各命中 1 次，4 个 clean 对照均无问题，所有响应完整，`num_predict` 截断路径按预期显式失败。该复跑只验证公开仓库、全局入口和本机 tuned 模型仍处于同一规则版本，不改变阶段 1 的真实人工标签分母。

随后补充跨仓库登录路由留出 `platform-gateway:7592b4d`：提交只在三套 Nacos 配置中新增 `/mobile/login` 到认证服务路由和白名单；显式附带 `platform-auth` 的移动登录控制器与 Spring Security 配置后，个人 profile 两次均完整返回 clean。第一次默认 16K 窗口按预算门禁拒绝发送（固定提示词 11362/11264），没有静默截断；仅对该次把 `OLLAMA_REVIEW_NUM_CTX` 提高到 32768 后两次均成功。网关 `AiGatewayRouteContractTest`、`SaTokenAuthGlobalFilterTest`，以及认证服务 `LoginServiceImplTest`、`LoginControllerTest`、`SystemLoginSecurityIntegrationTest` 均通过。该样本补充跨服务认证路由覆盖，不增加已确认 P0/P1 根因；它也验证了跨仓库上下文应按需扩大窗口，而不是降低完整性门禁。

随后复核 `platform-integration:18ea173` 的 HR 目录下游失败传播：变更为批次创建、分片上传和批次完成统一保留下游错误码与消息，并显式附带 `platform-api` 的 `HrDirectoryClient` 契约上下文。个人 profile 两次均完整返回 clean；`HrDirectoryPublisherTest` 通过。该样本补充外部调用错误处理和跨仓库契约覆盖，不增加已确认 P0/P1 根因。

继续复核 `platform-hr-service:c54baaf` 的内部人员树查询：提交新增组织树、当前有效任职挂载、关键词裁剪和账号状态范围；个人 profile 两次均完整返回 clean，分片预算在固定提示词较大时自动收紧到 2616 字节。人工核对确认人员查询最终进入带租户条件的 `HrPersonMapper`，并通过 System-HR 的 ACTIVE employment 范围限制可见账号；`HrPersonnelDirectoryApplicationTest`、`HrControllerContractTest` 通过。该样本补充人员目录的租户、状态和容量边界覆盖，不增加已确认 P0/P1 根因。

随后把真实提交 `platform-file:7eb92a1` 重新放回其父提交快照做正式留出（避免误把后续 HEAD 的配置一起纳入）：当前 tuned profile 精确报告 `nacos-config/platform-file-localhost.yml:98-99` 的 OSS 凭据字面量，人工按同一泄漏根因聚合为 1 条 P1，scorecard 为 `gold=1`、`found=1`、`candidates=2`、`false_positive=0`、完整运行 50 秒。两轮历史重复审查均 exit=0，文本 SHA-256 同为 `8ac50a65fd723a73b481ad3f764c5e60902922a12eae16e6425443006d5581ca`，重复门禁通过。该样本增加一个真实 P1 根因，但仍属于已有配置凭据族，不代表通用代码审计召回率。

## 2026-09-24 进展：补充跨服务超时与调度关闭 clean 留出

为避免真实 holdout 只集中在配置凭据族，新增两个不同运行边界的提交并按各自父提交快照审查：`platform-integration:d7cda2c` 调整 HR 批次完成阶段的读取超时和直连地址，个人 tuned profile 43 秒完整返回 clean；`platform-hr-service:4d5e974` 允许关闭 XXL-JOB 客户端时仍保存待注册生命周期动作，37 秒完整返回 clean。两份人工 scorecard 均为 `gold_p0_p1=0`、`predicted_candidates=0`、`false_positive=0`，因此不虚增 P0/P1 召回分母。

`d7cda2c` 随后完成两轮历史重复审查，均 exit=0、结果 clean，重复门禁通过；两轮耗时不同但候选集合和运行签名稳定。当前 tuned profile 也重新执行了 1 轮完整合成门禁：7 类正例均命中，4 个 clean 对照通过，截断路径显式失败。新增证据只扩大了跨服务和生命周期 clean 覆盖，仍不能替代至少 20 个经人工确认且包含多种真实 P0/P1 根因的独立留出集。

## 2026-09-24 进展：保留删除文件发现并补齐触发器迁移预检

大提交 `platform-hr-service:a8bf560` 的完整个人 profile 复核在 `num_ctx=32768`、9KB 分片下 exit=0；模型候选包含 1 条真实 OSS/内部令牌 P1，但人工还确认迁移脚本中 `DROP trg_hr_employee_event_forbid_delete` 与 `CREATE hr_projection_outboxtrg_hr_employee_event_forbid_delete` 名称不一致，原始 scorecard 为 `gold_p0_p1=2`、`p0_p1_found=1`、`predicted_candidates=19`、`false_positive=6`，即 1/2（50%）召回。另一次 15KB 分片尝试在第 16 个分片连续超时，按 fail-closed 处理，不计入 scorecard；这再次证明扩大分片不能作为默认提速手段。

为避免模型对已删除文件给出“真实路径但无当前行号”的信息时整次结果失败，输出门禁现在只对确实已删除的路径允许缺省行号，现有/未跟踪文件仍要求可验证行号；新增配置留出回归为 8/8。新增窄范围 SQL 触发器预检：同一 SQL 文件中 DROP/CREATE 名称仅差前后缀且至少一侧为新增行时，直接报告重放失败 P1；正负夹具已通过。对 `a8bf560` 的失败诊断已确认该预检准确定位 `sql/hr_assignment_history_integrity_upgrade.sql:33`，但由于完整模型重跑超时，尚未把修复后的结果替换为正式 scorecard。

当前 tuned profile 重新执行 5 轮完整合成门禁仍通过：7 类正例全部 5/5 命中、20 个 clean 对照全部通过，五轮输出哈希稳定，截断路径显式失败。上述修复提高了“发现必须可见”和迁移类高置信证据覆盖，但阶段 1 仍不能宣称达到生产级高可用，真实 P0/P1 留出分母需要继续扩大并避免同一凭据族重复计数。

## 2026-09-24 进展：安全修复反例暴露稳定误报

真实 `platform-file:2e33eaf` 将三套 Nacos 配置中的 OSS 字面量替换为环境变量占位符；个人 tuned profile 完整返回 3 条 P1，但三条都错误地声称旧凭据“未被删除”。人工 scorecard 为 `gold_p0_p1=0`、`predicted_candidates=3`、`false_positive=3`，没有把它误算成召回率；两轮重复审查均 exit=0、结果稳定，重复门禁通过。当前不使用没有证据的关键词过滤静默删除这些候选，而是保留全部输出并把误报记录进 scorecard；下一步要用更多“安全修复/删除敏感信息”反例判断是否需要增强 diff 语义提示。

## 2026-09-25 进展：二十提交双跑稳定性与诊断隔离

修复历史评测运行器的标准输出/标准错误混流问题：成功审查只将标准输出作为可评分结果，传输重试和其他诊断信息另存为私有 `.stderr.log`，并在 metadata 中记录哈希；失败运行仍保留两条流且以非零状态 fail-closed。`test-history.sh` 已覆盖该行为；`run-history-repeat.sh` 的签名忽略耗时及诊断日志元数据，但仍严格比较结果内容、退出码、分片状态和运行配置。

修复后，当前 tuned profile 对 `platform-api` 历史清单 20 个提交完成两轮复测，40/40 次 exit=0，重复稳定性门禁通过。人工把同一根因聚合后，scorecard 为 `gold_p0_p1=3`、`p0_p1_found=3`、P0/P1 召回 100%、`predicted_candidates=12`、`false_positive=9`，所有结果完整。该分母只有 3 个独立 P0/P1 根因，不能外推为生产高可用；`cbe47ea0` 的 8 条误报和约 308 秒尾延迟仍需优先优化。

同日生成私有跨项目聚合：追加 `platform-file:a9a1d4a` 对象删除、`platform-file:896dca8` 迁移删除和 `platform-hr-service:a8bf560` 令牌/触发器两个 P1 根因后，共 23 个完整提交，`gold_p0_p1=7`、`p0_p1_found=7`、`predicted_candidates=28`、`false_positive=19`、`incomplete_runs=0`。前 20 个提交、a9 和 896 已完成双跑稳定性；a8 只有一次完整复测，因此该聚合只证明当前人工样本的发现率，不证明全部样本稳定，更不等于生产级 90% 召回率。

2026-09-26：为降低大提交分片中的跨文件上下文丢失，运行器在需要分片时建立一次受限 Java 符号文本索引，并按精确 `diff --git` 路径把 `@Data`/配置注解和 `require*` 匹配计数注入对应分片。证据明确标记为文本匹配，预算不足时可跳过，不影响分片审查和 fail-closed 门禁；新增无模型跨文件夹具已接入 `test-sharding.sh`。完整确定性回归、运行态校验和五轮合成门禁均通过；`cbe47ea0` 两次复跑均为 8 片、27～55 秒 clean，`420ae70c`、`a1284658`、`63d520b` 的已知 P1 根因均保留。该优化改善可用性和尾延迟，但不扩大 23 个样本、7 个确认 P0/P1 根因的统计，也不改变“尚未达到生产级高可用”的结论。

2026-09-27：根据历史 `cbe47ea0` 的 Lombok/安全失败误报证据，系统规则明确将 `@Data` 等编译期生成成员和 `requireInternalToken()` 的 fail-closed 语义视为可验证上下文，并新增 `java-lombok-properties-safe` clean 回归。新增查询令牌宽范围重复定位回归，聚合层现在在同一文件已有确定性精确位置时保留精确调用行，仍保留不同调用点和独立根因。合成门禁还暴露预签名票据竞态在模型侧偶发漏报；新增窄范围对象存储预检，仅在有效票据、终态前删除同一 objectKey、活动态清理且无撤销证据四项同时成立时补充 P1。随后又为明确标注服务已有数据库的版本化迁移删除增加确定性 P1 预检，并按文件/行号过滤模型重复复述；独立 SQL、权限和并发根因仍保留。当前五轮合成门禁已验证 7 类正例各 5/5 命中、5 类 clean 共 25/25 通过，所有输出哈希稳定，截断失败路径显式失败；完整确定性回归与运行态校验也已通过，真实阶段 1 分母不因这些合成样例扩大。

2026-09-27：用当前运行态对真实 `platform-api:cbe47ea0` 做了重新审查和两轮重复审查。单轮 11 个分片、59 秒、exit=0、`output_complete=true`，结果为 `未发现阻塞问题`；两轮重复审查均 clean、exit=0，完整结果哈希与运行签名稳定。该提交此前曾稳定产生 8 条 Lombok/安全/查询令牌误报，本轮在不关闭全量输出门禁的前提下全部消失。这是一个真实 clean 误报簇的改善证据，不增加 P0/P1 召回分母，也不能单独证明所有代码类型都达到生产级高可用。

同日用真实 P1 `platform-api:63d520b` 发现个人 profile 默认 16K 上下文在固定规则和跨文件证据占用后无法发送请求，虽然确定性查询 token 预检已保留，但整次按 fail-closed 失败。将个人 `local-review-local` 默认请求窗口提升到 32K，并在分片输出过滤中加载当前变更文件及显式绑定的 `*Properties` 类来识别已存在的 guard、默认值和 `@ConditionalOnClass` 证据后，该提交以 32K、14 个分片、182 秒、exit=0 完整返回唯一真实 P1；原先的 properties/null/可选依赖误报全部移除。该结果证明高性能 profile 的默认预算和跨分片语义门禁都得到改善，但仍不扩大真实 P0/P1 分母。

同日修复证据过滤器的路径边界：模型输出的仓库外路径不能再触发完整源码读取，必须先在当前 diff 路径索引中存在才允许加载。无模型路径安全回归和完整 CI 均通过；个人 profile 五轮合成结果仍稳定。该修复降低了恶意/错误模型输出导致本地文件泄漏或误过滤的风险，不改变真实 finding 的人工统计。

随后补齐符号链接边界：当前变更路径的最终文件或任一目录组件是符号链接时，过滤器不再加载其目标作为完整源码证据，行号校验也不跟随链接读取仓库外内容；报告本身仍经过路径和差异定位门禁。changed-symlink 夹具、完整确定性回归、`git diff --check` 和运行态 SYSTEM 校验均通过。

路径安全补充：当前变更路径的最终文件或任一目录组件是符号链接时，过滤器及依赖完整源码快照的确定性预检不再加载其目标；Git 路径索引使用 NUL 安全解析，换行/回车、绝对路径和父目录组件会 fail-closed。仓库内 `AGENTS.md`、README 和显式 `--context` 符号链接不会跟随读取外部目标；差异本身仍继续审查。changed-java-symlink、symlink-rules 和 newline-path 夹具、完整确定性回归、`git diff --check` 和运行态 SYSTEM 校验均通过。

2026-09-27：`bbc767a` 后使用当前 tuned 模型重新执行 `SYNTHETIC_REVIEW_RUNS=5 ./evals/run-synthetic.sh`，7 类正例全部 5/5 命中，5 类 clean 共 25/25 通过，所有结果 SHA-256 在五轮内一致，`num_predict=1` 截断路径显式失败。此次运行同时验证空/错误 `done_reason`、路径边界和锁扫描 fail-closed 改动没有削弱现有正负例边界；真实阶段 1 的人工 holdout 分母仍未因此扩大。

同日对真实 `platform-api:420ae70c` 在冻结父提交快照上做两轮当前审计器复核：两轮均 8 个分片、exit=0、`output_complete=true`，结果 SHA-256 同为 `0d1da3ce59fd07e72b6c6370a99082b7738e807af919a4695b8c0f83d3ed07fe`，完整保留 5 个缺失 DTO 位置并聚合为一个 P1 构建阻断。该结果确认路径/响应门禁修复未丢失真实多文件定位证据；它是既有根因的稳定性复核，不新增阶段 1 真值分母。

## 失败处理原则

2026-09-21 更正：上述 `f0b3bcb` 配置措辞过滤已撤回。独立回归发现“端口 70000 + 可能启动失败”等完整报告被静默转为 clean，非法路径/行号/缺字段也被过滤绕过校验；修复前 7 个用例中 6 个失败，移除过滤后 7/7 通过。此前过滤后候选减少不能证明精度提升，真实样本中的配置推测仍待独立核实。该组回归通过 `test-preflight.sh` 进入 CI 和合成门禁，不扩大模型召回真值分母。

任何 API 错误、空响应、超时或 `done_reason=length` 都算本次审查失败，不能把半截结果计入召回率，也不能用模型输出替代人工确认。

2026-09-27：根据真实 `platform-hr-service:a8bf560` 的人工复核，系统规则补充 Spring `Propagation.MANDATORY`、MySQL 生成列 `STORED/VIRTUAL` 和字典 `sort` 重排三类窄边界；新增生成列 clean 夹具。合成门禁首轮发现 `java-token-url` 偶发附带“标准库无需额外依赖”的非问题信息，导致文本哈希漂移；运行器现在只过滤这一类没有缺少/冲突/编译失败证据的泛化信息，不影响 P1 或具体兼容性问题。当前 tuned 运行态重新完成 `SYNTHETIC_REVIEW_RUNS=5`：7 类正例各 5/5 命中、6 类 clean 共 30/30 通过，所有输出哈希稳定，截断路径显式失败。该轮仍只验证稳定性与误报边界，不扩大真实人工 P0/P1 分母；规则和运行器改动尚未替代多样化真实 holdout。

同日对真实 `platform-hr-service:a8bf560` 重新执行冻结父提交复核，使用 9KB 分片以覆盖大提交路径：28/28 分片成功，`output_complete=true`，耗时 877 秒，结果完整保留 4 条候选（硬编码凭据 P1、触发器名称不一致 P1、ERP 内部路由契约 P1、租户条件 P2）。旧结果中的字典排序、生成列和事务边界误报不再出现；这只是一次真实回归和待人工确认的候选集合，不直接改写既有 scorecard。过程中还修复了 Git 默认八进制转义中文文件名导致的分片路径路由失败，并加入无模型中文路径回归。

随后针对上述 `HrPersonMapper.xml` 租户 P2 误报增加了窄范围证据门：`EXISTS`/子查询已可见 `inner.tenant_id = outer.tenant_id` 时，过滤“缺少租户隔离”的泛化段落；别名不一致、权限、SQL 注入或其他独立证据仍保留。该规则只放在确定性输出过滤和无模型回归中，没有再次写入 SYSTEM；尝试写入 SYSTEM 会让预签名票据夹具超过 180 秒无响应，回滚后旧运行态恢复到约 45–51 秒。当前 tuned SYSTEM SHA 保持 `bfc4993dec3bc0c45d3a81e4f7712c645971e65cbd63e6aafb5904226442d783`，五轮合成门禁重新通过。

同日重新复核 ERP 并发留出 `736ef178` 与 `7fee9f1a`：两份冻结父提交均完整结束，分别为 5/12 个分片、57/226 秒；确定性锁序预检各输出唯一一条反向锁序 P1，人工核对确认两条路径实际锁定同一退货/收货资源且顺序相反。两轮重复审查均 exit=0，结果文本、分片状态和运行签名稳定（耗时分别约 59/238–249 秒）。这把此前模型 clean 的两条并发漏报转成可见候选并补进真实根因证据，但仍按独立人工样本记录，不把合成门禁或预检候选直接冒充生产召回率。

随后将这两条人工确认的 P1 以独立私有阶段一标签登记：两行 scorecard 均为 `gold_p0_p1=1`、`p0_p1_found=1`、`false_positive_count=0`、`output_complete=true`、`repeat_stable=true`，同属 `lock-order-erp-sales-return` 功能簇并都放在 `holdout`。阶段一门禁对这组单独 scorecard 正确拒绝（仅 2 个提交、2 个 holdout 根因且没有 train/dev），因此它们增加了真实根因证据，但没有被冒充为已经达到 20 个 holdout 根因或生产级指标。

同日补充跨仓库真实提交探测：`platform-auth:711e742`（小程序登录）、`platform-integration:18ea173`（HR 发布失败）、`platform-system:db93e1d`（网关规则缓存自愈）均完整返回 clean，人工核对后不计入问题真值；`platform-job:ce7010c3` 的生产 bootstrap 新增两处 `${NACOS_PASSWORD:nacos}`，缺少环境变量时会回退公开默认密码，人工确认两条 P1 均成立。该提交两轮重复审查均 exit=0、文本 SHA-256 一致，私有阶段一 scorecard 为 `gold_p0_p1=2`、`p0_p1_found=2`、`predicted_candidates=2`、`false_positive_count=0`、`location_accurate=1`、`repeat_stable=true`，功能簇为 `config-prod-nacos-default`、split 为 `holdout`。

同一轮发现模型可能把仅含 `username: ${...:nacos}` 的配置行误报为硬编码凭据；新增窄范围证据门只过滤“用户名单独作为凭据”的段落，密码、token、secret 及独立安全根因继续保留，并加入无模型/伪模型回归。该门禁不修改 SYSTEM；五轮合成门禁仍保持全部正例 5/5、clean 30/30、输出哈希稳定和截断显式失败。

2026-09-27：对真实 `platform-dac-service:36da7ae`、`platform-workflow-service:beab22f`、`platform-publishing-service:908b633`、`platform-auth:d5317b6` 和 `platform-gateway:052b848` 做跨仓库 holdout 探测。当前 tuned profile 均完整返回 clean；人工复核确认 workflow 租户排序、PDF 页预览缓存、小程序手机号回传和网关工作流路由没有可由差异证明的 P0/P1。DAC 提交仍记录两条需要后续契约确认的 P2 候选：`DacDirectoryGateway.users(boolean includeDisabled)` 丢弃旧参数且 HR 目录固定只返回 ACTIVE，以及 `/dac/v1/sso/me` 同步依赖 HR 服务、无本地上下文降级；两者不计入阶段 1 P0/P1 分母，避免把有意的目录契约调整冒充安全根因。

同日发现输出过滤器的两个真实漏报边界：路径级租户条件会把同一 Mapper 中另一条不安全查询或已删除租户条件误当作安全证据；“缺少日志”降噪会吞掉结构化 token 明文日志 P1。修复为仅使用报告行号附近的当前源码窗口，并保留明确 token/凭据日志；新增 `evals/test-filter-evidence.sh` 五用例回归，覆盖混合查询、删除行、别名错误、token 日志和安全负例信息。无模型确定性套件与五轮合成门禁均通过，五轮正例/负例输出哈希稳定，截断失败仍显式保留。

### 2026-09-28：声明式权限注解回归预检与大差异预算修复

新加入的真实 `platform-erp-service:4451b5b24ab544fc7344182347a83158e93702b5`（父提交 `8a4223e993d7287acd18944e27bf188845d7351f`）把四个主数据控制器的 `@PreAuthorize` 全部注释掉。模型原始完整输出能发现授权回归，但会把同一根因拆成多条并附带“可读性/维护性”信息；人工将其聚合为一个 `erp-endpoint-auth-bypass` P1 根因。

运行器新增窄范围声明式权限预检：只对 diff 新增的 `//@PreAuthorize`、`//@RequiresPermissions` 或 `//@Secured` 注释行生成确定性 P1，按文件聚合并保留全部证据行；分片提示词省略这段重复证据，但最终合并阶段重新注入并过滤模型重复段，逗号分隔行号范围也纳入重叠判断。纯维护性信息不再作为 finding，租户、SQL、并发、凭据等独立证据不受影响。预检文本同时压缩，并从预算探测中排除，避免四个控制器的大提交在 16K 上下文下因固定提示词不足而 fail-closed。

真实复测使用 `num_ctx=16384`、3KB 分片、`num_predict=1024`：11/11 分片完成，`output_complete=true`，耗时 447 秒，最终稳定输出四条按控制器聚合的 P1，覆盖全部注解证据行；两轮重复为 398/441 秒，`run-history-repeat.sh` 通过，结果文本、模型/SYSTEM/脚本和分片签名一致。重复脚本同时修复了全角括号紧邻 shell 变量名导致的 `set -u` 误报。`evals/test-filter-evidence.sh` 现为 11 个用例，过滤、预检、分片和运行态回归均通过。

同轮探测的 `platform-job:730c1066`（完整补齐 `/jobgroup` 管理端点管理员注解）和 `c6a4df2`（完整转义调度日志 XSS 输出）均返回 clean；它们是正确修复，不计入漏报。当前仍未达到阶段 1 的至少 20 个独立 holdout P0/P1 根因、90% 召回/定位和误报率门槛；本轮只新增一个已人工确认的 ERP endpoint 授权根因。

2026-09-28 补充：历史评测 manifest 现在在运行与标签生成前拒绝控制字符、未转义 TAB/列数漂移、非法 commit/parent 和可形成路径穿越的值，并有 fail-closed 回归。ERP 幂等候选 `0e6006b` 的旧金标已纠偏：并发缺陷属于父版本，目标提交已加入 `FOR UPDATE`、`request_no` 唯一键和重复键处理；当前两轮运行均 clean 且稳定，不计入召回分母。存量数据库缺少迁移脚本是独立升级风险；`platform-job:cb1bd548` 因与另一运行并行造成分片超时，明确不计入指标，待串行重跑。

同日补充预签名长尾：当单文件差异唯一确定性根因为取消后重放预签名票据时，即使 Ollama 传输失败或输出长度截断，也只返回该确定性 P1；若出现第二个预检根因或独立模型安全证据，仍拒绝恢复。该窄恢复有传输/截断/正常响应回归，证据过滤回归为 11 个用例，正式模型 SYSTEM SHA 保持 `b2763a461e0d2a9f46175a11a3aa35a3163da321860a594887378ab63cd0fa65`。

受控 `num_ctx=16384`、`num_predict=2048`、关闭重试的五轮合成门禁已通过：7 类正例各 5/5、clean 30/30、预签名 5/5，哈希稳定；个人入口仍默认 32K，但一般 32K 资源超时不会被恢复为通过。

补充的真实 clean holdout：`platform-job:0885d7d8` 密码修改旧密码校验（2/2 分片、44 秒）、`platform-job:e5a84a1b` bigint 兼容性修复（1/1 分片、34 秒）、`platform-ai-service:ddc7b767` SSE 错误内容协商修复（3/3 分片、27 秒）。均完整结束并由人工确认是安全/兼容性修复，不增加阶段一 P0/P1 分母；原始结果与 scorecard 保存在私有评测目录。

跨仓库内部目录 clean holdout `platform-hr-service:6192b5e6` 也已完整结束（5/5 分片、82 秒）。README 与全局 GatewayAuthFilter 证明其内部 token/租户边界已有统一门禁，控制器无显式方法注解不单独构成漏洞；该样本 `gold_p0_p1=0`，重复审查因 Ollama 资源争用中止，稳定性不作通过结论。

会话重放候选 `platform-job:cb1bd548` 串行重跑仍未达到完整性：59 个分片前 30 个成功，第 31 个分片的模型行号超过 `application.properties` 实际末行，严格定位门禁使整次 `output_complete=false`。该结果保留为失败诊断，不纳入召回/稳定性指标，也不放宽行号校验。

真实 `platform-job:ae26cb0c` SSRF 留出审查完整返回 clean，但人工确认 `executorAddress` 请求参数直接进入 `NetComClientProxy`，gold=1、found=0。已新增窄范围 RPC 出站地址预检和无模型回归（证据测试 14 个用例），并为重复/长度截断增加同形状恢复；预检只覆盖同一变更控制器中可见的请求映射、地址参数与 sink 三元证据，不把普通地址变量升级为 SSRF。

最新脚本复跑该提交得到 5/5 分片完整结果（154 秒）：模型首片重复预检触发 length，但过滤后安全恢复，最终输出单条确定性 P1，`gold=1/found=1/predicted=1/false_positive=0/location_accurate=1`；第二轮 186 秒结果文本与运行签名一致，`repeat_stable=true`，一般截断仍失败闭门。

2026-09-28：真实 `platform-job:7687f3fc23715a59dd5c77c4c6c3c68bcce71528` 曾被初步标成 MyBatis SQL 注入漏报，但后续静态源码复核纠正了该标签：`executorTimeout` 是请求绑定后的 primitive `int`，父提交已有同类 `${executeTimeout}`，当前提交没有新增可证实的 P1。旧的两轮 clean 结果保留为正确基线；原始模型启发式误报不再作为金标。

运行器新增窄范围 MyBatis 原始替换预检：仅当 mapper XML 的新增 SQL 标量赋值使用 `${...}` 时确定性报告 P1，并在最终合并过滤相同行范围的模型重复；动态标识符、白名单和其它独立安全根因仍由模型结合上下文判断。无模型预检夹具、证据过滤、运行态 SYSTEM 哈希和完整语法回归均通过。该修复只覆盖可证明的原始赋值形状，不把一个样本外推为全部 SQL 注入召回；阶段 1 仍未达到 20 个独立 holdout P0/P1 根因与 90% 召回/定位门槛。

2026-09-30：将 `platform-job:7687f3fc23715a59dd5c77c4c6c3c68bcce71528` 固定到目标提交及其直接父提交后，用当前 tuned 运行器重新做了两轮 typed 复测，避免把后续 HEAD 的差异混入结果。静态源码证据确认 `executorTimeout` 为 primitive `int`，因此 `${executorTimeout}` 不是可由请求携带任意 SQL 的 P1；模型重复输出的旧启发式不能作为金标。运行器现只把“完整 Mapper 声明 + Java 数值 getter”作为模型提示线索，未知参数类型仍保持 fail-closed，模型输出的问题不会被该线索静默删除。两轮均完整结束且稳定；该纠偏降低确定性预检误报，不扩大阶段 1 召回分母，阶段 1 总体门槛未改变。

2026-09-30 阶段 1 验收审计：已有真实样本中，多数正例正是此前调优预检的来源，不能再作为最终未见 holdout 计算召回。下一步必须冻结当前运行器和 Modelfile，排除已用于规则设计的提交及同功能簇，重新选取至少 20 个跨仓库真实提交，双轮运行并完成人工 P0/P1、定位和误报标签；在新清单完成前，生产召回率保持“未验收”，不以合成门禁或调优样本替代。

同日稳定性复测发现：完整合成序列中的 `java-tenant-leak` 两轮都保留同一 P1、同一文件和行号，但模型自然语言标题不同，旧的整段文本 SHA 会误判为漂移。新增 finding signature 比较器，仅比较严重级别、文件/行号、风险族和 MyBatis 表达式；完整原始输出仍全部保存和展示，不做 finding 过滤。修复后两轮合成门禁为 46 个正例、44 个 clean 对照全部通过，截断路径仍显式失败。真实 holdout 的 `repeat_stable` 也应以该语义指纹为准，并继续人工核对完整结果。

同日继续收窄 MyBatis 类型边界：精确 FQN、实际 Java 数值 getter、完整源码扫描三项证据缺一不可；简单类名、字段声明、注释 getter、嵌套表达式、`<bind>` 和 `<foreach item/index>` 都保持 fail-closed。类型扫描在文件边界检查总超时，避免大仓库无限占用审查预算。模型重复过滤仅在同一确定性表达式全部覆盖时生效，模型段落中出现未覆盖的另一个 `${...}` 表达式会完整保留。类型边界回归 10/10、MyBatis 去重回归 6/6；阶段一独立真实 holdout 仍未完成。

同轮五轮合成门禁曾发现 clean 样例的非问题信息漂移：安全负例被解释成“安全边界规则”、未跟踪文件被要求 `git add`、合法生成列被解释为“需要确认”。这些段落现仅在明确“无需修复/影响无/合法”且不含独立安全或兼容性证据时过滤；凭据、SQL、租户、权限、构建和迁移问题继续保留。修复后最终门禁为 7 类正例各 5/5、6 类 clean 共 30/30、预签名 5/5，哈希稳定，显式截断失败；`evals/test-filter-evidence.sh` 为 16 个用例通过。
2026-09-28：完成 `platform-file:f6ce8f6efe6f76d388ed2eb475faa50639ab5e96` 硬编码配置凭据留出。当前脚本按 3000 字节有效预算路由为 6/6 分片，两轮均完整结束（193/243 秒），结果 SHA-256 一致；8 个独立 P1 金标全部命中且定位准确。12 个候选中 3 条是配置注释/导入/README 信息误报，数据库 `CREATE/USE` 名称不一致保留为待确认契约候选，不混入凭据召回。该样本 scorecard 为 `gold=8`、`p0_p1_found=8`、`predicted_candidates=12`、`false_positive=3`、`repeat_stable=true`，证明当前压缩分片没有牺牲这组配置凭据的发现，但不代表其他代码类型的通用召回率。

2026-09-28：真实 `platform-hr-service:a8bf560e39d7bee93d9b0791dd37af9661490c47` 的 9KB 分片在第 15 片连续三次 180 秒无响应，严格记录为不完整失败；改用 6KB 有效分片后，32K 上下文、单并发双跑完成 44/44 分片，耗时 1491/1442 秒，结果和运行签名稳定。两个人工 P1（硬编码 token、触发器名称不一致）均命中且定位准确，第三个 schema 快照删除候选为误报；scorecard 为 `gold=2`、`p0_p1_found=2`、`predicted_candidates=3`、`false_positive=1`、`repeat_stable=true`。该样本证明小分片改善完整性，但长提交仍有约 24 分钟/轮的尾延迟。

同日为运行器加入本机 Ollama 并发锁并通过无模型回归：多个终端同时审查时后启动者 fail-closed，避免资源争用被误判为模型漏报；孤儿锁仅在严格校验后回收，不改变审查内容或 finding 可见性。

2026-09-28：补充独立并发根因 `platform-erp-service:736ef17845a9a45e55a262d6d64ea81738773059`。人工金标为事务锁顺序反向导致的潜在死锁 P1；当前运行器两轮 5/5 分片完整，102/63 秒，结果哈希一致，1/1 命中、定位准确、0 误报，`repeat_stable=true`。

同日补充 `platform-system:db93e1d23569727432fcde5e07b28719c0c5310f` 网关缓存自愈 clean 负例。两轮 6/6 分片完整，31/32 秒，输出哈希一致且无候选；人工未确认 P0/P1，作为 `gateway-cache-self-heal` holdout 负例，防止把受控缺失缓存修复误报为授权或租户隔离问题。

同日串行重试 `platform-job:cb1bd548a6d9512aab6f1ba9c5686de62f863fcd` 登录认证/权限迁移大提交：首轮大分片连续无响应并严格失败；1.5KB 分片、2048 输出预算下 130/130 分片完整结束，耗时 1804 秒，保留 job-group 授权缺口候选但共输出 18 条、包含重复与迁移推测。该结果尚未双跑或完成人工根因归并，只作为完整性/长尾诊断保留，不计入阶段一指标。

2026-09-29：继续补充公开合成根因覆盖。新增路径遍历、SSRF、命令注入和危险反序列化的 Java 正/负夹具；危险反序列化同时增加窄范围确定性 P1 预检，仅在同一文件可见新增 `ObjectInputStream/readObject`、`HttpServletRequest` 和请求输入流时触发，并过滤同根因模型重复，安全 `getReader()` 负例保持 clean。当前串行五轮门禁为 11 类正例各 5/5、10 类 clean 对照 50/50、预签名 5/5，所有 finding/body 哈希稳定，截断和不完整响应仍显式失败；无模型预检、路径安全、历史、分片、并发锁和运行态校验全部通过。此前仅返回“信息”级的反序列化探针未直接作为标签，修复后才纳入正式门禁。该批公开夹具只证明稳定性与窄证据边界，不扩大真实阶段一人工 P0/P1 分母；真实生产验收仍要求至少 20 个独立 holdout 根因、90% 召回/定位和受控误报率。
2026-09-29：继续补充三组不同根因的公开正/负样本：MyBatis 标量 `${...}` 原始替换 SQL 注入、HTTP XML 默认解析 XXE、以及有当前用户/租户上下文却按裸对象 ID 查询的 IDOR。模型单轮对 XXE 和 IDOR 漏报、对 SQL 预检重复复述，已分别加入窄范围确定性 P1 预检和同根因去重；多个同一行 SQL 表达式仍按表达式各保留一条。SQL 安全负例使用 `#{...}`，XXE 负例显式禁用 DOCTYPE/外部实体，IDOR 负例使用 `findByTenantIdAndId`，三组安全负例单轮均 clean。预检回归与证据过滤回归通过，最终五轮门禁为 14 类正例 70/70、13 类 clean 对照 65/65、预签名 5/5，哈希稳定且截断显式失败；真实阶段一仍需独立人工 holdout，合成结果不作为生产召回率证明。
2026-09-29：继续补充开放重定向、通配符 Origin + credentials 的 CORS、MD5/SHA-1 弱密码哈希三组正/负样本。开放重定向为模型漏报，CORS 为低等级泛化误报，弱哈希出现过格式不完整；对应窄范围确定性预检、安全对照和单根因 fail-closed 回退已加入。完整五轮门禁目标更新为 17 类正例、16 类 clean 对照；合成结果仍不作为生产召回率证明。
2026-09-29：继续补充 fail-open 授权异常、共享状态 check-then-act 竞态、事务外部支付部分成功三组正/负样本。模型存在漏报或不稳定识别，新增窄范围确定性 P1 预检；异常默认拒绝、AtomicBoolean 和 pending/outbox 对照均保持 clean。单轮全量门禁为 20 类正例、19 类 clean 对照；仍不作为生产召回率证明。

### 2026-09-30 当前公开合成门禁

新增 MyBatis 标量 `${...}` 原始替换、URL `startsWith` 白名单前缀绕过、声明式权限注解删除/注释三组正/负夹具。个人 tuned 入口单轮完整运行通过：23 类正例、22 类 clean 对照，预签名回退通过，显式截断失败；MyBatis 两个独立表达式保留为两条 finding，URL 前缀同文件/行号重复仅保留一条，独立文件/行号和独立 SQL 根因不被隐藏。`test-preflight.sh`、`test-filter-evidence.sh`、URL 去重 7 个边界用例、路径去重 3 个边界用例、分片/历史/scorecard/运行态回归均通过。

这些公开夹具只证明窄范围证据门、输出完整性和稳定性，不能替代阶段一真实人工 holdout。当前仍未满足至少 20 个独立 holdout P0/P1 根因、90% 召回率与定位准确率、受控误报率的生产验收条件。

### 2026-10-01：Reactor 鉴权异常放行与行号校验阻塞修复

跨仓库冻结留出显示，网关权限方法中的 `onErrorResume`/`defaultIfEmpty` 可能把依赖异常或空规则转成 `true`，形成 Reactor 版 fail-open。运行器新增窄范围预检：仅对当前新增的 `Mono.just(true)` 或 `defaultIfEmpty(true)` 进行检查，并要求同一当前源码方法同时出现 `Mono<Boolean>`/Reactor 证据和认证、权限或安全上下文证据；匿名判断、功能开关、默认 `false` 和 `Mono.error` 保持不触发。结果标记为确定性代码证据，模型原文仍完整保留。

同轮修复了行号范围校验在终端等待 stdin 的问题：`awk` 从显式路径/行数文件加载完数据后立即退出。新增边界夹具验证两个 Reactor 形状各发现一次、两个安全 fallback 不误报；预检、输出可见性、证据过滤、历史 fail-closed、分片路由和运行态测试均通过，完整五轮合成门禁保持 23 类正例 115/115、22 类 clean 对照 110/110、预签名 5/5，截断仍显式失败。

阶段一冻结留出目前有 21 个跨仓库候选提交；auth、system、gateway、common、ai 已完成双跑且输出完整、结果稳定。AI 大提交每轮约 20 分钟，并重复报告同一删除文件的 P1，记录为待人工归并的模型候选，不直接当作独立根因。ERP、publishing 和 MCP 仍需串行双跑与人工标注；在至少 20 个独立人工确认 P0/P1 根因、定位准确率和误报率达到阶段一门槛前，不宣称生产级高可用。

本轮实际完成的有效双跑已扩展到 21 个独立提交：跨仓库 auth、system、gateway、common、AI，加上 ERP 和 MCP 的多组独立功能簇。当前结果均保存于本机冻结评测目录；gateway `b25b85bd` 使用最新 Reactor 预检后稳定输出两个确定性 fail-open 位置，模型重复段仍完整保留，人工汇总时按同一根因归并。两个超大 publishing 提交和 ERP `2ff8080d` 因长尾/预算不足未完成，严格排除出通过统计；它们作为日常高可用延迟边界记录。

阶段一还剩人工标注和门禁计算：逐提交确认 P0/P1 真值、误报、行号准确率和功能簇 split，建立 train/dev/holdout scorecard，并在至少 20 个 holdout 根因达到召回、定位和误报阈值后再宣称完成。模型 clean 输出不能替代人工审计，空结果或不完整运行也不计入分母。

2026-10-01：新增“删除文件边界”规则，修正 AI 知识提交中“删除旧过滤器即必然导致运行时错误”的误报。删除文件只有在当前差异、显式 context 或确定性预检展示仍存在的仓库内引用、注册入口或兼容契约时才可报告；模型原文仍完整保留，不通过静默过滤掩盖其他独立问题。`test-preflight.sh`、输出可见性、证据过滤、历史 fail-closed、分片路由和运行态回归均通过。该规则还需在新的冻结提交上重跑并纳入人工误报率统计。

同轮构建阶段一 scorecard 时发现模板说明行与真实元数据使用同一键名，旧解析器会把“人工填写……”当成值并静默跳过全部标签；现已改为只接受合法枚举/slug/数字值，并新增模板说明行回归。21 个稳定双跑结果已成功汇总；当前严格门禁真实失败于 holdout 只有 1 个已确认 P0/P1 根因且 AI 删除误报使误报率超阈值，不能把这次失败包装成通过。

### 2026-10-01：修复预检输出块与混合清洁协议

XXL-JOB 确定性预检原先用多个带空行的 `printf` 参数写入同一 finding，导致统一的来源标记被误插入字段之间，破坏问题块边界和重复签名。现改为一次写入完整的四字段问题段，并新增回归确保两处可空证据各自产生一个完整 P1。模型输出协议同时明确：只要存在任意 P0-P3 或信息问题，就不得再附带“未发现阻塞问题”等 clean/总评段；运行器继续对缺字段或混合结果 fail-closed，不静默删除模型原文。该修复通过 `test-preflight.sh`，但不改变阶段一真实 holdout 分母；仍需补足至少 13 个独立 P0/P1 根因并完成最终门禁。

同日真实 `platform-job:c071a63f14db68f77799755c84a1d2502b861d45` 在冻结 runner 上完成两轮复测：两轮均完整结束、各 1 个分片，结果 finding signature 和结果 SHA 一致，模型原生 P1 与确定性 `ReturnT.msg.length()` P1 均可见。模型曾附带“文档与代码一致”的信息段；该无修复内容现由窄范围证据过滤移除，`test-filter-evidence.sh` 扩展为 22 个用例。该样本计入稳定性与漏报修复证据，但仍需按独立人工标签决定是否更新正式阶段一分母。

同日重跑 `platform-auth:9dbcc0c5af1b11b514ff92a08d8bfb63d3ff6c95` 两轮均完整稳定，原有 URL 查询令牌 P1 命中；人工已确认 `OnlineUserVO.token` 经仓储直接回填并由在线用户接口返回的第二个 P1。新增窄范围预检要求 DTO token 字段、`setToken(token)`、OnlineUserVO API 返回型三段证据同时可见，避免把普通 header 传递或脱敏标识误报为凭据暴露。该规则先通过无模型夹具回归，待当前 runner 提交后重跑真实样本再更新正式 scorecard。

同轮 `platform-job:5dfc6a1092ae8131db160d23323dca33f7501ad8` 的 66 分片复测在第 16 片因 Ollama 超时而 fail-closed；确定性预检已保留 7 个可空 `getJobParam()` 位置，但这次不完整运行不计入召回或稳定性，记录为大提交长尾容量边界。

随后为 `platform-erp-service:559275841648667c5fce19b0048e721df73ebdae` 增加窄范围供方归属预检：只有 `SalesStockSearchApplication.resolveTargetWarehouse` 新增逻辑仓 `findById`、同一源码存在寻货实体供方字段、且 resolver 内没有供方一致性校验时才生成 P1。该预检已通过无模型边界夹具，普通逻辑仓查询不触发；真实大提交需在可完整结束的分片预算下重跑，未完成运行仍不计入阶段一指标。

同轮修正该预检只从方法声明建立 resolver 范围，避免把调用点后续的 `entity.getSupplierId()` 错当作目标仓归属校验；完整 `test-preflight.sh` 重新通过。

system 角色/API 真实复测又暴露一个共性协议缺陷：角色/API 确定性预检也曾用多段 `printf` 写入，来源标记插入后使完整问题段被拆开。现已改为连续四字段写入，并增加字段计数回归；此前 system 运行的 41/41 分片结果因输出不完整而作废，修复后必须重新双轮验证。

修正后对真实 `platform-erp-service:559275841648667c5fce19b0048e721df73ebdae` 使用 6000 字节有效分片预算完成两轮复测：20/20 分片均完成，确定性供方归属 P1 稳定出现，结果签名一致；两轮耗时约 283/326 秒。该样本的原始 3000 字节配置曾出现长尾失败，因此 6000 字节只作为该大提交的受控留出配置，不改变个人入口默认预算。

2026-10-02：角色/API 预检块修复后，真实 `platform-system:ecc8d75eaf63596eb33574968b63e7649922dee1` 使用 6000 字节分片与 4096 输出预算完成双轮复测。两轮均 41/41 分片、`status=completed`、`output_complete=true`，耗时 794/728 秒；结果 SHA-256 和 finding signature 均为 `6235907a3a77f8fe2b8ae14818e5be8d63b1b44fb8cfe0bc49568ba5f38c439e`。确定性角色/API P1 的影响、修复建议、验证方式均在完整问题块中可见。此前多段写入造成的不完整结果和长度截断结果均排除，不计入阶段一指标。

当前剩余验收步骤：人工归并新真实结果并更新冻结 scorecard；对 `platform-job:5dfc6a1092ae8131db160d23323dca33f7501ad8` 长尾样本完成可完整双跑，或保留为明确容量边界；再用至少 20 个未参与规则设计的真实 holdout 根因完成双跑、定位准确率和受控误报率门禁。上述门禁完成前，保持“核心链路已修复、生产级高可用尚未验收”的结论。

同日按修复后的双跑结果重算本机私有 scorecard：7 个已确认 P0/P1 根因命中 6 个，召回 85.7%；holdout 分母不足且误报约 14.3%，不能据此宣称生产级高可用。剩余缺口是至少 13 个未参与规则设计的独立真实根因、双跑结果、定位准确率和人工误报标签。

随后对 `platform-job:5dfc6a1092ae8131db160d23323dca33f7501ad8` 使用 6000 字节分片与 4096 输出预算完成双跑：两轮 31/31 分片、539/561 秒、`output_complete=true`，结果 SHA-256 和 finding signature 一致。`getJobParam()` 确定性 P1 与模型原文均可见；其余重复空值段和受保护分支候选暂不折算为独立根因，等待人工误报/归并标签。

2026-10-02：真实复核 `platform-system:ed790b4186d24992e21011adcfdd1ae746679a0b7` 时确认新增 DAC/Workflow SQL 含固定 `client_secret`，模型原始双跑均 clean。新增窄范围 SQL 凭据预检，仅在新增 `.sql` 语句同时出现 `client_secret` 列上下文和带 `secret/password/token` 特征的引号字面量时报告 P1，`${...}` 占位符不触发；无模型回归覆盖固定字面量正例和占位符负例。修复后两轮 17/17 分片完整（169/139 秒），两个位置的确定性 P1、finding signature 和结果哈希均稳定。该样本中的两个值属于同一固定凭据暴露根因，正式分母仍需人工归并，不能按输出条数虚增召回率。

2026-10-02：复核 `platform-erp-service:cd6599ca85db62659e877c2cec0ff9059e305abc` 购物车提交时确认，差异文档/DTO 将 `retailerId/storeId` 定义为实时取价上下文，但实现直接以 SKU 基础 `retailPrice` 生成成交价，未展示价格等级解析。模型双跑均 clean；新增窄范围价格预检要求契约文本、购物车应用类、基础价格赋值和缺少价格解析同时成立。无模型回归和真实双跑均通过，真实运行 17/17 分片完整（158/128 秒），确定性 P1 稳定定位到 `setSalePrice`，结果哈希一致；正式分母仍待人工标签。

同日尝试评测 `platform-erp-service:31bcd68e6403860e339ce16bca0042dca6d25b02` 库存调整/非实物调拨大提交。该提交约 3,000 行、34 个分片，首轮多片进入 180 秒长尾，主动停止并保留 trace；运行不完整，严格排除出召回、稳定性和 clean 统计，后续只能以专门大提交配置完整双跑后再纳入。

2026-10-02：复核 `platform-erp-service:c6df653f25bef50b480354cd6ea619c8e3f0700f` 直采寻货提交。个人 tuned 双跑均 10/10 分片完整，93/55 秒，结果 SHA-256 均为 `9043c1d8899cc7ef049a89d5479222a70d063233af3789eea83f6bf64b193bb6`；稳定报告一个供方-目标仓隔离 P1，定位到 `SalesStockSearchApplication.java:371`。新增预检覆盖 `resolveTargetWarehouse` 与 `resolveDirectTargetWarehouse` 两种方法名，并通过普通仓库查询 clean 负例。该真实根因等待人工标签归并后再进入正式 scorecard。

同轮复核逻辑仓 SKU 提交 `platform-erp-service:fb8a35780b64c8aca9df569f20071869b45f0ef2` 为稳定 clean；目标提交尚未出现后续 `occupiedQuantity` 字段，故不把后续状态证据倒灌到历史金标。当前代码仍保留占用明细替换防回归预检，但该提交不计入 gold 分母。
2026-10-02：复核 `platform-erp-service:dbeb99f` 退货创建并提交接口时发现幂等竞态：租户级 `request_no` 唯一键存在，但 `createAndSubmit` 在普通 `findByRequestNo` 后直接插入，没有 requestNo 锁或唯一键冲突恢复；不同订单并发复用同一 requestNo 时后一请求可能返回未处理数据库异常。新增窄范围确定性 P1 预检和带锁/重复键恢复负例，`test-preflight.sh`、历史回归、证据过滤回归均通过。该提交作为调优来源候选记录，不直接计入最终未见 holdout；当前正式门禁仍剩至少 13 个独立真实 P0/P1 根因、双跑、定位与误报标注。

2026-10-02：复核 `platform-erp-service:4451b5b24ab544fc7344182347a83158e93702b5` 权限回归提交。四个 ERP 管理控制器把原有 `@PreAuthorize` 注解全部注释，确定性预检稳定报告 P1；个人 tuned 入口两轮均 9/9 分片完整，耗时 258/238 秒，结果 SHA-256 均为 `f8a9553425cdc8298831f3f660a5fb1c6b2bdd65d7f9e6be92c0806be411c6f9`，finding signature 通过。模型原文仍按“所有发现可见”契约保留，重复性校验只在私有签名中按严重度、位置、风险族和 MyBatis 表达式归一化同根因的重复措辞，并把“迁移到新的授权机制”与真实数据库迁移区分，避免稳定性门禁被措辞漂移误判。该提交作为新增独立真实 P1 候选，正式 scorecard 仍需人工归并；当前阶段一仍剩至少 13 个未参与调优的独立根因。

按人工归并规则将该提交记入私有冻结 scorecard 后，当前完整样本为 27 个，已确认 P0/P1 根因 8 个，命中 7 个，召回率 87.5%；已有 1 个误报，按 `FP/(gold+FP)` 计算约 11.1%。这比上一版更接近门槛但仍未达到 20 个根因、90% 召回和 10% 误报上限，因此剩余缺口更新为至少 12 个独立未参与调优的真实根因，并继续要求双跑、定位准确率和人工误报标签。

2026-10-02：`platform-dac-service:36da7ae82210d586ebcd3040930c21caaa87ec2f` HR 目录迁移提交已完成个人 tuned 双跑，24/24 分片均完整，耗时 625/628 秒，结果和 finding signature 稳定为 clean；未确认 P0/P1，因此不增加阶段一召回分母。人工复核保留一个待确认的 P2 契约线索：旧 `includeDisabled` 选项可能在新 HR ACTIVE 过滤中失效；在契约明确前不计入正式门禁。

2026-10-02：对真实 `platform-auth:b7fa4c0ed26c9ef711956f47daca3daa36a710a2` 做冻结双跑。源码确认 SSO 授权码兑换在 `SsoController.java:238` 先 `redisUtil.get` 后 `redisUtil.delete`，后续修复提交 `60aab92` 改为原子 `getAndDelete`；该根因作为当前规则调优来源，不重复计入正式 holdout 分母。运行器新增窄范围一次性授权码消费预检，并以发放/消费方法窗口区分同文件的两个 key 行；正负 fixture、完整 `test-preflight.sh` 和相关回归均通过。修复后的脚本版本 `b627e56` 双跑均 `status=completed`、1 个分片、exit=0，分别耗时 313/260 秒；两轮均只保留一条 P1，准确定位到 `SsoController.java:238`，结果稳定。该证据表明此前稳定漏报已转为稳定可见，但不改变正式阶段一仍有 8 个 gold P0/P1、7 个命中、至少 12 个独立未参与调优根因待补的结论。

 2026-10-02：复核 `platform-erp-service:8a2c1e1a28c88751b4503ac53fc5eefd2fdbda0a` 时确认已有 `erp_sales_return_inspection` 表快照新增 `request_no` 字段和唯一索引，同时实体新增 `requestNo`，但差异没有版本化 `sql/migration`，README 明确要求已有数据库走迁移；该样本属于 dev 调优来源，不计入正式 holdout。新增 schema 快照迁移预检后，修复 Git hunk 标题表上下文识别，并增加 SQL 字段与 Java 属性关联，过滤纯格式重写 hunk。最终合并逻辑对模型原文与确定性预检的同根因按路径/行号重叠去重，只保留带代码证据的 P1。修复后真实 tuned 双跑均完整（1/1 分片，253/194 秒），两轮均只保留 `sql/platform_erp.sql:2407` 的一条 P1，结果稳定；预检、输出、分片、过滤和历史回归均通过。

### 2026-10-03：支付与库存并发预检边界收紧，重新定义阶段一验收口径

本轮将支付凭证和库存调整两个并发竞态预检接入个人本地入口。支付规则现在按 `countPendingByOrderId`、待确认凭证构造、实际保存调用和当前 SQL schema 做证据关联，并沿提交方法检查订单行锁/重复键恢复；库存规则只在四个确认方法的候选修改范围内检查直接库存读写，只认可库存仓库自身的 `ForUpdate`、CAS/原子更新，纯原子服务路径因没有直接读写候选而不进入该规则。新增 Python Java 方法窗口提取器，会屏蔽字符串、字符、注释和文本块中的大括号，避免相邻方法串联或提前截断。

无模型回归新增跨方法锁、唯一键、字符串大括号、无关服务类名和显式原子调用负例；`test-preflight.sh`、输出可见性、分片、证据过滤、历史、配置、scorecard 和 stage1 回归全部通过。真实 ERP 支付候选在上一版 runner 上双跑稳定发现 1 条确定性 P1；库存候选两轮均完整结束但模型 finding signature 漂移，记录为容量/稳定性边界，不计入正式通过统计。预检代码变更后，支付真实双跑需要重新执行，旧结果只作为历史诊断保留。

验收审计同时确认，`combined-scorecard-20261002` 中的 8 个 gold P0/P1 全部直接参与过规则设计或复跑调优；其中 7 个命中不能称为独立 holdout，当前可确认的独立未见 P0/P1 分母为 0。“还差 12 个”只适用于未审计的账面数字，不再作为完成承诺。冻结 runner、模型和提示词后，必须另建至少 20 个未参与调优的真实根因清单，双跑并完成人工 P0/P1、定位准确率、误报和功能簇 split 标签；用于修规则的样本转入回归集，并由新的未见样本替补。只有该盲测门禁通过后，才能宣称个人版达到生产级高可用。
冻结预检代码后的真实 `platform-erp-service:2ff8080d` 支付凭证候选已重新双跑：两轮均 34/34 分片完整、exit=0、`output_complete=true`，耗时 514/538 秒；finding signature 均为 `7c29f5ec2cd65bd06e36a1de0b064779db2a610df0713c9da5ec2b8e49cb0bc6`，稳定保留 `SalesOrderApplication.java:516` 的确定性 P1。首次重跑曾暴露历史评测临时快照没有复制新增 Python 依赖，已将 `run-history.sh` 的快照清单扩展到 `.py` 并由本轮 `review_scripts_snapshot=true` 验证。该样本仍是调优来源，只计入工程稳定性证据，不计入独立盲测召回率。

2026-10-03：为正式盲测建立私有候选池 `~/.local/share/local-review/evals/stage1-freeze-20261003/blind-candidates.tsv`，当前 27 个候选、27 个功能簇。候选池只是人工审查输入，不是金标集；需继续排除已参与规则设计的提交、同根因派生提交、同一配置凭据族和纯功能/低严重度样本，并为保留项记录 P0/P1 标签、根因归并键和准确位置。正式阶段一仍按四个阶段推进：独立盲测集冻结、双轮运行与人工标注、门禁验收及替换失败样本、最终版本与报告固化；在这些阶段完成前不宣称生产级高可用。

随后对该候选池进行差异归因：27 个提交虽然功能簇不重复，但与既有调优族、父提交已有风险、修复性改动和配置凭据族存在大量重叠。按保守标准，目前约 3 个候选可以直接作为新增 P1 初筛，其余必须补充源码/运行链路证据或排除；因此还不能把候选数量当作 20 个独立 gold。正式盲测第一阶段需要继续扩展未调优历史，直到独立根因数量和人工标签都满足门禁。

候选池随后扩展到 29 行，新增两个待人工标注功能簇：`platform-log:124aff6` 的日志租户/审计身份边界，以及 `platform-job:08696b57` 把完整 GLUE 源码、任务参数和任务对象序列化写入 INFO 日志的敏感数据暴露。两者先以 `pending-human-label` 进入人工核查，后经真实双跑和规则闭环转为 `tuning-source`，不把候选直接当 gold。

同日从当前 `devstral-small-2-review-tuned` 重新执行一次完整合成门禁：23 类正例全部命中、22 类 clean 对照全部通过，预签名票据回退通过，截断响应仍显式失败。原始运行结果保存于私有 `~/.local/share/local-review/evals/stage1-freeze-20261003/synthetic-run-20261003-v1/`；这证明当前工程/规则链路状态，但不替代真实独立 holdout。

2026-10-03：对新增候选 `platform-log:124aff6` 做两轮真实复核，模型原始结果均为 clean；新增日志租户/审计身份窄预检后稳定输出查询/导出/清理跨租户边界和审计身份伪造两条 P1。对 `platform-job:08696b57` 先做两轮基线复核，模型同样稳定 clean；新增 XXL-JOB 敏感日志窄预检后，两轮完整运行均稳定捕获 GLUE 源码和完整任务配置序列化到 INFO 日志的全部位置，模型重复段仍原样保留。两条样本现从私有盲测候选改为 `tuning-source`，不得继续计入独立 holdout，必须由新的未参与规则设计样本替补。预检回归和完整历史双跑均通过；这轮进展提高了已知根因的可见性，但没有扩大正式独立召回分母。

2026-10-03：冻结当前 runner、模型和提示词后，新增 8 个不同项目/根因族的真实提交完成双轮运行，结果均完整且重复签名稳定。上传路径穿越和 ERP `@PreAuthorize` 注释化回归被召回；API 资源同步共享令牌、XXL-JOB 跨应用任务控制、后台角色菜单 RBAC、微信登录身份伪造、HKS 幼教 API 未认证/IDOR、SSO 一次性票据 GET/DELETE 并发重放稳定漏报。当前独立盲测为 `gold=8`、`found=2`，召回率 25%，不能进入生产级高可用验收。XXL-JOB 大提交 14/14 分片双轮约 1139 秒；SSO 首轮截断被 fail-closed，缩小预算后才完成，均记录为容量/完整性边界。后续仍需至少 20 个独立根因、人工定位/误报/功能簇标签，以及 ≥90% 召回、≤10% 误报、稳定和完整输出门禁。

2026-10-03：新增 `platform-gateway:5497d0c39944192495e75828e0c9a519a395f7d2` 独立盲测。两轮均 `output_complete=true` 且 finding signature 稳定，但模型都漏掉 `/workflow/**` 未加入业务应用映射、空 `applicationCode` 分支放行造成的租户应用授权绕过；证据为 `SaTokenAuthGlobalFilter.java:58-64,353-362,391-408`，后续 `052b848` 补映射并增加回归测试。该样本继续作为 holdout；当前私有独立集为 13 个 gold、2 个命中，严格集（排除 HR 部署边界条件样本）为 12 个 gold、2 个命中，严格召回约 16.7%。

2026-10-03：独立盲测扩展到 20 个 gold 根因，全部两轮完整且稳定。按根因归并后命中 4/20；排除 HR 部署边界条件样本后为 4/19，严格召回约 21.1%。稳定召回的是网关 Reactor 鉴权 fail-open 和 Bafan 明文凭据暴露；workflow 租户应用绕过、第三方登录跨租户绑定、在线会话读取/踢下线、部门跨租户写入、匿名 OSS 任意对象写入等新根因均稳定漏报。样本量前置条件已满足，但距离 ≥90% 召回、≤10% 误报和最终发布门禁仍有明显差距；接下来调优命中规则并以新的未见根因替补。

### 2026-10-03：在线会话预检闭环与长尾超时边界

`e0bf68d` 新增在线会话租户边界预检，覆盖 `/sso/online` 的跨租户查询和按任意 token 踢下线两类窄根因，并配套租户安全查询、当前用户退出、ROOT 全局接口负例。预检、输出完整性、分片、证据过滤、历史和 stage1 回归全部通过。

冻结 `e0bf68d` 后，`platform-auth:9dbcc0c5` 严格串行双跑均为 11/11 分片完整、`exit=0`、`output_complete=true`，结果哈希和 finding signature 一致，稳定命中两条独立 P1：在线会话查询缺少租户边界，以及在线会话踢下线缺少目标会话归属校验。模型原文没有被删除，只按同根因与确定性预检合并。

`platform-system:a269a835` 在冻结 `a172044` 下完成 15/15 分片双跑且签名一致，但字典全局 CRUD 缺少权限/租户约束仍被稳定漏报，记录为新的正式漏报。`platform-auth:b7fa4c0` 在 `0a39fbd` 预检下已能确定性识别第三方登录跨租户绑定；随后 `88ab5eb` 将该确定性证据从每个分片的模型 prompt 移到最终合并，新的双跑均 37/37 分片完整（224/196 秒），结果哈希一致。由于 b7fa 本身参与了规则设计，这次稳定命中只进入 tuning-source 回归，不增加最终 holdout 召回率；长尾由重复预检上下文引起，无需放大全局超时。

最新私有正式表为 21 个 P0/P1 根因，21/21 次双跑完整且稳定，合并后命中 6 个；排除 HR 条件样本后的严格口径是 6/20（30.0%）。这仍远未达到个人版高可用门禁。后续必须继续补充未参与规则设计的新根因，并把长提交自适应分片/长尾策略作为独立工程问题处理；用于新增规则的样本要移出 holdout，由新的未见样本替补。

随后为 `platform-job:a1755156` 增加 HTTP 任务参数 SSRF 窄预检（`e811433`）：仅匹配 `HttpJobHandler.execute(String param)` 直接构造 `HttpGet(param)` 并执行、且当前文件没有 URL/主机/IP 防护；静态 URL 和 allowlist 负例保持 clean。冻结 runner 后双跑均 7/7 分片完整，finding signature 与 SHA-256 一致，四个变体文件的位置全部可见。该提交参与规则设计，已转为 tuning-source 回归，不增加最终 holdout 分母；整文件 guard 的方法级收窄和 HttpPost 形状仍需独立负例验证。

2026-10-03：针对 `platform-job:4a0850b` 的稳定漏报新增 XXL-JOB 空 `accessToken` fail-open 预检。仅当 `xxl-job-admin` 运行配置新增空最终回退、当前 `OpenApiController` 方法在 token 非空时才比较、且 `PlatformJobSecurityConfig` 对 `/api/**` 使用 `permitAll` 时报告一个聚合 P1；非空 dev 回退、普通配置 key、缺少端点证据或默认拒绝实现均保持 clean。正负 fixture 与完整确定性回归通过。该提交已经参与规则调优，后续结果只能作为 tuning-source/稳定性证据，不能计入独立 holdout；正式门禁仍需要新的未见根因、双跑、定位准确率和误报标签。

同一 `platform-job:4a0850b` 长提交在个人 profile 默认 3KB 下被拆为 140 片并因总超时 fail-closed；受控 12KB 配置下为 35 片，两轮均完整稳定（1127/1105 秒），空令牌 P1 在真实差异中可见。结合既有 6KB 大提交稳定证据，个人 wrapper 默认分片预算调整为 6000 字节；12KB 仅作为受控复测参数，通用 core 仍为 3000 字节。该 tuning-source 结果不进入独立召回分母。

2026-10-03：对 `platform-publishing-mcp-service:6cb134b` 的工作区边界新增窄范围符号链接逃逸预检。仅当两个具体 MCP 工具类新增 `workspaceRoot.resolve(...).normalize()`、实际执行 DOCX 读写/目录创建/LibreOffice 进程操作，且当前快照没有 realpath 或 `NOFOLLOW_LINKS` 等链接防护时报告聚合 P1；已有真实路径校验和普通路径工具不触发。正负 fixture 已通过，真实双轮复测待完成；该提交参与规则设计，不能计入独立 holdout，后续需用未见根因替补。

2026-10-03：补齐出版任务证据边界与复核门禁预检。`platform-publishing-service:e41c1c3` 的 `/artifacts`、`/issues`、`/tool-invocations` 写入在普通 execute 权限下直接接受 DTO 并保存 READY/OPEN 证据，新增聚合 P1；同提交的复核流程还允许把 ERROR/BLOCKER 改为 IGNORED/RESOLVED，而批准只统计 OPEN 阻塞项，新增第二条聚合 P1。两条规则均要求可见的保存/计数/状态证据，并以 ExecutionRef/租约、实际内容校验和 NON_WAIVABLE_SEVERITIES 作为安全负例；独立 fixture、完整预检、输出与证据过滤回归均通过。该提交参与规则设计，不计入正式 holdout。

同轮补充出版 MCP 资源授权预检：当文件工具只有共享 `X-Gateway-Token`、直接接受 jobNo/工作区相对路径，且当前源码没有 `PublishingExecutionGrantService`、`PublishingWorkspaceService` 或授权调用时，报告 tenant/job/execution scope 缺失 P1；后续 HMAC execution grant 与租户工作区服务作为安全负例。该规则与符号链接预检分开，前者覆盖资源授权，后者覆盖真实路径逃逸；正负 fixture 和完整回归均通过，相关提交移出正式 holdout。

随后将出版 MCP 资源授权预检收紧为变更入口所在的方法窗口，新增“实际工具方法有 grant、无关 helper 也有 grant”的反例，避免整文件关键词造成误抑制；并新增 system 字典全局写权限预检。该规则要求 `/api/v1/dicts` 的 POST/PUT/DELETE 方法实际调用字典写服务，服务直接写 `sys_dict/sys_dict_item`，且租户配置将两表列为 ignore；缺少方法级 `@PreAuthorize`/等效权限表达式时报告 P1，带权限守卫的写入口和无关查询/日志方法保持 clean。

真实 `platform-system:a269a835` 快照的一次 Ollama 实跑全部分片正常结束，模型原生 P1 与确定性字典授权 P1 均可见且没有截断/超时；该样本已转为 tuning-source，不回填独立 holdout 召回率。

随后新增 Bafan OSS 匿名任意对象写入预检，要求具体 policy 方法、匿名路径排除、空 `$key` 前缀和 100MB policy 同时成立；正负 fixture 与真实 `bfan-backend:ee1e73b4` snapshot smoke 通过，确定性 P1 与原有默认凭据 P1 均可见。该提交已移出独立 holdout，后续需用新的未见根因替补。

2026-10-03：补齐 `platform-system:797cd5b` 部门跨租户写入预检。规则限定 `DeptController`/`DeptServiceImpl`/`SysDept` 的方法级证据，只有请求体 `tenantId` 经 `buildDept` 进入部门创建/更新，且服务层直接执行 `insert`/`updateById`、没有 `TenantOperationGuard` 或当前租户归属断言时报告 P1；方法声明定位避免把 `buildDept(...)` 调用行误当成证据，服务层守卫和非部门接口为 clean 负例。完整确定性回归与真实 797cd5b 归档 smoke 通过，稳定定位 `DeptController.java:86`、`DeptServiceImpl.java:38`。该样本参与规则设计，已从独立表转为 tuning-source，不计入正式 holdout 召回率；独立表当前需用新的未见根因替补。

2026-10-03：补齐 `platform-bafan:807b43b4` 后台分类写权限预检。规则限定 `AdminCategoryController` 的 POST/PUT/状态变更/DELETE 方法，要求 `/admin/**` 只注册认证拦截器、拦截器只解析 JWT/保存 role，且具体写方法直接操作 `categoryMapper`、没有方法级权限表达式；带权限守卫或真正权限拦截器的安全夹具保持 clean。完整回归与真实快照 smoke 通过，稳定聚合四个写入口为一条 P1；样本已转为 tuning-source，不计入独立 holdout，后续需补未见根因。

本轮同步审计私有 scorecard：独立表当前为 17 个 P0/P1 根因（含 1 个 HR 条件样本），严格口径为 16 个、命中 6 个，召回约 37.5%；tuning-source 为 4 个。新增预检命中只证明已知漏报形成回归保护，不能回填独立召回率；还需至少 4 个未参与调优的独立根因补足样本规模，再执行最终召回、误报、定位、稳定性和完整性门禁。

2026-10-03：补齐 `platform-system:e45a97f5` 应用详情密钥边界预检。只在查询权限详情返回原始 `SysApplication`、应用层直接 `ensureExists`、仓储 `findById` 直接 `selectById`、实体含 `clientSecret` 且同一仓储存在 `SysTenantApplication` 关系证据时报告 P1；脱敏 VO 和关系约束为 clean 负例。真实快照 smoke 稳定定位 `ApplicationController.java:66`，样本参与规则设计并转为 tuning-source，不计入独立 holdout。独立表口径仍为 17 个记录，严格排除 HR 条件样本为 16 个，命中 6 个，严格召回约 37.5%；tuning-source 为 5 个，仍需至少 4 个未见根因达到 20 个样本。

2026-10-03：补齐 `platform-system:abfb9cc` 内部 API 资源同步边界预检。规则限定 `/api/v1/internal/api-resources/sync`，要求同步应用按请求体 `applicationCode` 选择目标并直接新增/更新资源，同时 README 只证明共享 `X-Gateway-Token`，而控制器和同步服务没有可见的调用方到应用绑定；带 `@InternalService`、服务身份或显式 application grant 的安全夹具保持 clean。真实归档 smoke 稳定定位 `ApiResourceSyncController.java:24`，样本参与规则设计并转为 tuning-source，不计入独立 holdout。独立表仍为 17 个记录，严格排除 HR 条件样本为 16 个，命中 6 个，严格召回约 37.5%；tuning-source 增为 6 个，仍需至少 4 个未见根因达到 20 个样本。

2026-10-04：完成独立替补与角色权限边界批次。`platform-auth:3d1eaac` 双轮完整稳定，新增 localhost 配置中的固定数据库/Redis/Nacos 凭据，按一个独立 P1 根因计入 holdout；`platform-system:ecc8d75` 的 `RolePermissionApplication` 菜单/部门跨租户绑定预检在真实快照稳定命中，转为 tuning-source。当前独立表为 17 个记录（严格排除 HR 条件样本为 16 个），严格 gold P0/P1 为 16 个、命中 7 个，严格召回约 43.8%；tuning-source 为 7 个。按阶段一门禁仍需至少 4 个未见的新 P0/P1 根因，并至少补足 3 个独立提交记录，同时完成 train/dev/holdout split。

2026-10-04：统一冻结 scorecard 口径并切换为高效率补样流程。私有冻结目录三张表完成只读一致性审计；候选 TSV 的缺失 `parent` 列、状态拼写和仓库名拼写已修复。最终计分以 `independent-probe-results.tsv` 的 `label_status` 为唯一依据：`manual-confirmed` 才进入独立 holdout，`manual-confirmed-conditional` 单独记录部署前置条件，`tuning-source` 只用于回归保护。当前严格独立表为 9 个 P0/P1 根因，命中 4 个，定位准确 4/4，双轮完整稳定 9/9，严格召回率 44.4%；另有 1 个 HR 部署条件样本和 14 个调优源。历史快照中的 16/17/20 等数字保留，但不再与当前最终口径混用。

为提高效率，后续流程固定为“静态证据预筛 → 多角色并行根因审计 → 只对通过审计的少量样本双跑 → 发现规则后立即移出 holdout 并补新样本”。静态预筛先排除冻结表已有样本、修复提交派生、同一凭据族和纯功能改动；模型双跑只用于未见根因的真值、定位与稳定性确认。任何新增预检命中的样本立即标记为 `tuning-source`，由下一批未参与设计的样本补回分母。当前仍需至少 11 个新的独立根因达到 20 个样本，并在最终冻结后重跑召回、误报、定位、稳定性与输出完整性门禁。

同日对 `platform-system`、`platform-gateway`、`platform-hr-service`、`platform-auth` 和 `platform-common` 的 11 个近期提交做并行只读审计。HR 目录、移动端登录、网关 publishing 路由、系统账号 provisioning 和迁移加固均未发现由提交直接引入且未见过的 P0/P1；`platform-auth:cb2dcb6` 的 Sentinel 默认 Nacos 凭据属于已有 `config-prod-nacos-default` 根因族，只能标为 recurrence/tuning-source，不能扩大独立分母。该批次全部在模型双跑前淘汰，验证了“先根因去重、后模型复测”可以避免重复消耗本地推理时间。

随后对冻结池中的 14 个 pending 候选做第二轮并行源码审计：认证/网关 2 个、ERP 7 个、AI/出版 5 个。结果全部不进入独立 holdout：有的父提交已有风险，有的是安全修复或 clean 变更，有的只有 P2 隐私/DoS 或条件性 URL host allowlist 加固证据。该批次没有启动 Ollama 双跑；当前缺口不是多跑旧样本，而是从尚未扫描的功能簇中找到真正未见的 P0/P1 根因。

随后从未扫描的文件配置回归族中补入 `platform-file:7eb92a127ff3a52a6dc2bbc4549f91c55fe8ceb3`。父版本使用 `ALIYUN_OSS_*` 环境变量，目标提交将 OSS access key/secret 改为明文且当前 HEAD 仍保留；两轮个人 profile 均 1/1 分片完整，结果哈希和 finding signature 一致，模型原生 P1 稳定定位 `nacos-config/platform-file-localhost.yml:98-99`，确定性凭据预检同时保留两行。该样本未参与规则设计，计入严格独立 holdout；当前严格表为 10 个 P0/P1、命中 5 个、召回 50.0%，双轮完整稳定 10/10，命中定位准确 5/5。达到 20 个样本前仍需至少 10 个未见根因。

2026-10-04：从未扫描的 Bafan 商户模块确认 `b4271c98cc61bb36e0a27c2da40b7195afdc99df` 的公开实体序列化 P1：`/api/merchant/list` 与 `/api/merchant/hot` 被公开排除认证，控制器却返回 `Result<PageResult<AppMerchant>>`，实体含 `finderId`、`editExpireTime`、`status`、`deleted` 和内部统计字段；后续 `2e1b013` 引入 `PublicMerchantVO` 修复。个人 profile 两轮真实结果均完整稳定但 clean，证明模型稳定漏报，因此标记为 tuning-source，不进入独立 holdout。SYSTEM 新增公开路由/持久化实体/内部字段三条件边界，并新增跨文件 Bafan 确定性预检与 `evals/test-bafan-public-entity-preflight.sh` 正负回归；真实复测预检定位到 `AppMerchantController.java:90`，但模型分片超时，按 fail-closed exit=1，不计入成功率或稳定性。当前严格 scorecard 仍为 10 个 gold P0/P1、命中 5 个、召回 50.0%，调优源 15 个，另有 1 个 HR 条件样本；仍需至少 10 个未参与规则设计的新根因。

2026-10-04：对 ERP `ebfd4875` 完成多角色根因归因和双轮复核。原候选标题描述的是父提交已有的库存并发竞态，排除后确认目标提交新增的是兼容性根因：`LogicalWarehouseSkuRepository` 将无串码查询从 `NULL OR ''` 收窄为只匹配空字符串，`sql/platform_erp.sql` 只在初始化快照中新增 `NOT NULL`/唯一键，没有版本化迁移；父版本已存在写入 `serial_no=NULL` 的路径，因此已有库历史库存会从出库/调拨可用量查询中消失。个人 profile 两轮均 5 分片完整、exit=0、结果哈希与 clean finding signature 一致，模型稳定漏报；该样本转为 tuning-source，不计入严格 holdout。新增窄范围 schema-compatibility 预检与 `evals/test-inventory-serial-null-migration-preflight.sh` 正负回归，仅在 NULL 兼容查询被移除、初始化快照补约束、仓库存在迁移契约且当前差异没有版本化 migration 时报告 P1。当前严格 scorecard 仍为 10 个 gold P0/P1、命中 5 个、召回 50.0%，调优源增至 16 个；仍需至少 10 个未参与规则设计的新根因。
2026-10-04：继续执行高效率补样。对未冻结 ERP 候选 `0e6006b` 做父子快照预筛，通用 schema 迁移预检准确定位 `sql/platform_erp.sql:1768` 的 `erp_sales_order.request_no` 字段/唯一索引缺少版本化 migration，因此按同一机制族跳过模型双跑，不重复占用 holdout。对 Bafan workflow 凭据提交 `7acb085d` 做两轮个人 profile 复测，两轮单分片完整稳定，模型与确定性预检均定位 `.github/workflows/deploy.yml:14` 的 DingTalk `access_token`；只读 scorecard 校验发现该提交此前已计入严格表，本轮仅补稳定性证据，不重复计分。当前严格 scorecard 仍为 10 个 P0/P1、命中 5 个、召回 50.0%，输出完整和重复稳定均为 10/10。
2026-10-04：补充 ERP 寻货状态独立样本 `555758b374023ff490ed4243b0417c2115c271ed`。该提交仅改动 1 个 Java 文件、9 行逻辑；源码显示 `confirmInbound` 已完成入库单和库存更新后，`ensureFinishable` 由 PENDING/SEARCHING 白名单收窄为只拒绝 CANCELLED，导致 INBOUNDED/CLOSED 记录仍可被 close/cancel，形成状态与库存事实矛盾的 P1。个人 profile 两轮均单分片完整结束但均返回 clean，稳定确认一次模型漏报；该提交此前已在私有 pending 队列，因此按独立样本计入严格 scorecard而非重复添加。当前严格表为 11 个 P0/P1、命中 5 个、召回 45.5%，输出完整和重复稳定均为 11/11。
2026-10-04：补齐 SSO 一次性 ticket 竞态预检。规则只匹配 `SsoController` 的 `/sso/exchange` 方法，要求当前差异/快照同时出现 `RedisKeyUtil.getSsoTicketKey`、`redisUtil.get` 和 `redisUtil.delete`，并排除 `getAndDelete`、GETDEL、Lua/compare-and-delete 等原子实现；普通 Redis 读删代码不触发。`evals/test-sso-ticket-replay-preflight.sh` 正负夹具、真实 `platform-auth:5003d86b` 父子快照和完整回归均通过，准确定位 `SsoController.java:126`。该预检用于工程可用性回归，不把已知漏报回填为模型原生召回；公开门禁现为 40/40 套件通过。
2026-10-04：补齐 Bafan 角色菜单 RBAC 写接口授权预检。针对 `platform-bafan:e9aa921` 的稳定漏报，新增 `collect_bafan_admin_role_menu_authorization_preflight`：只匹配 `AdminRoleController` 新增的 `PUT /admin/role/{roleId}/menus` 与 `POST /admin/role/init-role-menus`，要求当前快照只有 `AdminAuthInterceptor` 的 `/admin/**` JWT 认证、没有注册权限拦截器，且方法实际调用 `roleService.saveRoleMenus` 或 `initBasicRoleMenus`；方法级权限表达式和已注册 `AdminPermissionInterceptor` 保持 clean。正负 fixture、完整 `test-preflight.sh` 和隔离真实快照 smoke 均通过，输出聚合 1 条 P1 并定位到 `AdminRoleController.java`。该样本按评测纪律从 `manual-confirmed` 转为 `tuning-source`，确定性覆盖增强不回填模型原生召回；当前私有表为严格 gold 10 个、命中 5 个、召回 50.0%，输出完整/双轮稳定 10/10，调优源 20 个，仍需至少 10 个未参与规则设计的新根因。

2026-10-04：为提高补样效率，新增只读候选筛选器 `scripts/triage-candidates.py` 及回归夹具。它只按 `repo + commit + feature_cluster` 去重并跳过已分类/已计分记录，不替代人工根因归并；当前冻结候选池 57 条记录中 24 条仍待人工标注，筛选器未发现待标候选与 scorecard 精确重叠。认证/网关/common、文件/出版/HKS、AI 和 ERP 候选随后完成并行静态审计，未发现新的独立 P0/P1，故本轮不启动模型双跑。当前严格 scorecard 仍为 10 个 gold P0/P1、命中 5 个、召回 50.0%，输出完整/双轮稳定 10/10，仍需至少 10 个未参与规则设计的新根因。

2026-10-04：第二轮效率审计先对未冻结提交做多角色静态去重，再决定是否调用 Ollama。`platform-erp-service:dbeb99f` 的退货幂等/并发 P1 已由现有预检和 `erp-return-idempotency` 调优族覆盖；`platform-erp-service:555758b` 的入库后关闭/取消 P1 已在评分卡；`platform-system:3b90a2e` 的 HR 批量账号查询具备输入上限、去重、租户/来源系统/逻辑删除条件和参数化查询，但新增入口沿用既有内部端点的直连暴露边界，若可绕过网关则属于与 `fc8e1c6` 同族的条件性 P1，不是新独立根因。此前 `platform-gateway:d3aa21`、`platform-ai-service:ddc7b767`、`platform-system:db93e1d` 也未形成新独立 P0/P1。以上提交全部 `model_double_run=no`，避免重复消耗本地推理；筛选器当前 `selected=0`，严格评分卡仍为 10 个 gold P0/P1、命中 5 个、召回 50.0%，输出完整/双轮稳定 10/10。下一步只补尚未扫描功能簇中的独立根因，不以规则命中冒充模型原生召回。

同日对 `platform-ai-front:83821a4` 做权限契约复核：页面菜单使用 `ai:erp-assistant:query`，发送按钮保留 `erp:ai-assistant:use`，README、后端校验和后续迁移均证明这是“进入页面 + 发起查询”的双权限设计，排除为 intended contract，不启动模型双跑。`platform-workflow-service:189b671` 是无父提交的全新服务基线，内部共享令牌未绑定调用方应用、事件领取显式跨租户，记录为部署边界审计线索；由于 root commit 不满足当前直接 parent 的冻结评测门禁，不纳入 scorecard。通过先核对契约和提交形态，本轮继续保持 `model_double_run=no`，避免无效推理。

同日审计 `platform-erp-service:e00c770` 收货验收规则变更。保存与确认路径均保留数量总和、串码、租户和锁定读校验，没有新的 P0/P1；但收货列表将 `updateTime` 用于所有状态，退款更新可能改变已确认单的时间顺序，记录为独立 P2；文档还残留一处旧的单行零数量说明，记录为 P3/信息。该样本不进入 P0/P1 holdout，也不启动模型双跑。

2026-10-04：对未冻结 ERP 订单资金提交 `platform-erp-service:2ff8080d22c31b90aa573281b914c87ef3ec4424` 完成两轮个人 profile 复测。两轮均 `exit=0`、34 个分片完整结束（约 532 秒/553 秒），结果哈希一致；模型只稳定报告父链已有的提交阶段待确认支付凭证问题，未发现本次新增的确认/拒绝并发竞态。源码核验确认 `confirmPaymentVoucher`/`rejectPaymentVoucher` 使用非锁定查询，资金服务先 `countActiveBySourceOrderNo` 再充值、冻结和落库，缺少行锁/CAS/来源订单唯一约束，存在重复充值冻结以及确认与拒绝交错导致资金与订单状态不一致的 P1。该样本标记为 `tuning-source`，不回填模型原生召回；新增窄范围 `collect_sales_payment_confirmation_race_preflight` 及正向/锁定负向夹具，完整 `test-preflight.sh` 已通过。当前独立 scorecard 仍为 10 个 gold P0/P1、命中 5 个、召回 50.0%，输出完整/双轮稳定 10/10；本轮效率收益来自稳定漏报后立即固化回归规则，而不是把确定性命中冒充模型能力。

2026-10-04：对未冻结 ERP 退货退款提交 `platform-erp-service:7fee9f1a2af94fdc6d47769a7e93f2d7a493f140` 做两轮个人 profile 复测。两轮均 19 个分片、`exit=0`、约 350/327 秒，结果哈希和 finding signature 一致；模型稳定报告了一个锁顺序 P1 候选，但源码核验确认退款与验收流程均按“退货单→验收单”顺序加锁，故不确认该候选。静态证据确认新增退款主表/明细表只进入 `sql/platform_erp.sql`，没有对应版本化 migration；这是既有 schema-migration 机制族，不重复计入独立召回。新增窄范围 `collect_sales_return_refund_schema_migration_preflight` 及“缺 migration / 有版本化 migration”正负夹具，先静态规则即可覆盖，避免再次消耗模型推理时间。scorecard 增加 1 条 `tuning-source`，严格 gold 仍为 10 个、命中 5 个、召回 50.0%；当前高效流程保持为“静态预筛→必要时双跑→立即固化回归”。

同日针对该样本的锁序误报补强模型硬边界：要求逐条列出可达事务路径的实际锁调用、资源映射和方法边界；可见路径同序时禁止报告，不得把行号、方法名或静态候选文本拼成反向锁序。完整预检回归通过，严格 scorecard 不变；该调整用于减少人工复核和无效修复建议，不把提示词约束当作模型原生命中。

随后从未扫描的 Bafan 可用性提交 `bafan-backend:85da9946` 补入一个独立安全样本。目标把 Actuator `metrics` 加入业务应用端口的公开暴露列表，并新增线程池指标；现有 Web MVC 拦截器只覆盖 `/api/**` 与 `/admin/**`，没有管理端口或 Actuator 认证边界。个人 profile 两轮均 10 个分片、`exit=0`、结果哈希一致且均返回 clean，源码核验确认未认证 `/actuator/metrics` 可枚举线程池、JVM、HTTP 和连接池遥测，计为新的独立 P1 漏报。独立 scorecard 当前为 11 个 gold P0/P1、命中 5 个、召回 45.5%，输出完整/双轮稳定 11/11。随后新增 `collect_public_actuator_metrics_preflight` 与独立/隔离管理端口正负夹具，作为后续审查的确定性保护，不回填模型原生召回。

2026-10-04：将补样流程固化为“自动发现 → 人工根因去重 → 风险排序 → 少量双跑”。新增只读 `scripts/discover-candidates.py`，从多个本地 Git 仓库自动生成真实 parent、提交主题和待人工状态，跳过 root/merge 提交并按 `repo + commit` 排除已处理记录；同时修复候选排序器在输入已有 `commit_subject` 时产生重复 TSV 表头的问题。三套脚本回归通过，真实 Platform 工作区在 2026-09-25 之后得到 22 条候选，排序结果仍保留全部 22 条；该改进只降低人工抄录和无效 Ollama 调用，不改变模型问题完整可见的门禁。
2026-10-05：继续执行效率优先的静态分流。对 ERP 退货 CRUD、寻货 SKU 查询、收货验收状态、订单退货汇总和退款字段快照逐提交核对，均为已覆盖根因族、只读契约变更或无新增服务端边界；五个高优先级前端退货提交只包含页面/请求封装/权限常量/文档，也不独立产生新的服务端 P0/P1。私有候选筛选器从 69 条待审降至 51 条，未启动重复模型双跑。对 2026-10-05 之后 26 个 Platform 仓库重新发现直接父提交，候选数为 0；候选筛选、排序和快速回归均通过。严格 scorecard 保持 gold P0/P1=11、found=5、召回 45.5%、输出完整 14/14、重复稳定 14/14。下一步只从新功能簇补充未参与规则设计的独立根因，不把静态预检命中计入模型原生召回。

2026-10-07：对冻结 scorecard 做规则时间线审计，发现 `platform-bafan:f895a223` 的路径穿越预检和 `platform-erp-service:4451b5b` 的权限注解预检均是在对应样本之后设计；两条记录从 `manual-confirmed` 改为 `tuning-source`，不再计入独立 holdout。严格口径由 11 个 gold/命中 5 个修正为 9 个 gold/命中 3 个，召回率 33.3%，输出完整与双轮稳定为 12/12，定位准确为 3/3。该修正移除了调优泄漏，后续必须用新的未见根因补足分母；外部数据只进入 train/dev/external-smoke，不回填独立 scorecard。

同日下载并私有保存 AACR-Bench 正/负审查样本、Vul4J 元数据和 JavaVFC 人工 JSONL，记录来源、许可证、版本和 SHA-256；只做完整性核验，不直接改动 few-shot 或独立 holdout。外部数据下一步先规范化、去重、切分，再作为 train/dev/external-smoke 使用。

2026-10-07：为 `platform-erp-service:a942bb4f` 增加三条确定性回归保护：作废报量串码计数缺少有效订单状态、五张报量持久化表缺少存量库版本化 migration、销量查询把订单/明细/串码全量加载后在 Java 中分页。规则要求完整的应用、仓储、控制器和查询对象证据，并对作废清理、状态关联、版本化 migration、数据库分页和 keyset 分页提供安全反例。`evals/test-erp-report-quantity-preflight.sh` 已接入完整预检套件，正负回归、完整预检和分片回归均通过。该提交的 Ollama 大差异盲跑未在总预算内完成，记录为 fail-closed 的调优源，不计入模型原生召回；当前严格独立口径仍为 9 个 gold P0/P1、命中 3 个、召回 33.3%，输出完整与双轮稳定 12/12。个人版尚未达到最终高可用验收，后续继续补未见独立根因并冻结复测。
2026-10-07：新增 ERP 大数据导出确定性预检，覆盖新导出任务表缺少存量 migration、RUNNING 任务无租约回收、空结果成功上传以及可变 status+id 游标四类高置信根因；`evals/test-erp-export-preflight.sh` 正负回归通过并接入总套件。`platform-system:57e86246` 两轮个人 profile 完整稳定但漏掉两个独立 P1，已写入私有账本；严格模型 holdout 更新为 11 个 gold、3 个命中、27.3% 召回，输出完整/双轮稳定 14/14。确定性规则命中不计入模型原生召回，后续继续补未见功能簇。
同日补齐 JavaVFC 的候选规范化边界：它没有独立逐行 review 金标，新增脚本仅生成 `pending-human-label` 的 Java 提交候选，不复制源码、不写入 positive 标签；私有 200 条候选稳定切分为 train 156、dev 24、external-smoke 20。AACR 人工评论与 JavaVFC 候选保持分离，避免外部数据污染 Platform 严格 holdout。
