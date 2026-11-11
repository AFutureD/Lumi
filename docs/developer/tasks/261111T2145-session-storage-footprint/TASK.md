# Session 存储瘦身：截图只存一份、镜像存裁剪行、空闲页回收

* Task: 261111T2145-session-storage-footprint
* Author: Huanan
* Status: DEVELOPING（代码与文档已提交，待发版）
* Type: BUG
* Related: [261108T1802-relay-transport-lifecycle](../261108T1802-relay-transport-lifecycle)

## 起因（2026-11-11 本机实测，只读）

| | daemon | Mac 缓存 |
| --- | --- | --- |
| 文件 | 2.0 GB | 1.7 GB |
| 活数据 | 375 MB | 349 MB |
| 空闲页 | 82% | 79% |

- 两边各 214 个 Session、317 MiB timeline。单个 Session 中位 108 KiB，最大 52.7 MiB；前 10 个占 88%。
- 84% 的字节是 Claude 工具结果里的截图 base64；同一张图在 `content[].source.data` 与 `toolUseResult.file.base64` 各存一份，纯重复 142.7 MiB。
- 没有任何界面渲染这些图。Mac 只在原始数据窗口里把它当文本显示。
- 项目从不 VACUUM：删除后的页面一直占着文件。

## Outcome

用户要求三项全部处理：

1. 截图只存一份。工具结果里与模型所见内容重复的大段数据只保留一份，另一处留一个可解析的引用，指明它与哪一处相同。已有数据一起迁移。
2. Mac 缓存像 iPhone 一样只存裁剪行。超过单条预算的行在 Mac 上只留摘要；打开原始数据窗口时向 daemon 取完整内容，取不到要明说。
3. daemon、Mac（以及 iPhone）的数据库删除后自动把空间还给磁盘；已有文件一次性压实。

完成标准：升级后 daemon 库与 Mac 缓存的文件大小接近各自活数据；Session 列表、活动列表、Notch、Inspector 行为不变；原始数据窗口仍能看到完整内容。

## 合同（摘要）

- daemon 是唯一保存完整行的地方。发给任何镜像（Mac 走 IPC，iPhone 走 Relay）的都是按同一预算裁剪的行；完整行按需取（Mac：IPC `get_timeline_items`；iPhone：`fetch_timeline_items`）。
- 同一 id 的新旧版本由一条规则判定：旧版本不覆盖新版本；裁剪行只在它就是现有完整行的裁剪结果时让位。
- 工具结果去重的引用形如 `{"lumi.sameAs": "/content/0/source/data"}`，是相对工具 `content` 对象的 JSON Pointer。
- 数据库文件以 `auto_vacuum = FULL` 运行；老文件在打开时一次性 VACUUM 转换。
- Mac 缓存换新文件重建（旧文件删除），不在原地改写。

详细决定见 `docs/design/data-communication-storage.md` 与 `docs/design/agent-hook.md`。

## 方案评审（子代理）采纳的修正

- 裁剪放在 daemon 的 IPC 出口，而非 Mac 入口：省掉约 292 MiB 的无用传输，与 Relay 同构。
- 去重用结构化引用而非占位字符串：误读者会因类型不符显式失败。
- 同 id 由小变大时裁剪行被拒收的潜在 bug（iPhone 已存在）一并修复。
- 选 FULL 而非 INCREMENTAL：不需要在每条释放页面的路径后补调用。

## 验收（2026-11-11，隔离环境，真实数据副本）

daemon 与 Mac 都指向 `/tmp` 下的隔离目录，数据是 21:59 时真实 daemon 库与 Mac 缓存的副本（221 个 Session）。真实库与正在运行的正式版 Lumi 未受影响。

| | 升级前 | 升级后 |
| --- | --- | --- |
| daemon 文件 | 2.04 GB | 249 MB |
| daemon timeline 内容 | 344.8 MiB | 199.2 MiB |
| Mac 缓存文件 | 1.68 GB（旧文件，已删除） | 64 MB（新文件） |
| Mac timeline 内容 | 344.8 MiB | 48.1 MiB |

- daemon 首次启动：`lumi-v13` 改写 864 行（308.6 MB → 154.6 MB，4.7 秒），VACUUM 2.1 秒；`PRAGMA integrity_check` = ok，Session 数不变。
- Mac 首次启动：`cache_retired bytes=1681948672`，对账重建 221 个 Session 用 7.3 秒，其间列表为空。
- 原始 JSON 窗口：截图行在 Mac 缓存里只有 535 字节（`truncated`），点开后显示从 daemon 取回的完整内容，重复处为 `{"lumi.sameAs": "/content/0/source/data"}`；daemon 停掉后再点，显示 `Couldn't load full content: connect: No such file or directory (2)` 与摘要版。
- 未解释：第一次点开时 sheet 在约一分钟内消失；之后三次（前台一次、后台两次，含一条普通小行）都正常保持，未能复现。
- 风险：daemon 首次升级启动约 7 秒才开始监听，接近 Mac 的 8 秒唤醒超时；超时时 Mac 按退避重连。
