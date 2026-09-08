# Usage 设计

> 基线：2026-09-08 当前仓库实现。Usage 是与 Session 平行的一条链路：daemon 直接读 Agent 自己的对话记录统计 token，按 models.dev 价目计价；Mac 的 Usage 页看全貌（Summary + Detail），iPhone 的 Usage Tab 看 Summary（经 Relay 向每台 Mac 索取）。

## 目标与边界

- 回答"这台 Mac 上的 Claude Code / Codex 在某段时间花了多少 token、多少钱、花在哪个项目和模型上"。
- 数据来源是 Agent 的本机文件，不是 Lumi 的 Session：没进列表的会话（安装 Lumi 之前的、被 Filters 隐藏的、从未触发 Hook 的）也计入；删除 Session、Clear history、reingest 都不影响 Usage。
- 计价是估算：按公开价目，含长上下文分档（一次调用的上下文超过模型阈值就整次按高档计），不含批量 / Flex / 速度档，不含订阅套餐折算；没有公开价格的模型单独标出、不计入任何 Cost。
- 两个消费者：Mac 的 Usage 页（Summary + Detail），iPhone 的 Usage › History（只有 Summary；按项目 / Agent / 模型分组的 Detail 表留在 Mac）。两端都只读，daemon 是唯一数据源，iPhone 不落盘。

## 数据来源

| Agent | 目录 | 记录 | 识别方式 |
| --- | --- | --- | --- |
| Claude Code | `~/.claude/projects/**/*.jsonl`（`CLAUDE_CONFIG_DIR` 覆盖根目录；含 `subagents/agent-*.jsonl`） | `assistant` 记录的 `message.usage`（`input_tokens`、`cache_read_input_tokens`、`cache_creation.ephemeral_5m/1h_input_tokens`、`output_tokens`、`output_tokens_details.thinking_tokens`）；记录级 `costUSD`（旧版本写）；`usage.iterations[]` 里 `advisor_message` 的独立用量 | 同一条 message 的每个内容块都重复整份 usage，按 `message.id + requestId` 去重，但流式写入时后面的内容块会带更大的 `output_tokens`：取最大的那份——后到的、更大的副本以「补足记录」（去重键加 `:more:<total>`，不计入调用数）把差额补上；`isSidechain == true` 记为 Claude Subagent，session id 仍是文件里记的父 id；advisor 迭代按自己的 model 单独成一条记录（去重键加 `:advisor:<i>`） |
| Codex | `~/.codex/sessions/**/*.jsonl` 与 `~/.codex/archived_sessions/*.jsonl`（`CODEX_HOME` 覆盖） | `event_msg/token_count.info`：`last_token_usage`（每次调用）与 `total_token_usage`（累计） | 第一条 `session_meta` 定 session id 与 cwd（fork 回放的祖先 meta 不覆盖）；`turn_context` 沿用 turn id / model / cwd；累计值是基线——累计不变的事件是重发、不计；累计回退是 reset，有 `last` 照计、无 `last` 不计；只有累计没有 `last` 时按累计差计；没有累计时按连续相同的 `last` 去重；`input_tokens` 含 cached 部分，未缓存输入 = input − cached − cache_write；`source.subagent` 存在记为 Codex Subagent；在任何 `turn_context` 之前出现的调用先挂起，等下一条 context 补上 turn / model / cwd 再入库（再来一条调用、或本次读到文件末尾，则原样放行；挂起从不跨读保存）；分叉 / 派生（`forked_from_id` 或 `source.subagent`）的 rollout 开头是祖先历史的副本，且时间戳被改成复制那一刻——复制期间的 `token_count` 不计（只推进累计基线），直到子线程自己的 `session_meta` 再次出现，或某条调用与上一行相隔超过 1 秒（真实调用总要等模型往返） |

Turn 归属：Claude 用与 Session 相同的内容规则（human 来源的 prompt 开 Turn，`promptId ?? uuid` 命名；注入的 resume 不开）；Codex 用 `turn_context.turn_id`。拿到 turn id 之前的记录 `turn_id = ''`，报表里并入同一 session、不计入 Turn 数。

计数校验：每个 token 计数必须是非负整数（不是布尔、不是小数、不超过 10^15），`costUSD` 必须是非负有限数；不合法的行整行拒绝、只记位置，其余行照常。

## 存储

三张表随 `sessions.sqlite3` 一起迁移（`lumi-v9-usage` 建表；解析规则或桶主键变更时用一条新 migration 整体重建三张表，让下次启动重扫——`lumi-v10-usage-rules` 因解析规则、`lumi-v11-usage-hour` 因主键加小时），与 `sessions` 没有外键：

| 表 | 内容 | 规则 |
| --- | --- | --- |
| `usage_buckets` | 主键 `(agent, session_id, turn_id, model, day, hour, tier)`；`hour` 是记录时间戳的本地小时（0–23，Today 趋势图的一根柱）；`tier` 是长上下文档位（0 = 基础档，n = 价目第 n 档），扫描器入库前按「上下文 = 未缓存输入 + 缓存读 + 缓存写」对照当时价目的阈值判定（超过才进高档；补足记录沿用整次调用的上下文）；`workspace`（桶内首条记录的 cwd）、`first_at` / `last_at`、六类 token（input / cache_read / cache_write_5m / cache_write_1h / output / reasoning）、`calls`（补足记录不计）、`reported_cost_usd` / `reported_calls`（来源自己报告的费用之和与条数） | `day` / `hour` 取记录时间戳的**本地日与小时**（daemon 的 `Calendar.current`）；同一桶累加 |
| `usage_seen` | 全局去重键 | Claude `claude:<message.id>:<requestId>`；Codex `codex:<timestamp>:<fnv1a(增量签名)>`——fork 回放、resume 复制历史、文件被重写后从头重扫，都只算一次 |
| `usage_cursors` | 主键 `identity` = `<source>:<设备号>:<inode>`；`path`（最近一次看到的路径）、`byte_offset`、`file_size`、`modified_at`、`prefix_length` / `prefix_hash`（文件前 4 KB 的 SHA-256）、解析状态 BLOB（当前 turn、Codex 的 session / cwd / model / 累计基线 / 挂起的调用） | 文件移动（Codex `archive`）inode 不变，游标只换路径、不重读；文件变短、同大小但 mtime 变、或前缀哈希变都视为重写，从 0 重读、状态清零（去重键保证不重复计数） |

桶里只存 token，不存钱：价目更新对历史生效。

## 扫描

`UsageScanService`（daemon 内，`Service`）：启动全量列文件，之后每 30 秒重列一次；按 inode 对上游标后，只有 `(size, mtime)` 与游标不同的文件才打开（mtime 按毫秒比较，SQLite 往返会带纳秒噪声），路径变了的只改游标里的路径；每个文件一个事务（去重键 → 桶 upsert → 游标），文件之间 `Task.yield()`，首扫本机约 1,700 个文件 / 1 GB 用时 20–25 秒，不阻塞 hook 路径。行级门槛（Claude `"usage"` / `"promptId"`，Codex `"token_count"` / `"turn_context"` / `"session_meta"`）先于 JSON 解析，坏行只记位置、跳过不中断。

没有 token 也没有报告费用的记录不是一次模型调用：解析器出口统一过滤（Claude 的 `<synthetic>` 占位消息——"No response requested"、中断提示——usage 全是 0；Codex 增量为 0 的事件；空的 advisor 迭代）；报表构建时再过滤一遍空桶，早于这条规则入库的数据无需重扫。

与 Session 采集的 rollout 游标（`rollout_cursors`）互不相干：两套游标、两套解析器，Usage 不经过 `AgentAdapter` 与 reducer。

## 计价

`ModelPriceRefresher`（daemon 内，`Service`）：

1. 启动先读 `Lumen/models-dev.json`（上次拉取的 `api.json` 原文，文件 mtime 即拉取时间）；没有就用编译进二进制的快照（`ModelPricingSnapshot`，由 `scripts/models-dev-snapshot.sh` 生成，保留全部 provider 的 `cost` 与 `limit.context`）。
2. 每 15 分钟检查一次，上次拉取超过 24 小时就重新拉 `https://models.dev/api.json`，原子写回缓存；失败保留现有表。`LUMI_MODEL_PRICES=0` 关闭联网（测试、离线）。

价目里的长上下文档：models.dev `cost.tiers`（只取 `type == context`，按 size 升序；档内没写的费率沿用基础档），只有旧字段 `context_over_200k` 的按 200K 一档。目前只有 OpenAI 的模型有档（阈值 272K），Anthropic 没有。档位在入库时定死，价目以后改阈值不追溯历史；报表时价目里已没有那一档则用最高的一档。

查找顺序（`ModelPriceTable.price(for:agent:)`）：Agent 对应 provider（Claude → `anthropic`，Codex → `openai`）精确 id → 去掉 `-YYYYMMDD` / `-YYYY-MM-DD` 后缀 → 别名表（`gpt-5.6 → gpt-5.6-sol`、`gpt-5.3-spark → gpt-5.3-codex-spark`）→ 其他 provider 同 id（按 provider id 排序取第一个）→ 无价格。`<synthetic>`、`opus` / `sonnet` / `haiku` / `fable` 这类裸家族名直接无价格。

来源自己报告了费用的调用（Claude Code 旧版本的 `costUSD`）优先：一个桶里每次调用都带报告费用时，用报告之和；否则整桶按价目估算（混合桶无法拆 token）。

估算成本（价目单位为每百万 token 美元）：

```
input × in + cache_read × (cache_read ?? in) + cache_write_5m × (cache_write ?? in)
  + cache_write_1h × 2 × in + output × out
```

1 小时缓存写按 Anthropic 公布的 2× input 计（models.dev 只有 5 分钟档）；provider 没公布缓存价的（OpenAI 无 cache_write）按 input 计，而不是按免费计。

## 报表：IPC 与 Relay

两个入口，一份构建（daemon 内 `UsageReporting`：范围校验 → 读桶 → 在 `DaemonService` actor 之外的 detached task 里由纯函数 `UsageReportBuilder` 折叠；一年的桶通常几万行，一帧即可）：

- **IPC `usage_report {since, until, compareSince?, compareUntil?}`**（Mac）：本地日闭区间，跨度 ≤ 366 天。上一周期由 Mac 定（Today → 昨天；This week → 上周同几天；This month → 上月同几天；Custom N 天 → 之前的 N 天），daemon 只校验两段并从同一次桶快照算出两段。
- **Relay `fetch_usage {usageRange}`**（iPhone）：只给档位 `today` / `thisWeek` / `thisMonth`（`UsageRangePreset`，wire 上没有 Custom），daemon 用**自己的本地日历**展开成 since / until 与对比区间（同一份 `UsageRange` 算法，Core 共享），答 `usage_report {usage, requestID}`。这样 iPhone 与 Mac 跨时区、或多台 Mac 跨时区时，每台 Mac 的数字都与它自己的 Usage 页一致；`usage` 缺失表示 daemon 没建出报表（日志 `usage_relay_failed` / `usage_relay_too_large`），iPhone 显示拉取失败而不是干等超时。

`UsageRangeKind`（Core，含 `custom`，Mac 的分段控件）与 `UsageRangePreset`（Transport，三个档位）是两个枚举：前者是页面的选择，后者是能上 wire 的子集，互转在 Core。

`UsageReport`：

- `totals` 与 `byAgent` / `byProject`（按 `workspace`）/ `byModel`（按 provider + model，带价目来源 `provider`：自家 provider 或字母序第一个列出该模型的其它家，界面暂不显示）四组 `UsageSlice`：六类 token、`costUSD`（只含有价格部分；全无价格时为 nil）、`unpricedTokens`、`calls`、`sessions`（去重 session id；Subagent 与父级同一个）、`turns`（去重 (session, turn)）、`lastDay`。
- `byDay` / `byWeek` / `byMonth`：按时段的切片（`period` = 单位 + 起始日；周从周一起，月为自然月），只有有调用的时段成行，升序。Detail 的 Time 分组直接用它们，所以 Sessions / Turns 在周、月上也是准确的去重数。
- `trendUnit` + `trend`：趋势图的行，粒度由 daemon 按范围定（单日 = hour，≤ 90 天 = day，更长 = week），一行一个 (时段, agent, model)；客户端自己决定按 Agent 还是按模型堆叠，iPhone 点选一根柱子时的 Cost / Tokens 也直接从这些行求和（真实的按桶聚合，不是按比例推算）。
- `comparison`：上一周期的 `totals` 与 `byAgent`，供 Summary 的「较上一周期」用。
- `pricing`：价目来源（builtin / cached / fresh）、拉取时间、模型数。
- `scan`：已扫文件数、待扫文件数、上次扫描时间、是否正在扫。

Summary 的推导（大数字文案、构成条段、趋势图的柱与序列、y 轴的整数上限）是 Core 里的纯函数 `UsageSummaryFigures` / `UsageTrend`，Mac 与 iPhone 共用；颜色不在里面——段只说自己是哪类 token、序列只带色阶序号，两端各自映射到设计系统的图表序列。

## Mac 页面

侧边栏 Monitor 组的 Usage 页，收起中栏。subheader：`Today · This week · This month · Custom` 分段控件（周从周一起，Custom 时出现两个日粒度日期选择器，结束日不晚于今天），右侧 `Prices · models.dev · updated 3h ago` / `Prices · built-in snapshot`。主体是两张卡（取值全部来自设计系统 `DesignSystem.Usage` / `DesignSystem.Chart`，见 `DESIGN SYSTEM.html` §1.1「图表序列」）：

- **Summary**：卡头 Agent 分段（All agents · Claude Code · Codex），只作用于这张卡。左栏 Cost（大数字 + `↑ 12% vs yesterday` 涨跌）、Tokens（大数字 + 构成条 Input → Cache read → Cache write → Output + `Cache read 88.6% · output 2.6%`）、Sessions / Turns / Calls；右栏趋势图（Swift Charts）：All agents 时按 Agent 堆两段（序列 1 = Claude Code、序列 3 = Codex），单 Agent 时按它的模型堆（按 Cost 顺序取序列 1–4，无价格模型灰段、图例后缀 `· no price`）；坐标轴按范围铺满（Today 24 根小时柱、This week 周一到周日、This month 1 号到月末，未来时段空柱），四条虚线网格 + 0 轴，`chartXSelection` 悬停时其它柱降到 38% 并在柱顶出浮层（日期 + 总额 + 每序列一行）。指标分段 Cost / Tokens 只换 y 轴；范围内全部模型无价格时 Cost 显示 `—`、图落到 Tokens。
- **Detail**：卡头 `Group by` 分段（Project · Agent · Time · Model，Time 时再出 Day · Week · Month），Summary 的 Agent 过滤生效时右端提示 `Not filtered by the Summary agent`。一张表（`UsageTable`）：表头可点排序（数字列先降序、首列先升序，再点反向；组行与子行各自排），Agent 分组的 Agent 行可折叠（折叠集记在 `UsageModel`，换范围不重置）、Total 固定末尾；Agent 与 Model 分组不列 Sessions / Turns（去重数跨行不可加）；Time 分组最新的在上，行名 `Sat, Sep 5` / `Aug 31 – Sep 6` / `September 2026`。表尾脚注列出无价格的 token 数与模型数。
- **状态**：首次加载 `Loading usage…`；扫描中在卡上方压一条 `Scanning transcripts · N files left`（还没有桶时只有这条）；范围内无调用时 Summary 留着、指标为 `$0.00` / `0`、趋势图位置写 `No usage in this range`（从未扫到文件写 `No usage yet`）、Detail 不画；`usage_report` 失败时最顶一条红色告警条，上一次的数字留在下面。

页面可见时每 30 秒重拉（重拉不清空数字、不切加载态），切换范围或工具栏 Refresh 立即重拉；范围、Summary 的 Agent、趋势指标、Detail 的分组与粒度都记在 UserDefaults。

## iPhone

Usage Tab 的 History 段（设计交接 `design_handoff_ios_usage` 第 9 页），只有 Summary：

- 范围行两个菜单：`Today · This week · This month`（没有 Custom）和 scope（`All Macs` / 某台 Mac）。换档位时向每台配对的 Mac 发一次 `fetch_usage`；页面可见时每 30 秒再发，下拉刷新立即发，离开 Tab 停。答复只在内存里（`UsageSnapshot`：报表、档位、到达时间、加载中、错误），退出即忘，每次冷启动都是加载态。
- All Macs 是 iPhone 侧的合并（`UsageAggregate`，纯函数）：totals / byAgent / byModel / trend 按 (agent, model, 时段) 相加，Sessions / Turns 跨 Mac 相加（不同 Mac 的会话不会重复），有一台没有对比区间就不画涨跌；单台 scope 直接用那台的报表。各 Mac 的桶按各自的本地日对齐，iPhone 画坐标轴用自己的日历——跨时区时轴标签可能与某台 Mac 的日期差一天，数字不受影响。
- 数字卡 = Cost（带涨跌）、Tokens（带构成条）、Sessions / Turns / Calls，永远是整段所有 Agent 的合计；图卡的 agent 菜单只改图：All agents 按 Agent 堆两段，选单家按它的模型堆（份额前三 + `Other N models`），y 轴始终按 All agents 的桶峰值标定，所以只看一家时柱子整体变矮。点柱子读单桶：卡头换成桶名 + Clear，Cost / Tokens 换成该桶的合计（从 `trend` 行求和）。
- 状态：某台 Mac 离线 → 保留它上一份报表并注明 `<Mac> data as of 2h ago`；全部拉不到 → `Can't reach any Mac`；没有配对 Mac → `Pair a Mac`；有无价格模型 → `N models have no price · counted in tokens, not in cost`。

## 与 ccusage 的对账

2026-09-05 用 `npx ccusage@latest claude daily --json` / `codex daily --json` 对 08-01..09-04 逐日对账：token 各字段完全一致（Claude 的 `output_tokens` 靠「取最大副本」对齐，Codex 的分叉日靠复制期判定对齐）。长上下文分档两边口径一致（超过阈值整次按高档）；剩余费用差只来自 ccusage 对 `codex-auto-review` 按日期猜模型计价，Lumi 记为无价格。

## 当前限制

- 不区分服务档位（standard / fast / batch）。
- Codex 分叉回放靠「复制期间时间戳成簇」判定；若将来 Codex 保留原始时间戳复制，则由全局去重键（时间戳 + 用量签名）吸收。子线程首次真实调用若在复制结束 1 秒内到达会被当成副本漏掉。
- `day` 用扫描时的本地时区，之后改时区不会重算历史桶。
- Codex 已归档会话也计入，但 Codex 在别的机器上产生的会话不会出现。
- iPhone 的 History 不做 Custom 范围，也没有 Detail 表；点柱子是它唯一的单桶读数方式。

## 相关文档

- [数据、通信与保存设计](data-communication-storage.md)
- [Agent Hook 设计](agent-hook.md)
- [日志设计](logging.md)
- [Mac 用量查看（产品文档）](../feat/modules/mac-usage.md)
