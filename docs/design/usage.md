# Usage 设计

> 基线：2026-09-05 当前仓库实现。Usage 是与 Session 平行的一条链路：daemon 直接读 Agent 自己的对话记录统计 token，按 models.dev 价目计价，只在 Mac 的 Usage 页展示。

## 目标与边界

- 回答"这台 Mac 上的 Claude Code / Codex 在某段时间花了多少 token、多少钱、花在哪个项目和模型上"。
- 数据来源是 Agent 的本机文件，不是 Lumi 的 Session：没进列表的会话（安装 Lumi 之前的、被 Filters 隐藏的、从未触发 Hook 的）也计入；删除 Session、Clear history、reingest 都不影响 Usage。
- 计价是估算：按公开价目，含长上下文分档（一次调用的上下文超过模型阈值就整次按高档计），不含批量 / Flex / 速度档，不含订阅套餐折算；没有公开价格的模型单独标出、不计入任何 Cost。
- 只有 Mac 页面；不进 Relay，不进 iPhone。

## 数据来源

| Agent | 目录 | 记录 | 识别方式 |
| --- | --- | --- | --- |
| Claude Code | `~/.claude/projects/**/*.jsonl`（`CLAUDE_CONFIG_DIR` 覆盖根目录；含 `subagents/agent-*.jsonl`） | `assistant` 记录的 `message.usage`（`input_tokens`、`cache_read_input_tokens`、`cache_creation.ephemeral_5m/1h_input_tokens`、`output_tokens`、`output_tokens_details.thinking_tokens`）；记录级 `costUSD`（旧版本写）；`usage.iterations[]` 里 `advisor_message` 的独立用量 | 同一条 message 的每个内容块都重复整份 usage，按 `message.id + requestId` 去重，但流式写入时后面的内容块会带更大的 `output_tokens`：取最大的那份——后到的、更大的副本以「补足记录」（去重键加 `:more:<total>`，不计入调用数）把差额补上；`isSidechain == true` 记为 Claude Subagent，session id 仍是文件里记的父 id；advisor 迭代按自己的 model 单独成一条记录（去重键加 `:advisor:<i>`） |
| Codex | `~/.codex/sessions/**/*.jsonl` 与 `~/.codex/archived_sessions/*.jsonl`（`CODEX_HOME` 覆盖） | `event_msg/token_count.info`：`last_token_usage`（每次调用）与 `total_token_usage`（累计） | 第一条 `session_meta` 定 session id 与 cwd（fork 回放的祖先 meta 不覆盖）；`turn_context` 沿用 turn id / model / cwd；累计值是基线——累计不变的事件是重发、不计；累计回退是 reset，有 `last` 照计、无 `last` 不计；只有累计没有 `last` 时按累计差计；没有累计时按连续相同的 `last` 去重；`input_tokens` 含 cached 部分，未缓存输入 = input − cached − cache_write；`source.subagent` 存在记为 Codex Subagent；在任何 `turn_context` 之前出现的调用先挂起，等下一条 context 补上 turn / model / cwd 再入库（再来一条调用、或本次读到文件末尾，则原样放行；挂起从不跨读保存）；分叉 / 派生（`forked_from_id` 或 `source.subagent`）的 rollout 开头是祖先历史的副本，且时间戳被改成复制那一刻——复制期间的 `token_count` 不计（只推进累计基线），直到子线程自己的 `session_meta` 再次出现，或某条调用与上一行相隔超过 1 秒（真实调用总要等模型往返） |

Turn 归属：Claude 用与 Session 相同的内容规则（human 来源的 prompt 开 Turn，`promptId ?? uuid` 命名；注入的 resume 不开）；Codex 用 `turn_context.turn_id`。拿到 turn id 之前的记录 `turn_id = ''`，报表里并入同一 session、不计入 Turn 数。

计数校验：每个 token 计数必须是非负整数（不是布尔、不是小数、不超过 10^15），`costUSD` 必须是非负有限数；不合法的行整行拒绝、只记位置，其余行照常。

## 存储

三张表随 `sessions.sqlite3` 一起迁移（`lumi-v9-usage` 建表；解析规则变更时用一条新 migration 整体重建三张表，让下次启动重扫——`lumi-v10-usage-rules` 是第一次），与 `sessions` 没有外键：

| 表 | 内容 | 规则 |
| --- | --- | --- |
| `usage_buckets` | 主键 `(agent, session_id, turn_id, model, day, tier)`；`tier` 是长上下文档位（0 = 基础档，n = 价目第 n 档），扫描器入库前按「上下文 = 未缓存输入 + 缓存读 + 缓存写」对照当时价目的阈值判定（超过才进高档；补足记录沿用整次调用的上下文）；`workspace`（桶内首条记录的 cwd）、`first_at` / `last_at`、六类 token（input / cache_read / cache_write_5m / cache_write_1h / output / reasoning）、`calls`（补足记录不计）、`reported_cost_usd` / `reported_calls`（来源自己报告的费用之和与条数） | `day` 是记录时间戳的**本地日**（daemon 的 `Calendar.current`）；同一桶累加 |
| `usage_seen` | 全局去重键 | Claude `claude:<message.id>:<requestId>`；Codex `codex:<timestamp>:<fnv1a(增量签名)>`——fork 回放、resume 复制历史、文件被重写后从头重扫，都只算一次 |
| `usage_cursors` | 主键 `identity` = `<source>:<设备号>:<inode>`；`path`（最近一次看到的路径）、`byte_offset`、`file_size`、`modified_at`、`prefix_length` / `prefix_hash`（文件前 4 KB 的 SHA-256）、解析状态 BLOB（当前 turn、Codex 的 session / cwd / model / 累计基线 / 挂起的调用） | 文件移动（Codex `archive`）inode 不变，游标只换路径、不重读；文件变短、同大小但 mtime 变、或前缀哈希变都视为重写，从 0 重读、状态清零（去重键保证不重复计数） |

桶里只存 token，不存钱：价目更新对历史生效。

## 扫描

`UsageScanService`（daemon 内，`Service`）：启动全量列文件，之后每 30 秒重列一次；按 inode 对上游标后，只有 `(size, mtime)` 与游标不同的文件才打开（mtime 按毫秒比较，SQLite 往返会带纳秒噪声），路径变了的只改游标里的路径；每个文件一个事务（去重键 → 桶 upsert → 游标），文件之间 `Task.yield()`，首扫本机约 1,700 个文件 / 1 GB 用时 20–25 秒，不阻塞 hook 路径。行级门槛（Claude `"usage"` / `"promptId"`，Codex `"token_count"` / `"turn_context"` / `"session_meta"`）先于 JSON 解析，坏行只记位置、跳过不中断。

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

## IPC 与报表

`usage_report {since, until}`（本地日闭区间，跨度 ≤ 366 天）→ `UsageReport`：

- `totals` 与 `byAgent` / `byProject`（按 `workspace`）/ `byModel`（按 provider + model）四组 `UsageSlice`：六类 token、`costUSD`（只含有价格部分；全无价格时为 nil）、`unpricedTokens`、`calls`、`sessions`（去重 session id；Subagent 与父级同一个）、`turns`（去重 (session, turn)）、`lastDay`。
- `pricing`：价目来源（builtin / cached / fresh）、拉取时间、模型数。
- `scan`：已扫文件数、待扫文件数、上次扫描时间、是否正在扫。

聚合在 daemon 内存里完成（`UsageReportBuilder`，纯函数）：一年的桶通常几万行，一次 IPC 帧即可。

## Mac 页面

侧边栏 Monitor 组的 Usage 页，收起中栏。subheader：`Today · This week · This month · Custom` 分段控件（周从周一起，Custom 时出现两个日粒度日期选择器，结束日不晚于今天），右侧 `Prices · models.dev · updated 3h ago` / `Prices · built-in snapshot`。主体：四张指标卡（Cost / Tokens / Sessions / Turns）→ By agent（Claude / Codex 组行可折叠，模型是组内子行，Total 固定在末尾；含 Cache ratio = cache read ÷ total；无价格显示 `—`，表尾注明多少 token 没有价格）→ By project（目录名 + `~` 缩写路径，含 Cache ratio；列可点排序，组行与子行各自排）。页面可见时每 30 秒重拉，切换范围或工具栏 Refresh 立即重拉；上次选择的范围记在 UserDefaults。

## 与 ccusage 的对账

2026-09-05 用 `npx ccusage@latest claude daily --json` / `codex daily --json` 对 08-01..09-04 逐日对账：token 各字段完全一致（Claude 的 `output_tokens` 靠「取最大副本」对齐，Codex 的分叉日靠复制期判定对齐）。长上下文分档两边口径一致（超过阈值整次按高档）；剩余费用差只来自 ccusage 对 `codex-auto-review` 按日期猜模型计价，Lumi 记为无价格。

## 当前限制

- 不区分服务档位（standard / fast / batch）。
- Codex 分叉回放靠「复制期间时间戳成簇」判定；若将来 Codex 保留原始时间戳复制，则由全局去重键（时间戳 + 用量签名）吸收。子线程首次真实调用若在复制结束 1 秒内到达会被当成副本漏掉。
- `day` 用扫描时的本地时区，之后改时区不会重算历史桶。
- Codex 已归档会话也计入，但 Codex 在别的机器上产生的会话不会出现。
- iPhone 没有 Usage。

## 相关文档

- [数据、通信与保存设计](data-communication-storage.md)
- [Agent Hook 设计](agent-hook.md)
- [日志设计](logging.md)
- [Mac 用量查看（产品文档）](../feat/modules/mac-usage.md)
