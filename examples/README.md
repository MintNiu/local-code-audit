# Review 示例

few-shot 示例应由人工确认后再使用，每条至少包含：

- 变更或 diff 摘要；
- 必要上下文；
- 正确的问题列表，或明确的“未发现阻塞问题”；
- 严重级别、文件、行号、证据、影响、修复和验证方式；
- 误报反例（如果该案例容易被误报）。

真实示例不要提交到公共仓库。默认本机示例文件位于：

`~/.local/share/local-review/examples.md`

也可以通过 `LOCAL_REVIEW_EXAMPLES_FILE` 或 `local-review --examples <file>` 指定其他路径。
