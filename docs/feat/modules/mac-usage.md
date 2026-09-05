# Mac 用量查看

> 验证状态：开发预览。daemon 全量扫描、按日 / 周 / 月 / 项目 / 模型的报表、价目刷新与 Usage 页均已在本机核对；2026-08-01 至 09-04 逐日与 ccusage 对账，token 各字段一致。

Lumi for Mac 在侧边栏提供 Usage 页，回答"这台 Mac 上的 Claude Code 和 Codex 在某段时间用了多少 token、花了多少钱、花在哪个项目和哪个模型上、走势如何"。数据直接来自 Agent 自己的本机对话记录，与 Session 列表彼此独立。

## 模块概览

- **入口**：侧边栏 Monitor 组的“Usage”。
- **前置条件**：daemon 已安装并运行；不需要安装 Hook——Usage 读的是 Agent 自己写在本机的对话记录。
- **主要结果**：选一个时间范围，Summary 卡给出花费、token、走势，Detail 卡给出一张可换分组的明细表。
- **只读边界**：Usage 只统计，不改变任何 Agent 记录，也不影响 Lumi 的 Session。
- **相关文档**：[Mac 会话查看](mac-session-view.md)、[数据流](../data-flows.md#用量)。

## 主流程

1. 点击侧边栏“Usage”。
   - 系统反馈：页面以上次选过的范围打开（首次为 Today），Summary 与 Detail 随即填充；daemon 首次扫描还没完成时卡上方显示 `Scanning transcripts · N files left`，数字随扫描增长。
   - 规则引用：[USG-R-001](#usg-r-001-用量来自-agent-的本机记录与-session-无关)、[USG-R-004](#usg-r-004-页面可见时自动刷新)。
2. 在页头选时间范围：Today、This week（周一起）、This month，或 Custom。
   - 系统反馈：选 Custom 后出现两个日期框（起、止），止日不能晚于今天，起日不能晚于止日；范围一变，整页重算，趋势图的粒度也跟着变。
   - 规则引用：[USG-R-003](#usg-r-003-时间范围按本地日计闭区间)。
3. 看 Summary：Cost 下面一行是较上一周期的涨跌，Tokens 下面是四段构成条和缓存读 / 输出占比；右边的趋势图悬停任一根柱看当期明细。
   - 系统反馈：卡头切 `All agents · Claude Code · Codex` 只改这张卡——指标、构成条、趋势图一起换成该 Agent 的；趋势图右上角切 Cost / Tokens 只换 y 轴。
   - 规则引用：[USG-R-002](#usg-r-002-cost-是按公开价目的估算)、[USG-R-005](#usg-r-005-趋势图的粒度随范围而定)。
4. 看 Detail：`Group by` 切 Project、Agent、Time、Model；Time 时再选 Day / Week / Month。点表头按该列排序，再点一次反向；Agent 分组下点行首箭头展开或收起它的模型子行。
   - 系统反馈：Detail 不跟随 Summary 的 Agent 过滤，过滤生效时卡头右端提示 `Not filtered by the Summary agent`；没有公开价格的模型 Cost 为 `—`，表尾一行说明有多少 token 没有价格。
   - 规则引用：[USG-R-002](#usg-r-002-cost-是按公开价目的估算)、[USG-R-006](#usg-r-006-sessions-与-turns-是去重计数)。

完成信号：Summary 的 Cost 与 Detail 按 Agent 分组的 Total 行一致；页头右侧显示 `Prices · models.dev · updated … ago`。

## 页面结构

- **页头**：范围分段控件（Today · This week · This month · Custom）+ Custom 的两个日期框；右侧是价目状态——`Prices · models.dev · updated 3h ago`，daemon 从未成功联网时显示 `Prices · built-in snapshot`。
- **Summary 卡**
  - 左栏：Cost（范围内有价格部分的总花费；下一行 `↑ 12% vs yesterday` / `vs last week` / `vs last month` / `vs previous 30 days`，上一周期没有数据时写 `no comparable previous period`）；Tokens（输入 + 缓存读 + 缓存写 + 输出；下面一条构成条按 Input → Cache read → Cache write → Output 分四段，再一行 `Cache read 88.6% · output 2.6%`）；Sessions（去重的会话数，Subagent 归入父会话）、Turns（去重的回合数）、Calls（模型调用次数）。
  - 右栏：趋势图。All agents 时按 Claude Code / Codex 两段堆叠；只看一个 Agent 时按它用过的模型堆叠，没有价格的模型是灰段、图例后缀 `· no price`。悬停一根柱，其它柱变淡、柱顶出现当期的日期、总额和每一段的数字（当期为 0 的段不列）。
  - 卡头：Agent 分段，只作用于这张卡。
- **Detail 卡**：一张表，四种分组各取同一列序（Sessions · Turns · Input · Cache read · Cache write · Output · Cache ratio · Tokens · Cost · Last active）的子集——
  - Project：Project（目录名 + `~` 缩写路径，悬停看全路径）· Sessions · Turns · Cache ratio · Tokens · Cost · Last active。
  - Agent：Agent · Model（Agent 组行可折叠，模型是子行，Total 固定末尾）· Input · Cache read · Cache write · Output · Cache ratio · Tokens · Cost。
  - Time：Day / Week / Month（最新的在上；行名如 `Sat, Sep 5`、`Aug 31 – Sep 6`、`September 2026`）· Sessions · Turns · Input · Cache read · Output · Tokens · Cost。
  - Model：Model（带 Agent 图标）· Input · Cache read · Output · Cache ratio · Tokens · Cost。
- **工具栏**：标题 Usage 与 Refresh（立即重拉当前范围）。

## 规则

### USG-R-001 用量来自 Agent 的本机记录，与 Session 无关

- 条件：daemon 运行中。
- 行为：daemon 扫描 `~/.claude/projects` 与 `~/.codex/sessions`、`~/.codex/archived_sessions` 下的全部对话记录（含 Claude 子 Agent），每 30 秒跟进新写入。
- 结果：安装 Lumi 之前的会话、没触发 Hook 的会话、被 Filters 隐藏的会话都计入；删除 Session 或 Clear history 不改变 Usage。
- 限制或例外：只统计这台 Mac 上的文件；Agent 自己删掉的记录随之消失；没有 token 的占位消息（Claude 的 `<synthetic>`）不算调用、不出现在任何表里。

### USG-R-002 Cost 是按公开价目的估算

- 条件：模型在 models.dev 价目表里有该模型的价格。
- 行为：按公开价目计算：未缓存输入、缓存读、缓存写（1 小时档按 2 倍输入价）、输出分别计价；一次调用的上下文超过模型的长上下文阈值（如 OpenAI 模型 272K）时，这次调用整体按高档价计；daemon 每 24 小时刷新价目，刷新后对历史范围同样生效。
- 结果：Cost 反映公开 API 价，不是账单，也不含订阅套餐的折算。
- 限制或例外：价目表里没有的模型（如 `codex-auto-review`）Cost 显示 `—`，其 token 计入 Tokens 但不计入任何 Cost；趋势图里它们是灰段，切到 Tokens 时才有高度；范围内全部模型都没有价格时 Cost 显示 `—`、趋势图落到 Tokens。

### USG-R-003 时间范围按本地日计，闭区间

- 条件：用户选择任一范围。
- 行为：以这台 Mac 的本地日为单位，起止都包含；This week 从周一起；Custom 的止日不能晚于今天，起日不能晚于止日，最长 366 天。
- 结果：跨午夜的回合按每次模型调用的发生日（和小时）分别计入。
- 限制或例外：改系统时区后，历史记录仍按扫描时的本地日归档。

### USG-R-004 页面可见时自动刷新

- 条件：Usage 页在前台。
- 行为：每 30 秒重拉一次当前范围；切换范围或点 Refresh 立即重拉；离开页面停止。
- 结果：正在进行的会话在页面上持续增长，数字原地更新、不闪加载态；上次选过的范围、Summary 的 Agent、趋势指标、Detail 的分组与粒度下次打开仍在。
- 限制或例外：daemon 不可达时保留上次的数字并在页首显示错误；恢复后下一次刷新自动接上。

### USG-R-005 趋势图的粒度随范围而定

- 条件：任一范围。
- 行为：Today 按小时画 24 根柱；This week 画周一到周日、This month 画 1 号到月末（未来的日子是空柱）；Custom 按天，超过 90 天改按周。
- 结果：x 轴标签跟着粒度变（每 3 小时、星期缩写、每 5 天一个 `月/日`、隔一周）；涨跌行比较的上一周期也随范围定——昨天、上周同几天、上月同几天、之前的 N 天。
- 限制或例外：范围内没有任何调用时只剩网格与 0 轴，不写数字、不画图例。

### USG-R-006 Sessions 与 Turns 是去重计数

- 条件：任一分组。
- 行为：每一行的 Sessions / Turns 在该行范围内去重（Subagent 与父会话算同一个）。
- 结果：跨行不能相加；Agent 与 Model 分组不给这两列，Total 行也不合计它们。
- 限制或例外：Summary 的 Sessions / Turns 是整个范围（或所选 Agent）的去重数，与 Detail 各行之和不对账。

## 空状态与故障

- **No usage in this range**：范围内没有任何模型调用；换个范围。Detail 卡此时不显示。
- **No usage yet**：daemon 还没在这台 Mac 上找到任何对话记录。
- **Scanning transcripts · N files left**：首次扫描进行中，数字不完整；扫完自动消失。
- **页首红色告警条**：daemon 不可达或拒绝请求，上一次的数字留在下面；参照[恢复路径](../friction-points.md)。

## 相关文档

- [功能全景](../index.md)
- [Mac 会话查看](mac-session-view.md)
- [数据流](../data-flows.md)
- [Usage 设计](../../design/usage.md)
- [已知问题：`codex-auto-review` 没有价目](../../issues/codex-auto-review-model.md)
