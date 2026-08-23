# 三端日志：daemon / macOS / Relay

* Task: 260823T0537-three-end-logging
* Author: Huanan
* Status: DEVELOPING
* Type: FEAT
* Related: [260816T1953-agent-status-v1](../260816T1953-agent-status-v1)、[260823T0142-relay-pairing-code-sas](../260823T0142-relay-pairing-code-sas)

## Outcome

给 daemon、macOS App、Relay 补一套能落地排障的日志，五条要求逐条对应：

1. **error 额外记录** — Swift 侧所有 `error` 级别除了进各自的 `<process>.log`，还追加到同目录共享的 `errors.log`；IPC 内部失败（客户端只看到 `internal_error`）的真实原因现在有处可查。Relay 侧 error 走 `console.error` 并带 stack。
2. **数据转换需要日志** — `convert` 分类：helper 每次 hook 一行（provider / session / hook / 读了多少行 / 发了几个事件 / 耗时）、transcript / rollout watcher 的增量扫描、`RichSourceReader` 里原先被 `try?` 吞掉的坏记录（位置 + 错误，不含内容）、Session 重建、给 iPhone 切分 index / session 的 parts 数。
3. **数据传输需要日志** — `transport` 分类：daemon IPC 每请求一行（op / status / failure / bytes_in / bytes_out / ms）、Mac 端 IPC 客户端与事件流连接、Relay WebSocket 连接 / 发送 / 接收 / 断开、REST 调用（method / 脱敏 path / status / bytes / ms）、Relay Worker 每请求与每帧转发。
4. **事件需要日志** — `event` 分类：每批 ingest 的 received / accepted / duplicates / sessions、订阅中心 fan-out（debug）、Mac 端 apply 结果、Relay 推送（events / summaries / removals）。
5. **Relay 支持日志** — `Relay/src/log.ts`：分级（`LOG_LEVEL` var，默认 info）、一行一个 JSON、DO 级 child logger 自带 `do` / `hostID`；入口 Worker 记 route / status / ms，HostRelay 记 socket 生命周期、帧转发、序号拒绝、配对状态机，PairingDirectory 记码分配 / 领取 / 限流。

隐私边界不变：字段只有标识、计数、字节、kind、state、耗时；不记 Session 正文、配对码、secret / token、nonce / commitment / 密钥 / 密文；配对 session id 只记前 8 位。

## 设计

见 [docs/design/logging.md](../../../design/logging.md)。要点：

- API 就是 swift-log：`Logger(label:)` 的 label = category（`lifecycle` / `agent` / `convert` / `db` / `ipc` / `relay` / `pairing` / `ui`），声明处决定，调用点只写 MESSAGE（事件名 + `metadata: .fields([...])`）。
- 框架层只有一个自定义 `LogHandler`（`AgentStatusLogHandler`）：渲染 `[TIME] [LEVEL:subsystem] [category] ['trace':ID] MESSAGE`，写 os_log（`com.huanan.AgentStatus.<subsystem>`）、`<subsystem>.log`、`errors.log`（error 及以上）、可选 stderr；0700 / 0600、`O_APPEND`、5 MB × 3。
- subsystem 由进程入口 `AgentStatusLogging.bootstrap(LogConfiguration)` 决定：`daemon` / `helper` / `app`；daemon / helper 读 `AGENT_STATUS_LOG_LEVEL` / `AGENT_STATUS_LOG_DIRECTORY`，Mac 读 `-AgentStatusLogLevel`。
- trace 用 swift-service-context 的 task-local `ServiceContext` 携带（`withTrace(id) { }`），`Logger.MetadataProvider.traceID` 自动注入；一个工作单元一个 id：IPC 请求 id、helper run id（同时作为它发出的 IPC requestID，daemon 侧同 id）、Mac reconcile id、Relay 请求 id、Worker 的 `cf-ray`。不引 swift-distributed-tracing 的 Tracer / span。
- helper stderr 仍以 `agent-status-helper:` 开头，默认只镜像 warning 以上，`--verbose` 全量。
- Relay `src/log.ts` 同构：`new Logger("ws")` 绑 category，`subsystem:"relay"`，`trace` 提到 `event` 前。
- 去掉了自造的 `AgentStatusLog.shared` API、`RelayHostService` / 两个 watcher 的 `logger:` 闭包和 Mac 端散落的 `NSLog`。

## 验证

- Common：`AgentStatusLoggingTests`（渲染列与 trace 前置、引号转义、级别过滤、errors.log 复制、`withTrace` 作用域与嵌套 Task、轮转、环境解析）。
- CLI：`swift test` 25 个通过（重连测试改为轮询 `connections`，消除 presence 与 observer 之间的竞态）。
- Mac：`swift build` + 57 个测试通过。
- Relay：`wrangler types` 重生成（`LOG_LEVEL`）、`tsc --noEmit`、`eslint src test`、`test/log.test.ts`（格式 / 级别 / child / route 脱敏）。
- `scripts/smoke-local-chain.sh`：日志指到临时目录，断言 `daemon_started` / `events_ingested` / `ipc_handled` / `hook_ingested` / `errors.log` 有 helper 失败，helper 的 run id 出现在 daemon 的 `ipc_handled` 行上（跨进程 trace），且任何日志文件都不含 prompt 文本。

## 未做

- iOS 不写文件（只有 `AgentStatusRemote` 的 transport 行进 os_log）。
- 没有远程上报 / 日志上传。
