# 日志设计

> 基线：2026-08-23。三端（daemon / helper / macOS App、Relay）共用一套"subsystem + category + trace"的日志；错误另行汇总；Session 正文永远不进日志。目标只有排障，不做 telemetry。

## 一眼看懂

```
[2026-08-23T05:40:12.345Z] [INFO:daemon] [agent] ['trace':3f9a2c1d] events_ingested accepted=3 duplicates=0 received=3 sessions=abc123
 └─ TIME (UTC ms) ─────┘  └LEVEL:subsystem┘ └category┘ └── trace（有则最前）┘ └──── MESSAGE：事件名 + key=value（业务层写）────┘
```

| 列 | 谁定 | 取值 |
| --- | --- | --- |
| `[TIME]` | 框架 | ISO-8601 UTC 毫秒 |
| `[LEVEL:subsystem]` | LEVEL 来自调用的方法；subsystem 进程启动 `bootstrap` 一次 | `daemon` / `helper` / `app`（Mac）/ `ios` / `relay` |
| `[category]` | `Logger(label:)` 声明处决定，调用点不传 | `lifecycle` / `agent` / `convert` / `db` / `ipc` / `relay` / `pairing` / `ui`；Relay 侧 `http` / `ws` / `pairing` / `directory` |
| `['trace':ID]` | 框架从任务上下文取，有就放 MESSAGE 最前 | IPC 请求 id、helper run id、Relay 请求 id、Worker 的 `cf-ray` |
| MESSAGE | 业务 | `事件名 key=value …`；`error=` 永远最后；键按字母序，所以同一事件的列顺序稳定 |

| 端 | 写到哪 | 看哪 |
| --- | --- | --- |
| daemon | `~/Library/Logs/Lumi/daemon.log` + os_log `app.huanan.lumi.daemon` + stderr | 文件 / Console.app |
| helper（每次 hook 一个进程） | `helper.log` + os_log `…helper` + stderr（默认只有 WARN 以上） | 文件 |
| macOS App | `app.log` + os_log `…app` | Settings › Daemon › Logs › Show in Finder；Console.app |
| 三者的 ERROR | 同目录 `errors.log`（额外一份） | 出问题先看这个 |
| Relay（Worker + DO） | `console.log / warn / error`，一行一个 JSON：`{"ts","level","subsystem":"relay","category","trace"?,"event",…}` | `wrangler tail` / Workers Logs |

## 依赖与分层

- [swift-log](https://github.com/apple/swift-log)（1.6）：`Logger(label:)`、`Logger.Level`、`Logger.Metadata`、`LogHandler`、`MetadataProvider`、`LoggingSystem.bootstrap`。业务代码只认识 swift-log 的 `Logger`。
- [swift-service-context](https://github.com/apple/swift-service-context)（1.x）：task-local 的 `ServiceContext` 装 trace id——这是 swift-distributed-tracing 的地基，我们只用这一层，不引 Tracer / span。
- 自己写的只有 `Common/Sources/Diagnostics/`：
  - `DiagnosticsLogHandler`：唯一的 `LogHandler`。渲染行、写 os_log（subsystem `app.huanan.lumi.<subsystem>`，category = label）、`<subsystem>.log`、`errors.log`（error 及以上）、可选 stderr；文件 0700 / 0600、`O_APPEND`（三个进程共用 `errors.log` 不串行）、5 MB × 3 轮转（轮转发生在写入前，最新一行总在活文件）。
  - `Trace.swift`：`TraceIDKey`、`withTrace(id) { }`（继承调用方 isolation，`@MainActor` 里也能用）、`currentTraceID`、`makeTraceID()`（8 位 hex）、`Logger.MetadataProvider.traceID`。
  - `Diagnostics.bootstrap(LogConfiguration)`：进程入口调一次；`LogConfiguration.fromEnvironment(subsystem:)` 读 `LUMI_LOG_LEVEL`（默认 info）/ `LUMI_LOG_DIRECTORY`（默认 `~/Library/Logs/Lumi`，`off` 关文件）；Mac 用启动参数 `-LumiLogLevel`。
  - `Logger.Metadata.fields([...])`：业务字段糖——丢 `nil`、Date → ISO、Double 一位小数；`LogClock.milliseconds(since:)` 给 `ms=`。

## 业务侧怎么写

```swift
import Diagnostics
import Logging

private let log = Logger(label: "ipc")          // 声明决定 category

log.info("ipc_handled", metadata: .fields(["op": op, "status": status, "ms": ms]))
dbLog.error("apply_failed", metadata: .fields(["session": id, "error": error]))
```

一个工作单元 = 一个 trace：

| 单元 | 在哪开作用域 | id |
| --- | --- | --- |
| daemon 处理一个 IPC 请求 | `DaemonServer` 的 `Task { await withTrace(envelope.requestID.rawValue) { … } }` | 客户端给的 requestID |
| helper 一次 hook | `SparkMain.main` | `makeTraceID()`；`DaemonIPCClient` 把 `currentTraceID` 当 IPC requestID 发出去，所以 daemon 侧同一个 id |
| Mac 一次 reconcile | `MacSessionStore.scheduleReconcile` | `makeTraceID()`，同样随 IPC 请求带到 daemon |
| daemon 处理一个 Relay 请求（index / fetch / timeline / removed） | `RelayHostService.process` | payload.requestID |
| Relay Worker 一个请求 | `index.ts` / `HostRelay.fetch` 的 child logger | `cf-ray` |

非 async 边界直接 `metadata: ["trace": id]`，handler 一视同仁。

## category 归属

| category | 含义 | 典型事件 |
| --- | --- | --- |
| `lifecycle` | 进程启动 / 停止、配置、服务注册、自动更新、hook 安装 | `daemon_started`、`app_started`、`daemon_auto_update_restarting`、`claude_watcher_started` |
| `agent` | Agent 接入：hook 入口、transcript / rollout 扫描、事件入库与分发、Mac 端 apply | `hook_ingested`、`events_ingested`、`transcript_scanned`、`rollout_scanned`、`stream_publish`、`events_applied` |
| `convert` | 纯数据转换：adapter 归一化、坏记录、Session 重建、给 iPhone 切片 | `rich_source_line_rejected`、`session_reingested`、`index_prepared`、`session_prepared` |
| `db` | SQLite 仓库 / 缓存读写 | `session_deleted`、`history_cleared`、`cache_open_failed`、`event_apply_failed` |
| `ipc` | 本机 Unix socket：请求、事件流、编解码 | `ipc_listening`、`ipc_handled`、`ipc_request`、`ipc_stream_connected`、`ipc_operation_failed`、`reconciled` |
| `relay` | Relay WebSocket / REST、设备列表、推送、序号 | `relay_connected`、`relay_ws_sent`、`relay_rest`、`devices_refreshed`、`request_received`、`events_pushed`、`sequence_healed` |
| `pairing` | 配对状态机（daemon 与 Mac 页面） | `pairing_started` → `pairing_device_submitted` → `pairing_revealed` → `pairing_approved` / `pairing_rejected` / `pairing_expired`；`pairing_page_*` |
| `ui` | App 的用户操作 | `logs_revealed` |

Relay：`http`（入口每请求一行 `http_request route= status= ms=`、`https_required`、`edge_rate_limited`、`request_*`）、`ws`（`ws_opened` / `ws_closed` / `ws_*_frame_forwarded` / `ws_sequence_rejected`…）、`pairing`（状态机 + `pairing_claim*`）、`directory`（`pairing_code_allocated` / `pairing_code_claimed` / `pairing_claim_rate_limited`）。`LOG_LEVEL` 是 `wrangler.jsonc` 的 var（默认 info，测试绑 `warn`）。

## 隐私

字段只放：标识（session / device / host / request id）、计数、字节数、kind、state、耗时。永远不放：prompt / 工具参数 / 时间线正文、配对码、host secret / device token、nonce / commitment / 密钥 / 密文。配对 session id 是 bearer capability，只记前 8 位。`scripts/smoke-local-chain.sh` 断言 prompt 文本不出现在任何日志文件里，并断言 helper 的 run id 出现在 daemon 的 `ipc_handled` 行上。

## 边界

- 日志不是数据通道：没有任何逻辑读取日志文件。
- iOS 暂不写文件，只有 `Remote` 的 relay 行进 os_log。
- 不做 span / 采样 / 导出；要接 OTel 时，`ServiceContext` 已经是 span context 该待的位置，日志一行不用改。
