# 主程序维护 daemon 的抽象行为模型（Paseo vs Lumi）

> 来源：Paseo 仓库（v0.15.3，Electron + Node）与本仓库 2026-11-08 现状。两份只读调查原文在 `/tmp/codex-paseo-daemon/result.md` 与 `/tmp/codex-lumi-daemon-mgmt/result.md`（临时文件，带行号）。
> 用途：把「主程序如何维护后台服务」从技术栈里抽出来，作为 Lumi 调整的参考。只谈行为，不谈实现。

---

## 0. 一句话结论

- 主程序对后台服务的职责可以拆成 8 个与技术栈无关的问题。Paseo 和 Lumi 对每个问题都有回答，差别在「谁来答」：Paseo 大部分自己答（pid 锁文件 + supervisor 进程），Lumi 把一半交给 launchd。
- Lumi 真正缺的不是机制，而是三种「身份」里的两种：实例身份（现在跑的还是不是刚才那个进程）和所有权（我有没有权利动它）。其余差异多数是 launchd 已经替我们做了，或是产品取向本就不同。

---

## 1. 八个问题

| # | 问题 | 与技术栈无关的规则 |
|---|---|---|
| 1 | 分发：服务从哪来 | 随主程序一起分发；主程序包内的副本就是「期望版本」，没有独立的安装步骤。若服务要被主程序之外的东西调用（Hook），需要一个稳定路径的安装副本，由主程序负责刷新。 |
| 2 | 身份：怎么指认一个实例 | 三个标识分开记：实例身份（pid + 启动时刻 + 开机标识）、版本身份（版本号或可执行指纹）、所有权（是否本主程序这次拉起）。三者回答三个不同问题：还是不是它、是不是对的版本、能不能动它。 |
| 3 | 获取：启动等于先发现再决定 | 发现靠一份权威记录；已有活实例默认复用，死记录清掉重建。就绪判据是「能回答健康问题」，不是「进程存在」。等待有预算。 |
| 4 | 版本对齐：何时换掉旧的 | 时机是主程序启动时与主程序自身更新前后。只换自己拥有的实例，外来实例只告警。换完要验证两件事：实例身份变了，且版本等于期望。 |
| 5 | 健康与恢复：谁救谁 | 两层分开：进程层恢复归监督者（supervisor / launchd），连接层恢复归主程序。健康是服务自述（版本、pid、指纹、运行时长），走同一条连接。重连有退避、有上限。失联要分类，不同类给不同文案和按钮。 |
| 6 | 关停：谁能停、怎么停 | 退出时是否带走服务是产品决定，可配置。只停自己拥有的。手动停止带着「确认时看到的实例身份」，执行时复核，变了就拒绝。优雅、超时、强杀三段式。「重启」不等于「停再起」，监督者可以留着只换 worker。 |
| 7 | 用户可见面 | 一个总开关「由主程序管理内置服务」，关掉即只连不管。状态枚举 starting / running / stopped / errored，附 pid、目录、版本、自己拉起 / 接管的标签。操作：停止（带确认）、重启、看日志、复制诊断命令。错误按「失败在哪一步」区分。 |
| 8 | 本地信任 | 服务生成凭据，主程序只在确认目标是自己管理的实例且端点一致时才读。单用户 Unix socket 场景可用文件权限代替凭据。 |

---

## 2. 两边各自怎么答

| # | Paseo | Lumi |
|---|---|---|
| 1 分发 | daemon 入口打包在 asar 内，用 Electron 自身当 Node 跑；CLI 独立走 npm 全局安装。 | Lumen 留在 App 包内，launchd 直接指向它；Spark 复制到 Application Support，App 启动时字节比较后刷新。 |
| 2 身份 | 三者齐全：锁文件记 pid、startedAt、bootId、serverId、desktopManaged；主进程内存记「这次自己拉起的」那一个。 | 只有版本身份（SHA-256 指纹）。launchd Label 保证唯一，但 App 不记实例身份，也不区分自己拉起还是接管。Debug 与 Release 共用 Label 和 socket。 |
| 3 获取 | 读 pid 锁，活则复用，死则删锁重建；轮询 status 30 秒。 | 注册 LaunchAgent（RunAtLoad）；连 socket 得到「不存在 / 拒绝」时走 Mach 服务唤醒再重连，预算 App 8 秒、Spark 4 秒。 |
| 4 版本对齐 | 自己拥有且版本不同才停掉重起；App 更新前先停自己的 daemon；设置页等「同 serverId、不同 pid、版本等于新版本」才算完成。 | 启动 10 秒内健康为空或指纹不同，做一次 unregister + register；只验证指纹，不验证 pid 变化；App（Sparkle）更新前不停 daemon，靠下次启动自愈。 |
| 5 健康与恢复 | supervisor 崩溃即重启 worker（无退避）；客户端 ping 10 秒、重连退避 1.5 秒到 30 秒；状态分 stopped / not_ready / running，连接分 reachable / unreachable / auth_required / auth_failed。 | launchd `KeepAlive.SuccessfulExit=false`、节流 5 秒；App 固定 2 秒重连，无退避无上限；失联只显示 SMAppService 状态或 connect 错误原文。 |
| 6 关停 | 「退出后保持运行」默认关；手动停止带 pid + startedAt 复核；SIGTERM 等 15 秒再 SIGKILL 等 3 秒；restart 只换 worker 保留 supervisor。 | App 退出不动 daemon（设计意图：Hook 采集需要常驻）；Stop & uninstall 即 unregister；Reinstall 是 unregister、轮询等待、再 register；launchd 默认 exit timeout 5 秒。 |
| 7 可见面 | 两个开关、四态枚举、owned / attached 标签、停止确认框含 pid 与目录、日志尾 100 行、可复制 status 命令。 | Install & Start / Reinstall / Stop & uninstall 三个按钮；状态只有 Running 与 Not connected · 原因；日志 Show in Finder。 |
| 8 信任 | 32 字节随机凭据写 0600 文件；主进程核对锁内端点一致后才下发。 | 0700 目录 + 0600 socket，无凭据。 |

---

## 3. Lumi 的缺口（行为层面，与 launchd 无关）

按影响排序。

1. 没有实例身份与所有权。
   Reinstall 和 Stop 不知道动的是不是同一个进程；Debug 版会接管真实采集（现状靠 `chflags uchg` 锁 Spark 文件顶着）。Paseo 的对应做法是锁文件记 pid + startedAt + 管理标记，主程序只记自己拉起的那一个。

2. 失联没有分类。
   「Not connected · 原因」把未注册、已注册但没拉起、在跑但未就绪、被拒绝四种情况揉成一条字符串，用户不知道该按哪个按钮。

3. 重连无退避无上限。
   固定 2 秒无限重试；daemon 长期不在时每 2 秒写一条 warning。

4. 版本对齐不验证「真的换掉了」。
   reinstall 后只比指纹。如果 launchd 根本没重拉（2026-09-05 的 on-demand-only 情况），健康一直为空，决策停在 wait，不再有第二次动作，也不提示用户。

5. 文档与代码三处不一致。
   Spark 找不到 daemon 时的退出码与等待（data-communication-storage.md 第 290 行）；Codex 信任成功文案（observe-session-locally.md 第 25 行、friction-points.md 第 32 行）；`hook_environment` 日志开关（logging.md 第 67 行）。

---

## 4. Paseo 里不该照抄的

- supervisor 崩溃重启没有退避、没有次数上限。
- Electron 不重拉整体死掉的 supervisor，要等下一次前端 bootstrap。Lumi 由 launchd 兜底，更好。
- 启动时机绑在前端根布局挂载上，主进程是被动的。
- 注释与实现矛盾：Windows 的 paseo.cmd 声称把 CLI 起的 daemon 标为 desktop-managed，实际环境变量被共享函数删掉。

---

## 5. 刻意不同，不需要对齐

- 退出是否带走 daemon：Lumi 的 daemon 为 Hook 采集常驻，App 只是观察者，不需要「退出后保持运行」开关。
- 「只连不管」模式：Lumi 没有用户自己起 Lumen 的场景，隔离测试走环境变量即可。
- 本地凭据：单用户 socket 0600 已足够；跨设备信任另有 Relay 配对体系。

---

## 6. 建议的应用顺序（2026-11-08 已全部落地）

落地与下表的两处出入，都来自实现前的方案评审：

- Debug 包不接管的办法不是「看 health 再决定刷不刷 Spark」，而是一条独立的管理策略：开发构建与隔离运行一律不自动管理已安装的 daemon、helper 与 Codex 信任；正式构建对没有进程身份的旧 daemon 仍修复一次。
- 实例身份用 daemon 启动时生成的 `instanceID` 比较，pid 与启动时刻只给人看；重装后的验证直接向 socket 探测新鲜 health，不读 store 里的旧值。

| 顺序 | 做什么 | 对应缺口 | 估时 |
|---|---|---|---|
| 1 | 健康自述加实例身份（pid、启动时刻、所在 App 包路径），Reinstall / Stop 前后比对，Debug 包不接管 Release 的 socket | 3.1 | 半天 |
| 2 | 失联原因改成枚举，驱动 Settings 的文案和按钮 | 3.2 | 半天 |
| 3 | 重连退避 2 秒到 30 秒，长期失联降级为一条日志 | 3.3 | 1 小时 |
| 4 | reinstall 后验证 pid 变化；reinstall 后仍无健康时给用户提示而不是静默 wait | 3.4 | 1 小时 |
| 5 | 修三处文档 | 3.5 | 半小时 |
