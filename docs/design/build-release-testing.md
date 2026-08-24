# 构建、发布与测试设计

工程使用一个 Xcode Workspace 组织两个 App；daemon、helper 和公共库保持 SwiftPM 可独立构建；Relay 使用独立 pnpm 工程。

## 目录与构建单元

```text
lumi/
├── Lumi.xcworkspace
├── Apps/
│   ├── Mac/           # AppKit Xcode App（LumiMac）+ 本地 Swift Package
│   └── iOS/           # UIKit Xcode App（LumiIOS）+ 本地 Swift Package
├── CLI/                      # daemon、helper、daemon runtime SwiftPM
├── Common/
│   ├── Transport/            # Foundation-only 独立 Swift Package
│   └── Sources/              # Core、Persistence、Adapters、IPCClient、Remote、DesignSystem、Diagnostics
├── Relay/                    # TypeScript Worker + Durable Object
├── docs/
└── scripts/
```

Xcode App target 只负责入口、资源、Info.plist、entitlements 和打包；主要控制器代码位于各自本地 Swift Package。

## 平台与依赖

| 项目 | 当前要求 |
| --- | --- |
| macOS | 26+ |
| iOS/iPadOS | 18+ |
| Swift | 6.2 |
| Xcode | 稳定版 26；当前本机验证为 26.6 |
| GRDB | 7.10.0 exact |
| Swift Testing | `swift-6.2.4-RELEASE` revision |
| OpenNook | `https://github.com/AFutureD/opennook.git`，固定 revision `7b0ca6ca251885aecec5834b374ef4dc0907bd8f` |
| Relay | TypeScript 5.9.3、Wrangler 4.123.0、pnpm 11.19.0 |

各 SwiftPM Package 提交自己的 `Package.resolved`；Relay 提交 `pnpm-lock.yaml`。

## 开发构建

### Swift Packages

```sh
swift build --package-path Common/Transport
swift test --package-path Common/Transport
swift build --package-path Common
swift test --package-path Common
swift build --package-path CLI
swift test --package-path CLI
swift test --package-path Apps/Mac/MacPackage
```

### Apps

使用 `Lumi.xcworkspace` 中的共享 scheme：

- `LumiMac`
- `LumiIOS`

App 的 Relay URL 来自各自 `Config/Shared.xcconfig`，不是运行时用户设置。

### Relay

```sh
cd Relay
pnpm install --frozen-lockfile
pnpm run check
pnpm test
pnpm run deploy:dry-run
```

## macOS 嵌入式服务

macOS 产物只有一个脚本 `scripts/macos-bundle.sh`，两个子命令。

Xcode build phase 调用 `scripts/macos-bundle.sh build`：

1. 单次 `swift build` 编出 daemon/helper，仅 arm64（本机架构），Release 只切换 `--configuration release`。
2. 复制到 App `Contents/Resources/`；Release 下随即 `strip -Sx`（Xcode 的 strip 流程只覆盖主程序，嵌入二进制的符号表只能在这里去掉）。
3. 复制 LaunchAgent plist 到 `Contents/Library/LaunchAgents/`。
4. 有签名 identity 时先签 daemon/helper，再由 Xcode 签外层 App。

嵌套 executable 使用 Hardened Runtime。正式发布顺序必须是：内层二进制签名 → App 签名 → Developer ID 验证 → 公证 → Staple。

归档后运行 `scripts/macos-bundle.sh verify <app path>` 检查：

- daemon/helper 包含 arm64。
- 两个 executable 带 Hardened Runtime 标志，且独立 codesign verify 通过。
- LaunchAgent plist 可解析。
- App deep signature 通过。
- Gatekeeper `spctl` 通过。

## Relay 发布

Cloudflare 配置：

- Worker：`lumi-relay`，自定义域名 `relay.lumi.huanan.app`（`workers_dev` 关闭，只有这一个入口）
- Durable Object binding：`HOST_RELAY` → class `HostRelay`（migration `v1`）；`PAIRING_DIRECTORY` → class `PairingDirectory`（migration `v2`）
- Rate limit binding：`RATE_LIMITER`（300 req / 60 s，按客户端地址）
- observability：启用，head sampling 1
- compatibility date：`2026-08-16`

发布命令：

```sh
cd Relay
pnpm exec wrangler deploy
```

发布后至少检查 `GET /health` 返回 `status: ok` 和 `protocolMajor: 1`。

## CI 分层

| Job | 平台 | 验证内容 |
| --- | --- | --- |
| `common` | macOS 26 | Common、Transport build/test、DTO 边界和 golden fixture |
| `cli` | macOS 26 | daemon/helper build/test、本地真实 socket smoke chain |
| `relay` | Ubuntu 24.04 | pnpm lock、types、tsc、eslint、Vitest、Wrangler dry-run |
| `apps` | macOS 26 | package resolve、macOS build、Mac feature tests、iOS Simulator test |

## 测试层级

### 传输

- Session/Timeline Codable round trip。
- 未知枚举值是解码错误（不做兼容兜底）；日期带毫秒往返。
- 4-byte framing 的半包和多包。
- delete request 和 Relay golden fixture。

### Core/Adapter

- reducer 幂等与乱序不回退。
- GRDB 保存、删除、tombstone、单 Session 原子替换（replaceSession）与索引裁剪（pruneSessions）。
- Hook 与 rollout 解析。
- 模型配置、reasoning/world state/压缩上下文和 Token/rate-limit 保留。
- 三端状态颜色语义。

### daemon/helper

- owner-only Unix socket。
- socket 服务端并发语义：单连接并发请求乱序应答、malformed 帧不断连、入站超限帧只断本连接、停读订阅者按出站字节预算断开且不影响其他订阅者、shutdown 解除 `wait()` 并清理 socket 文件、占用路径报错。
- 订阅流（真 socket）：subscribe ack 带 health、事件有序、服务端断开回调恰好一次、stop 后可重启。
- daemon 缺失和坏 stdin。
- `list_sessions` 索引 + 分页 `get_session` 重组出与仓库一致的 Session；超限响应变成 `response_too_large` 失败帧。
- 单事件流多 Session 复用。
- rollout offset 恢复和首次基线。
- 单 Session 删除后被动晚事件不复活；新 prompt / SessionStart 复活。`needsReview` 在 turn end 置位并粘滞，只有已查看清除。
- `RelayHostService`（内存 Relay 双端）：序号先落盘且按设备独立；`sync_index` 分片 + health；`fetch_session` 缺失回 `session_removed`；`fetch_timeline_since` 只回 `since` 之后；事件合并成批、只推已同步设备；`session_info`；Worker 回报非单调序号后自愈并向该设备补发 health；未知设备的首个请求先刷新设备列表再应答；iPhone 的 `session_reviewed` 经本地流（`summary` 帧）到达 Mac；Relay 断开后重连并清空已同步集合；配对 offer 与撤销。

### Relay/Remote

- X25519/HKDF/ChaChaPoly round trip 和错误设备解密失败。
- 一次性配对、列表、撤销和鉴权。
- 每设备独立 sequence。
- Host 离线 presence。
- 设备只能发密封 `request`，其余 kind 关闭为只读违规；非单调 Host 序号回报当前游标。
- Swift/TypeScript 共享 routing fixture。
- `RelayPayloadBatcher`（index 分片 / 事件分批 / 超大事件去 item）、`RelaySessionPartitioner`（turns 只在 part 0、分片重组）、`SyncReconcilePlan`（裁剪 / 整取 / 补尾 / 仅 summary）、仓库新增的 `sessionIndex / updateSummary / mergeSession / timelineSince`。

### Apps

- Mac Hook merge、`RelayHostStatusClient`（脚本化 daemon 的 relay_* 应答）和 Notch snapshot/activity 规则。
- Xcode UI/runtime 验证三栏布局、Notch、配对和删除。
- iOS Simulator 验证多 Mac 分组、Timeline，以及 `RelayDeviceChannel`（内存 Relay + 假 host）：冷启动先显示缓存再对账、事件实时应用与未知 Session 整取、info / removed / reviewed 双向、Clear received data 后回填、凭据被拒后停止重连并标 Revoked、Host 重复 `online` 再次 index、隐藏会话只在更新副本到达时回来、重配同一 Mac 复用 Device ID、孙级子 Agent 并入顶层行。

## 边界检查

`scripts/check-transport-boundaries.sh` 阻止两类漂移：

1. 在 `Transport` 外重复声明核心 Swift DTO。
2. Relay 测试不再消费 Transport Package 的 `transport-v1.json`。

协议变更时先修改 Transport Package 和 fixture，再更新所有消费者。兼容新增字段应保持可选；破坏性改动提升 protocol major。

## 发布门槛

正式可分发版本仍需完成：

1. Developer ID 签名和公证。
2. 干净 Mac 上安装、SMAppService 授权、daemon 更新和卸载。
3. 真实 Codex `/hooks` 触发的端到端链路。
4. 物理 iPhone 摄像头配对、前后台和弱网恢复。
5. 超大单 Session（分片路径）、长时间 Relay 连接和 Durable Object 重启测试。

APNs 不属于当前发布门槛；它是后续独立能力。

## 相关文档

- [整体架构设计](system-architecture.md)
- [数据、通信与保存设计](data-communication-storage.md)
- [Agent Hook 设计](agent-hook.md)
- [Relay、配对与安全设计](relay-pairing-security.md)
