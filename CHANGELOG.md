# Changelog

功能全景见 [FEAT.md](docs/FEAT.md)。  

## [Unreleased]

### 配对与同步

- [Lumi for iPhone] - 点开 Session 先看到最近的活动：第一次点开只取最新的一页（约 80 条），每到一片就显示；列表顶上出现 Load earlier 时点它再取更早的一页。此前要等整本时间线传完才显示，长会话要等几分钟。
- [Lumi for iPhone] - 超大的工具输出和上下文在手机上先只带摘要，活动详情页底部出现 Load full content，点一下从 Mac 取完整内容。
- [Lumi for iPhone] - 等不到 Mac 答复时不再整份重发、也不再把已收到的内容扔掉：30 秒没有新进展才重问一次，再等不到只放弃这一个请求；离开详情页时取消它的翻页请求。Mac 这边认出同一个 Session 的重复请求只答最新一份。
- [Lumi for iPhone] - 手机和 Mac 在同一个局域网时直接连接，不经 Relay；Macs 页显示 `Online · Direct`。直连断开后自动回到 Relay。第一次需要允许 Lumi 访问本地网络。
- Mac 与 iPhone 之间的连接有了心跳：断线 30 秒内发现，重连间隔 2 秒起逐次拉长到 30 秒。Relay 在设备配对、撤销或推送 token 变化时主动通知 Mac，Mac 不再每 10 秒轮询设备列表。
- 升级提示：Lumi for Mac、Lumi for iPhone 和 Relay 要一起更新到这一版。旧版 iPhone 连上新版 Relay 会收到提示更新并停止重试；Relay 的消息改为二进制，不再 Base64 放大。
- daemon 每次答复 iPhone 记一条 `request_answered`（片数、字节、准备与发送耗时、走的链路），Relay 对每帧转发记录大小。远程协议 1.3 → 1.4。

## [0.3.0] - 2026-11-08

### Daemon

- [Lumi for Mac] - “Settings > Daemon”不再只有 Running / Not connected：状态拆成 Not installed、Waiting for approval in Login Items、Not running、Starting…、Not responding、Incompatible daemon、Error，药丸按色区分，卡片底部写出原因；按钮跟着状态走（未安装 Install & Start、等待允许时 Open Login Items…、已注册 Reinstall / Stop & uninstall）。本地缓存数据库的错误单独显示，不再混进连接状态。
- [Lumi for Mac] - 卡片新增 Managed by 与 Process 两行：daemon 自述启动时生成的实例标识、pid、启动时刻与可执行文件来源。来自另一个 Lumi 安装包的 daemon 只显示来源、不自动替换；点 Reinstall 替换前先确认。
- [Lumi for Mac] - 安装 / 重装后直接向 daemon 探测最长 20 秒，另一个进程以当前版本应答才算完成；系统没有换进程、规定时间内没有应答、回来的仍是别的版本，都写在卡片底部，不再静默等待。手动 Reinstall / Stop 执行前核对确认框里的进程，中途换了进程就拒绝。
- [Lumi for Mac] - 开发构建（从 Xcode 运行）与隔离运行不再自动重装已安装的 daemon，也不再覆盖已安装的 helper 与 Codex 信任；面板底部标明管理已关。此前从 Xcode 运行一次就会把正式版 daemon 与 helper 换成开发版。
- [Lumi for Mac] - 事件流重连按 2、4、8、16、30 秒退避；daemon 长时间不在时不再每 2 秒记一条 warning，前 3 次之后只记一条 `daemon_stream_unavailable`，恢复时记一条。
- daemon 的健康自述新增 `process`（实例标识、pid、启动时刻、可执行路径），本机协议版本 1.2 → 1.3。旧 daemon 不带这个字段，新 App 视其为过期并在正式构建里重装一次。

### 会话查看

- [Lumi for Mac] - 修复回合完成卡片约 6 秒到时后 Notch 不收回、一直展开到鼠标悬停再移开的问题。此前卡片换回列表引起的面板高度变化会被当成用户还在操作，面板因此留在展开状态。随之更新 OpenNook。
- [Lumi for Mac] - Notch 不再注册 ⌘⌥; 全局快捷键（此前由界面框架默认注册，没有设置项，容易和别的 App 冲突）；文件拖到 Notch 上也不再展开。展开只靠悬停和回合结束 / 失败的提示。
- [Lumi for Mac] - Notch 面板收起后，下次展开从列表开始。此前在 Notch 里看过某条 Session 的详情、鼠标移开后，详情页会留在面板里：别的 Session 回合结束时面板展开显示的是那条旧详情而不是完成卡片，而且无人查看期间这条 Session 新结束的 Turn 也会被直接标为已查看。

## [0.2.1] - 2026-11-06

### 配对与同步

- 升级提示：Lumi for Mac 与 Lumi for iPhone 要都更新到这一版才能继续同步。只更新一端时，iPhone 的 Macs 页仍显示 Online、Mac 上这台 iPhone 仍是 Active，但 Session 不再更新；两端都更新后自动恢复，不需要重新配对。
- 配对时一个会话只认一台 iPhone：iPhone 提交之后，Mac 没能和 Relay 完成下一步（网络中断或 Relay 出错）时，这个码整个作废、Mac 直接换新码，不再回到还能接收别的设备的状态。此前这一步失败后同一个码还能再接收一台设备，削弱了 6 位数字比对对 Relay 的防护（[#3](https://github.com/AFutureD/Lumi/issues/3)）。
- [Lumi for Mac] - Revoke 一台 iPhone 现在由这台 Mac 自己记住并立即生效：这一行马上变成 Revoked，不再向它发送任何内容；Relay 连不上、报错或之后仍把它列为有效，都不会让它恢复，重启也不会。此前撤销是否生效取决于 Relay 的回答，Relay 连不上时无法撤销。只有重新配对并点 Match 才能恢复。
- 每次同步由 Mac 与 iPhone 各出一把一次性钥匙，Session 内容用只存在于内存里的会话密钥加密：会话结束后，即使某一端长期保存的钥匙日后泄露，也解不开之前同步过的内容；只拿到一端的钥匙也冒充不了另一端。此前所有内容都用配对时定下的同一把钥匙加密。
- 防重放：Mac 与 iPhone 都只接受在当前会话里验证通过、且顺序向前的数据。Relay 重复发送、打乱顺序、保留以前的数据再发，或谎报 Mac 的在线状态，都不会改变任何一端的内容；一条验证不过的数据也不会让后面的正常数据被丢弃。此前 iPhone 重连后会重新接受旧数据，Mac 不检查 iPhone 请求的先后。
- daemon 判断是否信任一台 iPhone 只读自己的状态文件（Match 时记下的钥匙），Relay 的设备列表只用于显示；刚配对的 iPhone 的第一个请求不再需要等设备列表刷新。
- 修复 Relay 回报一个超大序号就能让 daemon 在下一次发送时崩溃、并在重启后反复崩溃的问题：通道序号有了上限，超出范围的回报不再采信。

## [0.2.0] - 2026-09-09

### 会话查看

- [Lumi for iPhone] - Session 内容改为点开才同步：列表只同步每个 Session 的摘要（标题、状态、时间，几秒即齐），第一次点开某个 Session 时才把它的时间线取来（详情页先显示 `Loading session…`），之后只补差异；没点开过的 Session 只跟着 Mac 更新状态。此前重新上线要把所有变过的 Session 整个补齐，长历史下要等几分钟。
- daemon 的 Relay 发送队列分小项 / 大块两条道交替发送，一台 iPhone 补历史不再挡住另一台的索引和用量应答；同一设备重复的索引请求只答最新一条。
- [Lumi for Mac] - 修复 App 内存常驻 150 MB 左右、启动瞬间接近 180 MB 的问题：Notch 每次刷新都把 7 天内每个 Session 的完整时间线读进内存再丢掉。现在完整的 Session 详情只保留最近用到的几份（选中的那条固定保留），Notch 每次刷新只取正在工作、等待或刚结束的少数 Session，其余只用摘要显示；已读进内存的 Session 直接吸收 daemon 推来的更新，不再反复读库。
- [Lumi for Mac] - Notch 里被中途打断的 Session（Failed / Interrupted，或结束信号先于 Turn End 到达的 Completed）现在按 Session 状态判定为已结束：标题变为正文色，悬停出现 Archive 按钮。

### 用量

- [Lumi for iPhone] - 新增底部 Usage Tab（Sessions · Usage · Macs · Settings）。History 段按 Today / This week / This month 看所有 Mac 或某一台的花费与 token：Cost（带较上一周期的涨跌）、Tokens（带构成条）、Sessions / Turns / Calls，以及一张每日花费柱状图——点柱子在柱顶弹出当日浮层（总额、每家 / 每模型一行、Tokens），菜单可切某一家按模型堆叠（多于四个模型时前三 + `Other N models`）。数字来自每台 Mac 的 daemon，各台按自己的本地日算，只在内存里；明细表留在 Mac。
- daemon 的 Relay 新增 `fetch_usage`（只给档位，daemon 用自己的日历展开）与 `fetch_plan_usage` 两种请求；IPC 的 `usage_report` 与它们共用一份报表构建。

### 套餐用量

- [Lumi for iPhone] - Usage Tab 的 Plan 段：一台 Mac 一张卡，卡内 Claude Code、Codex 各一小节，每个窗口一行 `SESSION · 5 HOURS` / `WEEKLY · 7 DAYS` / `FABLE · 7 DAYS`、百分比、用量条与 `resets in …`；条统一蓝色，只有数字在 ≥ 90% 变橙。开关关着、未登录、登录过期、限流、Mac 离线都在卡里写明；「已用 / 剩余」跟每台 Mac 自己的设置。
- [Lumi for Mac] - “Settings > Notch”的 Percent（Used / Remaining）改为保存在 daemon 里，iPhone 读同一份；升级后第一次启动把原来的本机偏好带过去。
- daemon 新增 `settings` 表（一行一个点分 key，如 `plan_usage.percent_style`、`plan_usage.enabled.claude`）与 `get_settings` / `set_settings`；套餐用量的开关从 `plan-usage-settings.json` 迁入（第一次启动导入后删文件），`set_plan_usage` 随之删除。只与 Mac App / Notch 相关的设置仍留在 Mac 本地。
- [Lumi for Mac] - “Settings > Usage”新增 Plan 段：一账号一张卡，卡头是登录（邮箱与套餐、读取来源、刷新时间）与开关，打开后 daemon 每 5 分钟向服务商询问套餐额度，卡身按窗口列出 `42% used`、用量条与重置倒计时（≥ 90% 变橙）。“Settings > Notch”新增 Usage 段：Preview 黑条、Agents（Switch on click / Show both）、Percent（Used / Remaining）、Show 多选药丸（Claude Code：5-hour / Weekly / Fable；Codex：5-hour / Weekly，只列服务商报了的窗口，一颗都不选即关闭）。选了之后 Notch 展开态顶栏左侧的 Lumi 标记换成额度簇：Claude 标记 `5h 42% · 7d 18% · Fable 7%`，Codex 标记 `7d 12%`；≥ 90% 的数字变橙，悬停看重置时间。
- daemon 只读 Agent 自己保存的登录（`~/.claude/.credentials.json`，没有则读 Claude Code 的钥匙串项，不弹提示；`~/.codex/auth.json`），不换发 token、不写回；文件缺失、登录过期、被拒、限流都在 Settings 行里写明原因，失败时保留上一次的数字。

## [0.1.6] - 2026-09-05

### 用量

- [Lumi for Mac] - 侧边栏新增 Usage 页：按 Today / This week / This month / Custom 日期范围查看 token 与花费。Summary 卡给出 Cost（带较上一周期的涨跌）、Tokens（带输入 / 缓存读 / 缓存写 / 输出的构成条）、Sessions / Turns / Calls，以及一张堆叠趋势图——单日按小时、其余按天、超过 90 天按周，可只看某一个 Agent（按它的模型堆叠），y 轴可切 Cost / Tokens，悬停看每根柱的明细；Detail 卡是一张可排序的明细表，Group by 可选 Project、Agent（展开看它用过的模型，Total 固定末尾）、Time（Day / Week / Month）、Model，含 Cache ratio。价目取自 models.dev，页头注明更新时间；没有公开价格的模型在表里标 `—`、在图里是灰段并注明 `· no price`，不计入花费。
- daemon 直接扫描本机 Claude Code 与 Codex 的对话记录（含子 Agent 与 Codex 已归档会话）统计用量，与 Session 记录彼此独立：没进 Lumi 列表的会话、被 Filters 隐藏的会话也计入，删除 Session 或清空历史不影响 Usage；每 24 小时刷新一次 models.dev 价目，离线时用随 App 内置的快照；来源自己报告过费用的调用以报告为准；上下文超过模型长上下文阈值的调用按高档价计；没有 token 的占位消息（Claude 的 `<synthetic>`）不算调用。

### Daemon

- 修复 daemon 已安装却一直 Not connected（`connect: No such file or directory`）的问题：系统暂缓登录项自动启动时，注册成功的 daemon 从未被拉起。现在 Mac App 与 Agent hook 在连不上 daemon 时会按需把它唤醒；daemon 正常退出后，下一次连接也会重新把它拉起来。
- [Lumi for Mac] - “Reinstall daemon”与启动时的自动重装都等系统完成注销后再注册，不再因两步撞车而失败；“Settings > Daemon”的 Status 行先给出注册状态（未安装 / 等待允许），已注册却连不上时才显示连接错误。

## [0.1.5] - 2026-08-31

### 数据存储

- 本机数据按归属分目录：daemon 数据移入 `Application Support/Lumi/Lumen/`，Mac App 缓存移至 `Lumi/Storage/`；升级后首次启动自动迁移，无需重新同步。

### 会话过滤

- [Lumi for Mac] - “Settings > Agents”新增 Filters：按 Agent、Application、User message、Folder 组合规则过滤幽灵 Session（测试、一次性调用等）——命中的 Session 照常入库，但不进列表、Notch、iPhone 与推送。判定在首条用户消息到达时一次冻结，改规则不追溯已有 Session。
- [Lumi for Mac] - 修复所有文本输入框无法粘贴的问题：主菜单补上标准 Edit 菜单，编辑快捷键全应用生效。
- [Lumi for Mac] - “Settings > Agents”的 Hook 卡片合并为 Integrations 列表：一行一个 Agent，行尾单个按钮表示动作（Install / Remove / Trust）。

### 会话查看

- [Lumi for Mac] - Session 列表支持多选（Shift 连选、⌘ 点选、⌘A 全选）与更多删除入口（右键菜单、⌘⌫）；确认框多选时写明条数，删除后选中落到相邻一条。
- 由 AaaS 应用（Paseo、Raft 等）启动的 Session 改用该应用自己的标题，不再停留在默认的“Claude Session / Codex Session”，会话结束后也不再被换回。
- Session 详情 Inspector 的 Overview 新增 Application 项，显示承载该会话的 AaaS 应用。
- Activity 中用户键入的斜杠命令保持为用户消息，按记录原文显示；命令的本地输出仍是上下文。
- Raft daemon 自动发起的工具型会话（如用量轮询）现在也归属 Raft，不再被归为 Claude Code。

### 会话采集

- 修复中断的 Codex 会话永久卡在 Running 的问题：daemon 常驻的 watcher 在数秒内把会话收口为 Interrupted。
- 回合信息改为从时间线推导，时间线成为唯一事实源；对用户可见的行为不变。
- Hook 采集链路重构为「helper 只转发、daemon 全量归并」，对版本偏差与超大断档更皮实：未知 hook 事件不再整帧丢弃，大断档整段补读、不再只吃尾部或整本重放。
- daemon 迁移到结构化并发，收到退出信号时按序优雅关停，期间入队的补读不再丢失。
- [Lumi for Mac] - 修复 Codex hook 授权链路的线程优先级反转；codex 进程意外退出时授权立即失败返回，不再干等超时。

### 配对与同步

- [Lumi for Mac] - 配对码到期后停在 Expired，不再自动换新；点 New code 或重新进入“iPhone”页才出新码。

### 官网

- Download 按钮改为直接下载最新版 dmg，解析失败时退回 releases 页面。

## [0.1.4] - 2026-08-27

### 官网

- 上线落地页 lumi.huanan.app：单页十节（Hero 推送卡片、三大功能、Privacy boundary、三步上手、FAQ），含移动端单列布局；以 Cloudflare Worker 静态资产部署。

### 会话查看

- [Lumi for Mac] - Session 列表改为两行式：状态点前置 + 标题 + 行尾相对时间，副标题显示 Agent 图标与 CLI 上报的 `model · reasoning effort` 原值。
- [Lumi for Mac] - Session 列表改按创建时间倒序排列，顺序不再随后续活动跳动；行尾仍显示最近更新的相对时间。
- [Lumi for Mac] - Subagent 折叠成副标题右端的叠放状态点（最多五个，数量与分档进悬停提示），展开后一个一行、按启动先后排列、行尾显示各自的持续时间（运行中每秒走动，结束后停在最终用时），且可单独选中查看自己的详情；Running / Waiting / Failed 默认展开、Completed 默认收起。
- [Lumi for Mac] - 列表选中改为满宽中性灰底（Subagent 行为圆角灰底），新增悬停底色；状态词与生命周期文字移入状态点的悬停提示。
- 列表相对时间口径统一为 0s / 12s / 4m / 2h / 12d：不足一秒显示 0s，不再出现 now。
- [Lumi for Mac] - 关闭主窗口后 Dock 图标随之隐藏（App 继续驻留，Notch 与同步照常运行）；从 Notch 打开 Session / 设置或再次启动 App 时，窗口与 Dock 图标一起恢复。
- [Lumi for Mac] - 在 Notch 归档带 Subagent 的 Session 时，整组子 Agent（含更深层）随父级一起从列表和计数消失，不再升格为独立顶层行；父级收到新请求时整组一起回来。

### Daemon

- [Lumi for Mac] - 已注册的 daemon 起不来时（如注册指向的安装包被重编译或删除），App 启动约 10 秒后自动重装一次并恢复连接，不再无限报 Connection refused。

### 推送提醒

- [Lumi for iPhone] - 修复点按推送提醒时 App 立刻闪退、看起来像"没有打开"的问题；现在点提醒会直接落在对应 Session 的详情页，App 未启动、在后台或已打开都一样。
- 推送提醒只发给这台 Mac 点过 Match（身份已核对）的 iPhone；Paired iPhones 里显示 Unverified 的设备不再收到含 Session 标题的提醒，与 Session 内容同一条信任边界。

### 系统要求

- [Lumi for iPhone] - 最低支持版本提升到 iOS 26。

## [0.1.3] - 2026-08-26

### 会话查看

- [Lumi for Mac] - Activity 保留完整的工具调用与工具结果内容，不再截断。
- [Lumi for Mac] - 修复刷新时 Session 内容被截断的问题。

### 会话采集

- 重做 Claude 回合边界判定：以内容驱动（human 输入开启、终态 stop_reason 收束），不再依赖 hook 时序。

### 推送提醒

- Session 回合结束、失败或中断时，通过 APNs 发送系统通知到 iPhone。

## [0.1.2] - 2026-08-25

### 发布流水线

- 发布合并为单一 workflow，包含 macOS、iOS 与 Relay 三个任务。
- TestFlight 上传使用持久化的开发证书，不再每次重新生成。

## [0.1.1] - 2026-08-25

### 会话采集

- Codex：映射 item_completed 事件，完善回合归属。
- Codex 事件通道仲裁重构，移除 subagent phase 机制。

### 应用图标

- Mac 与 iPhone 图标更换为矢量 spark 图案。

## [0.1.0] - 2026-08-25

首个公开版本。

### 会话查看

- [Lumi for Mac] - Session 列表、Activity 时间线（L1/L2/L3 密度切换）、子 Agent 层级、Liquid Glass 界面。
- [Halo] - 常驻状态展示，支持自定义设置与响应式细节。
- [Lumi for iPhone] - 查看 Session 状态与 Activity。

### 会话采集

- 采集并归纳 Claude Code 与 Codex 的会话数据。

### 配对与同步

- Mac 与 iPhone 之间的同步通道，支持配对码与 Numeric Comparison 配对。

### 软件更新

- Sparkle 稳定更新通道，支持自动检查。

### 发布流水线

- 由 tag 驱动的发布流水线。

[Unreleased]: https://github.com/AFutureD/Lumi/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/AFutureD/Lumi/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/AFutureD/Lumi/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/AFutureD/Lumi/compare/v0.1.6...v0.2.0
[0.1.6]: https://github.com/AFutureD/Lumi/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/AFutureD/Lumi/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/AFutureD/Lumi/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/AFutureD/Lumi/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/AFutureD/Lumi/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/AFutureD/Lumi/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/AFutureD/Lumi/releases/tag/v0.1.0