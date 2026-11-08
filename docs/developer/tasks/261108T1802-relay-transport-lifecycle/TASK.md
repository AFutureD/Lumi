# 手机 ↔ daemon 传输：先尾后头、请求不重复、心跳退避、局域网直连

* Task: 261108T1802-relay-transport-lifecycle
* Author: Huanan
* Status: DEVELOPING（代码与文档完成，待人工 review 与发版）
* Type: FEAT
* Related: [260823T0142-relay-pairing-code-sas](../260823T0142-relay-pairing-code-sas)、[260823T0537-three-end-logging](../260823T0537-three-end-logging)

## Outcome

调研结论见 [docs/research/relay-transport-model.md](/docs/research/relay-transport-model.md)。用户要求把其第 6 节的 5 步全部落地，结果按用户可感知的行为描述：

1. 点开一个 Session，几秒内看到它最近的活动；往上翻时才把更早的活动分页取来。不再等整本传完。
2. 一个请求等不到答复时，手机不整份重发、不把已收到的扔掉；电脑认出同一本 Session 的重复请求只答最新一份；手机放弃或离开详情页时电脑停止寄送。
3. Mac 与 iPhone 之间的连接有心跳：断了 30 秒内发现；重连间隔逐次拉长到 30 秒封顶；设备列表由 Relay 推送变化，不再每 10 秒轮询。
4. 手机和电脑在同一局域网时直接传，不经 Relay；直连不可用时自动退回 Relay。Macs 页标出当前走的是直连还是 Relay。
5. 每次寄送在 daemon 日志里有一条汇总（片数、字节、耗时），Relay 侧每帧转发有大小记录。

隐私与信任边界不变：Relay 与局域网上的任何人都读不到内容、换不了身份；信任仍只看 daemon 自己钉住的公钥。

## 设计（合同层）

### 远程协议 1.3 → 1.4

两端一起升级，不做兼容（仓库规则）。`RemoteSessionPayload` 新增可选字段：`limit`、`before: TimelineCursor{occurredAt, id}`、`itemIDs`、`cancels: RequestID`、`hasOlder`。`TimelineItem` 新增 `truncated: Bool?`。

| 方向 | kind | 含义 |
| --- | --- | --- |
| 设备 → daemon | `sync_index` | 不变 |
| | `fetch_session` | `sessionIDs` + `limit`：每个 Session 最新的 `limit` 条（尾页）。取代“整本” |
| | `fetch_session_before` | `sessionIDs[0]` + `before` + `limit`：比游标更早的一页 |
| | `fetch_timeline_since` | 不变（补尾） |
| | `fetch_timeline_items` | `sessionIDs[0]` + `itemIDs`：被裁剪条目的完整内容 |
| | `cancel_request` | `cancels`：放弃某个请求，daemon 丢弃排队与在途的剩余分片 |
| | `session_reviewed` / `fetch_usage` / `fetch_plan_usage` | 不变 |
| daemon → 设备 | `session_tail` | 取代 `session_full`。每片自含（part 0 带 summary + turns，之后只带 timeline 切片），**到一片用一片**：part 0 `replaceSession`，后续 `mergeSession`；末片 `nextCursor == nil` 且带 `hasOlder` |
| | `session_history` | `fetch_session_before` 的应答，同样逐片 merge，末片带 `hasOlder` |
| | `session_timeline` | 形态同上，逐片 merge |
| | `session_items` | `fetch_timeline_items` 的应答，merge |
| | 其余 | 不变 |

分片规则：按**编码后字节**贪心装满（预算 1 MB 明文，压缩加密后仍远低于 Relay 2 MiB 上限），不再按条数对半切；每条 timeline item 在 Relay 副本里有 64 KB 内容预算（工具 / 上下文 / 配置的 `content` 置空、消息与推理文本截断，标 `truncated`），完整内容按需 `fetch_timeline_items`。daemon 与 Mac 的本地副本不受影响。

### 对账（`SyncReconcilePlan`）

惰性镜像（iPhone）持有的只是尾段，不再比较行数：远端 `lastItemAt` 更新 → `fetch_timeline_since`；远端更旧或为空 → 重新取尾页；相同 → 只比 summary。急切镜像（Mac）规则不变。

### 请求生命周期

- iPhone：每个请求记录 `lastProgressAt`，超时按“最近一片之后无进展 30 秒”判；第一次超时重发一次（新 requestID），第二次只放弃该请求并通知 daemon `cancel_request`，不清空其他在途请求、不重新 index。index 请求保持原规则。
- daemon：`fetch` / `history` / `timeline` / `items` 工作项按（设备, Session）去重，新请求顶掉排队中的旧请求；`cancel_request` 删排队项并让在途项在下一片前停下；每个请求结束记 `request_answered`（kind、session、items、parts、ciphertext_bytes、prepare_ms、send_ms、cancelled）。

### 活性、退避、设备列表

- 两端 WebSocket 每 10 秒发协议级 ping，30 秒无 pong 视为断线。
- 重连 2 → 4 → 8 → 16 → 30 秒，连上即重置。
- Relay 在设备行变化（配对批准、撤销、push token）时向 Host 推 `devices_changed`；daemon 的轮询拉长到 60 秒作兜底。

### Relay 帧

- 二进制 WebSocket 消息：`u32 BE 头长度 + JSON 头（version、hostID、deviceID、sequence、kind、nonce）+ 原始密文`，去掉 Base64。Worker 只解析头。
- Durable Object 的 host → device 序号单调检查改为内存：对象重新唤醒后以第一帧为新基线。两端早已各自防重放（issue #3），Relay 这一层只是多一道。

### 局域网直连

- daemon 用 Bonjour 发布 `_lumi-relay._tcp`（TXT：hostID），监听 TCP；每条连接按“4 字节长度 + 二进制帧”收发，走与 Relay 完全相同的密封与信任检查。
- iPhone 浏览同名服务，TXT 的 hostID 匹配已配对 Mac 时建立直连，并在直连上重新 `sync_index`；daemon 记住每台设备最近一次请求来自哪条路径，应答与推送只走这一条。直连断开时手机在 Relay 上重新 `sync_index`，路径切回。Relay WebSocket 始终保持，提供在线状态与兜底。
- Macs 页：`Online · Direct` / `Online · <Relay 地址>`。

## 验证

### 单元测试（2026-11-08，全绿）

| 包 | 数量 | 新增覆盖 |
| --- | --- | --- |
| Common（Core / Remote / Persistence / Transport） | 193 | 内容预算与 `truncated`、按字节贪心装满、最新在前切片、`SyncReconcilePlan.lazy` 与 `classify`、裁剪不覆盖完整 |
| CLI（RelayHostServiceTests） | 36 | 尾页 / 翻页 / 补尾改尾页、按需取完整行、重复请求顶替与取消、局域网直连 + Relay 掉线不影响直连会话 |
| iOS（IOSFeatureTests） | 61 | 点开取尾页 + Load earlier 翻页 + 水位持久化、裁剪行按需取回且不被再次裁剪、卡住的请求重问一次再单独放弃、离开详情取消翻页、同网直连与断开回退 Relay |
| Relay（vitest） | 54 | 二进制帧解析、`frame_too_large` 不断线、文本帧 4004、`devices_changed`、内存序号基线 |

### 用户验收（vphone Cherry，隔离 daemon + 本地 Relay `wrangler dev`，2026-11-08 18:50–19:05）

已验证（截图在 `assets/`）：

1. 配对：`lumi://pair?relay=http://192.168.64.1:8787&code=…` → 本地网络权限弹窗（文案即 Info.plist 里写的）→ Match → Macs 页显示 `Online · Direct`（`vphone-05-after-allow.png`）。daemon 日志：`channel_session_accepted path=relay` 后 18 秒内 `direct_connection_accepted` + `channel_session_accepted path=direct replaced=true`。
2. 点开 971 行 / 8.5 MB 的运行中 Session：0.7 秒内已显示最近活动与 `Load earlier` 行（`vphone-07-open-0.7s.png`）；daemon `request_answered kind=session_tail items=80 parts=1 ciphertext_bytes=38886 prepare_ms=23 send_ms=1 path=direct`。
3. `Load earlier`：`request_answered kind=session_history items=80 ciphertext_bytes=23261`；列表多出更早一页（`vphone-09-load-earlier.png`）。
4. 裁剪条目：181 行 / 5.2 MB 的 Session（含 5 条 0.9–1.2 MB 的工具结果）尾页只有 43 KB；点开其中一条结果，详情页底部出现 `Full content is on the Mac. / Load full content`（`vphone-15-sheet-trimmed.png`）；点后 daemon `request_answered kind=session_items ciphertext_bytes=709640`，再打开该条目时提示消失（`vphone-21-sheet.png`）。
5. 杀掉 App 重开：列表立刻从缓存显示；Relay 会话与直连会话在 4 毫秒内先后建立，直连顶替 Relay；Relay Worker 日志每帧带 `bytes`。

验收中发现并已修的两个问题：`Load earlier` 原先是固定的列表头，滚动时浮在第一行上，改成普通首行；直连会话存活而 Relay socket 正在重连时，取条目等请求被 `isConnected` 挡住，改为「任一链路在就能发」（`isLinked`）。

未验证：

- 真机 iPhone 与真实 Relay（线上 Worker 尚未部署这一版；部署即要求 Mac、iPhone 一起升级）。
- 心跳判死与退避：vphone 走查里 daemon 的 Relay socket 没有掉过，只有单元测试里的内存链路；真实 `sendPing` 对线上 Durable Object 的行为未实测。
- 直连断开回退 Relay：只在 iOS / daemon 单元测试里用内存链路验证，vphone 上没有办法把 Mac 从网络上拿走。
- 请求卡住 30 秒后的重问与放弃：只有单元测试。

### 本地验收复现

隔离 daemon：`CLI/.build/debug/Lumen`，环境变量 `LUMI_SUPPORT_DIRECTORY` / `LUMI_SOCKET` / `LUMI_DATABASE` / `LUMI_LOG_DIRECTORY` / `LUMI_RELAY_URL=http://localhost:8787` / `LUMI_RELAY_KEYCHAIN_SERVICE=<唯一>` / `LUMI_RELAY_STATE` / `CODEX_HOME` / `CLAUDE_CONFIG_DIR` / `LUMI_PLAN_USAGE=0` / `LUMI_MODEL_PRICES=0` / `LUMI_WAKE_SERVICE=0`；本地 Relay：`wrangler dev --local --ip 0.0.0.0 --port 8787 --local-upstream localhost:8787`（vphone 经 vmnet 用 `http://192.168.64.1:8787`，DEBUG 构建允许私网 http）。灌数据：`sqlite3` ATTACH 生产库只读复制 `sessions` / `timeline` 行。IPC 用 20 行 Python（4 字节大端长度 + `TransportEnvelope` JSON）驱动 `relay_pairing_start` / `relay_pairing_state` / `relay_pairing_decide {"approved":true}`。vphone：`apps.open_url` 打开配对链接，`input.tap`（点坐标）点系统弹窗，`ui.tree` 读行位置（时间标签里是 U+202F 窄空格），socket `swipe` 带 `ms` 才能小幅滚动。

## 未做

- 每台设备一条独立的 Relay 数据通道（Paseo 的做法）：尾页分页之后管道争用已经很小，先不做。
- Relay Worker 线上部署与三端同步发版：需要用户决定时间点（旧版 iPhone 连新 Worker 会被 4004 断开并提示更新）。
