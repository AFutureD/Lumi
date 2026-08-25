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

## Activity 消息类别

Activity 里每条记录的 chip 标签，以及 Category 过滤面板里的名称。

| Chip | 面板名 | 含义 |
| --- | --- | --- |
| SESSION | Start / end | 会话开始 / 结束 |
| COMPACT | Compaction | 上下文压缩 |
| CONFIG | Configuration | 配置：Agent 怎么跑（设置、工作目录、模型档位） |
| CONTEXT | Context | 注入上下文：模型读到的、非用户键入的内容 |
| USER | User input | 用户输入 |
| REASONING | Thinking | 思考 |
| ASSISTANT | Reply | 回复 |
| PLAN | Plan | 计划 |
| SUBAGENT | Subagent | 子 Agent |
| TURN END | Turn end | 回合结束 |
| FAILED | Turn failure / Tool failure | 回合失败（Model 泳道）/ 工具失败（Exec 泳道），同一个 chip |
| ABORTED | Interrupted | 中断 |
| TOOL | Tool call | 工具调用 |
| RESULT | Tool result | 工具结果 |

## 推送提醒

| 场景 | 界面写法 | 含义 |
| --- | --- | --- |
| iPhone 设置行 | Push notifications | 通知权限的三态入口（Allow / Allowed / Not allowed） |
| 文档叫法 | 推送提醒 | Session 回合结束、失败或中断时发到 iPhone 的系统通知 |

通知本身没有新词：标题就是 Session 标题，副标题是它的状态（Completed / Failed / Interrupted，与状态胶囊同一套词）。

## 软件更新

| 场景 | 界面写法 | 含义 |
| --- | --- | --- |
| 设置分区 | Software Updates | 管理 Lumi for Mac 的更新检查方式 |
| 主动检查 | Check for Updates… | 立即向稳定更新通道检查新版本 |
| 自动检查 | Automatically check for updates | 允许 Lumi 定期检查新版本，但不静默下载或安装 |
| 自动检查已开启 | Automatic checks on | Lumi 会定期检查新版本 |
| 自动检查已关闭 | Automatic checks off | Lumi 只在用户主动要求时检查新版本 |
| 更新通道 | Stable | 只接收正式发布版本 |

## 弃用词

| 不再用 | 原因 |
| --- | --- |
| CONTEXT ×N | 2026-08-24 起相邻上下文不再合并；一条记录一行 CONTEXT |
| Session context / Turn context | 上下文不再分两档：模型读的叫 Context，Agent 的运行方式叫 Configuration |
