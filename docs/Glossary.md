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

## 时间概念

| 概念                                             | 界面用词    | 中文写法 |
| ------------------------------------------------ | ----------- | -------- |
| 距上次更新过去了多久（Session 行尾的相对时间）   | Last update | 最近更新 |
| 从启动到结束（或到现在）用了多久（Subagent 行尾）| Duration    | 持续时间 |

## 禁用说法

| 说法                         | 原因                                                                 |
| ---------------------------- | -------------------------------------------------------------------- |
| 到点自动换新、自动换一个新码 | 2026-08-28 起配对码到期只停在 Expired，不自动换；换码只有 New code。 |
