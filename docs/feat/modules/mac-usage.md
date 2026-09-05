# Mac 用量查看

> 验证状态：开发预览。daemon 全量扫描、按日 / 项目 / 模型的报表、价目刷新与 Usage 页均已在本机核对；2026-08-01 至 09-04 逐日与 ccusage 对账，token 各字段一致。

Lumi for Mac 在侧边栏提供 Usage 页，回答"这台 Mac 上的 Claude Code 和 Codex 在某段时间用了多少 token、花了多少钱、花在哪个项目和哪个模型上"。数据直接来自 Agent 自己的本机对话记录，与 Session 列表彼此独立。

## 模块概览

- **入口**：侧边栏 Monitor 组的“Usage”。
- **前置条件**：daemon 已安装并运行；不需要安装 Hook——Usage 读的是 Agent 自己写在本机的对话记录。
- **主要结果**：选一个时间范围，看到四张指标卡（Cost、Tokens、Sessions、Turns）和两张表：By agent（每个 Agent 一行，点开看它用过的每个模型）、By project（按工作目录）。
- **只读边界**：Usage 只统计，不改变任何 Agent 记录，也不影响 Lumi 的 Session。
- **相关文档**：[Mac 会话查看](mac-session-view.md)、[数据流](../data-flows.md#用量)。

## 主流程

1. 点击侧边栏“Usage”。
   - 系统反馈：页面以上次选过的范围打开（首次为 Today），指标卡和三张表随即填充；daemon 首次扫描还没完成时页首显示 `Scanning transcripts · N files left`，数字随扫描增长。
   - 规则引用：[USG-R-001](#usg-r-001-用量来自-agent-的本机记录与-session-无关)、[USG-R-004](#usg-r-004-页面可见时自动刷新)。
2. 在页头选时间范围：Today、This week（周一起）、This month，或 Custom。
   - 系统反馈：选 Custom 后出现两个日期框（起、止），止日不能晚于今天，起日不能晚于止日；范围一变，整页重算。
   - 规则引用：[USG-R-003](#usg-r-003-时间范围按本地日计闭区间)。
3. 看表：By agent 一行一个 Agent（Claude、Codex）加 Total，点行首箭头展开或收起它的模型子行；By project 一行一个工作目录（目录名 + 缩写路径，悬停看全路径）。点表头按该列排序（Agent 行之间、同一 Agent 的模型之间各自排），再点一次反向。
   - 系统反馈：Cost 列显示美元；Cache ratio 是缓存读取占全部 token 的比例；没有公开价格的模型 Cost 为 `—`，表尾一行说明有多少 token 没有价格。
   - 规则引用：[USG-R-002](#usg-r-002-cost-是按公开价目的估算)。

完成信号：指标卡的 Cost 与 By agent 表的 Total 行一致；页头右侧显示 `Prices · models.dev · updated … ago`。

## 页面结构

- **页头**：范围分段控件（Today · This week · This month · Custom）+ Custom 的两个日期框；右侧是价目状态——`Prices · models.dev · updated 3h ago`，daemon 从未成功联网时显示 `Prices · built-in snapshot`。
- **指标卡**：Cost（范围内有价格部分的总花费）、Tokens（输入 + 缓存读 + 缓存写 + 输出）、Sessions（去重的会话数，Subagent 归入父会话）、Turns（去重的回合数）。
- **By agent**：Claude、Codex 两个组行（带图标、可折叠）+ 各自的模型子行 + 固定在最后的 Total 行；列 Cost · Input · Cache read · Cache write · Output · Total · Cache ratio · Sessions。默认按 Cost 降序，无价格的模型排在组内最后。
- **By project**：Project · Sessions · Turns · Tokens · Cache ratio · Cost · Last active，默认按 Cost 降序。
- **工具栏**：标题 Usage 与 Refresh（立即重拉当前范围）。

## 规则

### USG-R-001 用量来自 Agent 的本机记录，与 Session 无关

- 条件：daemon 运行中。
- 行为：daemon 扫描 `~/.claude/projects` 与 `~/.codex/sessions`、`~/.codex/archived_sessions` 下的全部对话记录（含 Claude 子 Agent），每 30 秒跟进新写入。
- 结果：安装 Lumi 之前的会话、没触发 Hook 的会话、被 Filters 隐藏的会话都计入；删除 Session 或 Clear history 不改变 Usage。
- 限制或例外：只统计这台 Mac 上的文件；Agent 自己删掉的记录随之消失。

### USG-R-002 Cost 是按公开价目的估算

- 条件：模型在 models.dev 价目表里有该模型的价格。
- 行为：按公开价目计算：未缓存输入、缓存读、缓存写（1 小时档按 2 倍输入价）、输出分别计价；一次调用的上下文超过模型的长上下文阈值（如 OpenAI 模型 272K）时，这次调用整体按高档价计；daemon 每 24 小时刷新价目，刷新后对历史范围同样生效。
- 结果：Cost 反映公开 API 价，不是账单，也不含订阅套餐的折算。
- 限制或例外：价目表里没有的模型（如 `<synthetic>`、`codex-auto-review`）Cost 显示 `—`，其 token 计入 Tokens 但不计入任何 Cost，By model 表尾会注明数量。

### USG-R-003 时间范围按本地日计，闭区间

- 条件：用户选择任一范围。
- 行为：以这台 Mac 的本地日为单位，起止都包含；This week 从周一起；Custom 的止日不能晚于今天，起日不能晚于止日，最长 366 天。
- 结果：跨午夜的回合按每次模型调用的发生日分别计入。
- 限制或例外：改系统时区后，历史记录仍按扫描时的本地日归档。

### USG-R-004 页面可见时自动刷新

- 条件：Usage 页在前台。
- 行为：每 30 秒重拉一次当前范围；切换范围或点 Refresh 立即重拉；离开页面停止。
- 结果：正在进行的会话在页面上持续增长；上次选过的范围下次打开仍在。
- 限制或例外：daemon 不可达时保留上次的数字并在页首显示错误；恢复后下一次刷新自动接上。

## 空状态与故障

- **No usage in this range**：范围内没有任何模型调用；换个范围。
- **Scanning transcripts · N files left**：首次扫描进行中，数字不完整；扫完自动消失。
- **页首红字错误**：daemon 不可达或拒绝请求；参照[恢复路径](../friction-points.md)。

## 相关文档

- [功能全景](../index.md)
- [Mac 会话查看](mac-session-view.md)
- [数据流](../data-flows.md)
- [Usage 设计](../../design/usage.md)
- [已知问题：`codex-auto-review` 没有价目](../../issues/codex-auto-review-model.md)
