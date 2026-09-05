# 术语表

产品叫什么、界面上用什么词。写任何用户能看到的文字之前，先来这里对一遍。

这份文档只管说法，不管实现。代码里的模块名、路径、参数不在这里。

## 产品名

| 场景      | 写法            |
| --------- | --------------- |
| 产品      | Lumi            |
| Mac 端    | Lumi for Mac    |
| iPhone 端 | Lumi for iPhone |

只有英文名，没有中文名。中文句子里直接写 Lumi，不翻译、不加括号注释。

## 应用程序

| 部分         | 英文  |
| ------------ | ----- |
| iOS，macOS   | Lumi  |
| macOS Daemon | Lumen |
| macOS Helper | Spark |
| Relay        | Ray   |
| macOS Notch  | Halo  |

## Agent 来源

| 概念                                              | 写法                            |
| ------------------------------------------------- | ------------------------------- |
| 运行会话的引擎（Codex、Claude） | Agent |
| 承载会话的应用层，会话的标题由它决定（ChatGPT、Codex、Claude Desktop、Claude Code、Paseo、Raft） | AaaS（Agentic AI as a Service） |
| Session 详情 Overview 里显示归属 AaaS 的那一栏（值为上述六个名字之一；注意与 Settings 侧栏的 Application 分组同词不同义） | Application |

## Settings · Agents

| 概念 | 界面用词 | 中文写法 |
| ---- | -------- | -------- |
| 向 Lumi 上报 Session 事件的各个 agent 接入（装 / 卸 / 信任） | Integrations | 接入 |
| 把幽灵 Session 挡在列表外的那组规则（Settings 里编辑） | Filters | 过滤规则 |
| 一条规则 | Filter | 规则 |
| 测试、一次性调用等不想在列表里看到的 Session | ghost Session | 幽灵 Session |
| 规则的四个字段 | Agent · Application · User message · Folder | 不翻译 |
| 规则的运算 | is · contains · starts with | 不翻译 |

- Filters 里的 Application 与 Session 详情 Overview 的 Application 栏同义（AaaS 六个名字之一）。
- 同词不同义：Activity 时间线里按 Category / Importance 筛行的控件也叫过滤器，但那是看时的显示筛选，与 Settings 的 Filters（决定 Session 是否被隐藏）是两回事。

## 配对

| 概念                                   | 界面用词         | 中文写法 |
| -------------------------------------- | ---------------- | -------- |
| iPhone 输入的那 6 位                   | Code             | 配对码   |
| 码还能用多久                           | Expires in       | 倒计时   |
| 码到点作废后卡片停住的状态             | Expired          | 已失效   |
| 再出一个码（唯一的换码方式）           | New code         | 换新码   |

## Usage

| 概念 | 界面用词 | 中文写法 |
| ---- | -------- | -------- |
| 侧边栏里按项目、模型看 token 与花费的那一页 | Usage | 用量 |
| 页面上半张卡：两个大数字、token 构成条、三个小数字和趋势图 | Summary | 总览 |
| 页面下半张卡：一张可换分组维度的明细表 | Detail | 明细 |
| 按公开价目估算出的美元数 | Cost | 花费 |
| 模型处理过的 token 总数（输入 + 缓存读 + 缓存写 + 输出） | Tokens | token |
| Cost 与上一周期相比的涨跌（`↑ 12% vs yesterday`；上一周期没有数据时写 `no comparable previous period`） | vs yesterday · vs last week · vs last month · vs previous N days | 较上一周期 |
| Tokens 下面那条 6pt 的条，按四类拆开、合计恒为 100% | Input · Cache read · Cache write · Output | token 构成 |
| 范围内模型被调用的次数 | Calls | 调用次数 |
| Summary 卡头的过滤器，只作用于 Summary | All agents · Claude Code · Codex | Agent 过滤 |
| Summary 右侧按时间画的堆叠柱状图；单日按小时、90 天内按天、更长按周 | Cost per day · Tokens per hour …（趋势图） | 趋势图 |
| 趋势图 y 轴量什么 | Cost · Tokens | 趋势指标 |
| Detail 表的分组维度 | Group by · Project · Agent · Time · Model | 分组 |
| Time 分组下一行代表多长 | Day · Week · Month | 时间粒度 |
| Summary 的 Agent 过滤生效时 Detail 卡头的提示 | Not filtered by the Summary agent | 明细不受过滤影响 |
| 用量表格里的“项目”，即 Agent 运行时的工作目录（与 Filters 的 Folder 同一事物，Usage 页叫 Project） | Project | 项目 |
| 模型的原始 id（如 `claude-fable-5`、`gpt-5.5`），照 Agent 上报的原样显示 | Model | 模型 |
| 时间范围的四个档位 | Today · This week · This month · Custom | 今天 · 本周 · 本月 · 自定义 |
| 价目表里没有的模型，其 token 不计入任何 Cost；趋势图里是灰段，图例后缀 `· no price` | Unpriced（表里显示 `—`） | 无价格 |
| 缓存读取占全部 token 的比例（cache read ÷ total） | Cache ratio | 缓存命中率 |
| 页头右侧说明价目表来自哪、多久前更新 | Prices · models.dev · updated … ago / Prices · built-in snapshot | 价格更新时间 |

- Usage 与 Session 无关：删除 Session、清空历史都不会改变 Usage 的数字。
- Cost 是按公开价目算出的估算值，不是账单，也不含订阅套餐的折算。
- Usage 页里 Claude 的 Agent 一律写 `Claude Code`（会话列表里的 Agent 名仍是 `Claude`）。
- Sessions 与 Turns 是去重计数，跨 Agent 不能相加：Agent 与 Model 分组不列这两列。

## 时间概念

| 概念                                             | 界面用词    | 中文写法 |
| ------------------------------------------------ | ----------- | -------- |
| 距上次更新过去了多久（Session 行尾的相对时间）   | Last update | 最近更新 |
| 从启动到结束（或到现在）用了多久（Subagent 行尾）| Duration    | 持续时间 |

## 禁用说法

| 说法                         | 原因                                                                 |
| ---------------------------- | -------------------------------------------------------------------- |
| 到点自动换新、自动换一个新码 | 2026-08-28 起配对码到期只停在 Expired，不自动换；换码只有 New code。 |
