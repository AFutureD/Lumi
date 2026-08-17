# 构建、发布与测试设计

工程使用一个 Xcode Workspace 组织两个 App；daemon、helper 和公共库保持 SwiftPM 可独立构建；Relay 使用独立 pnpm 工程。

## 目录与构建单元

```text
agent-status/
├── AgentStatus.xcworkspace
├── Apps/
│   ├── AgentStatusMac/       # AppKit Xcode App + 本地 Swift Package
│   └── AgentStatusIOS/       # UIKit Xcode App + 本地 Swift Package
├── CLI/                      # daemon、helper、daemon runtime SwiftPM
├── Common/
│   ├── AgentStatusTransport/ # Foundation-only 独立 Swift Package
│   └── Sources/              # Core、Codex、IPC、Remote
├── Relay/                    # TypeScript Worker + Durable Object
├── docs/
└── scripts/
```

Xcode App target 只负责入口、资源、Info.plist、entitlements 和打包；主要控制器代码位于各自本地 Swift Package。

## 平台与依赖

| 项目 | 当前要求 |
| --- | --- |
| macOS | 15+ |
| iOS/iPadOS | 18+ |
| Swift | 6.2 |
| Xcode | 稳定版 26；当前本机验证为 26.6 |
| GRDB | 7.10.0 exact |
| SwiftNIO | 2.101.3 exact |
| Swift Testing | `swift-6.2.4-RELEASE` revision |
| OpenNook | `https://github.com/AFutureD/opennook.git`，固定 revision `7b0ca6ca251885aecec5834b374ef4dc0907bd8f` |
| Relay | TypeScript 5.9.3、Wrangler 4.123.0、pnpm 11.19.0 |

各 SwiftPM Package 提交自己的 `Package.resolved`；Relay 提交 `pnpm-lock.yaml`。

## 开发构建

### Swift Packages

```sh
swift build --package-path Common/AgentStatusTransport
swift test --package-path Common/AgentStatusTransport
swift build --package-path Common
swift test --package-path Common
swift build --package-path CLI
swift test --package-path CLI
swift test --package-path Apps/AgentStatusMac/AgentStatusMacPackage
```

### Apps

使用 `AgentStatus.xcworkspace` 中的共享 scheme：

- `AgentStatusMac`
- `AgentStatusIOS`

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

Xcode build phase 调用 `scripts/build-embedded-services.sh`：

1. Debug 只编译当前 architecture。
2. Release 分别编译 `arm64`、`x86_64`。
3. 使用 `lipo -create` 合并 Universal 2 daemon/helper。
4. 复制到 App `Contents/Resources/`。
5. 复制 LaunchAgent plist 到 `Contents/Library/LaunchAgents/`。
6. 有签名 identity 时先签 daemon/helper，再由 Xcode 签外层 App。

嵌套 executable 使用 Hardened Runtime。正式发布顺序必须是：内层二进制签名 → App 签名 → Developer ID 验证 → 公证 → Staple。

`scripts/verify-macos-bundle.sh` 检查：

- daemon/helper 同时包含 arm64 和 x86_64。
- 两个 executable 独立 codesign verify 通过。
- LaunchAgent plist 可解析。
- App deep signature 通过。
- Gatekeeper `spctl` 通过。

## Relay 发布

Cloudflare 配置：

- Worker：`agent-status-relay`
- Durable Object binding：`HOST_RELAY`
- class：`HostRelay`
- SQLite migration tag：`v1`
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
- unknown enum 兼容。
- 4-byte framing 的半包和多包。
- delete request 和 Relay golden fixture。

### Core/Adapter

- reducer 幂等与乱序不回退。
- GRDB 保存、删除、tombstone 和 snapshot 原子替换。
- Hook 与 rollout 解析。
- reasoning/world state 排除。
- 三端状态颜色语义。

### daemon/helper

- owner-only Unix socket。
- daemon 缺失和坏 stdin。
- 一个 IPC snapshot 返回多个 Session。
- 单事件流多 Session 复用。
- rollout offset 恢复和首次基线。
- 单 Session 删除后晚事件不复活。

### Relay/Remote

- X25519/HKDF/ChaChaPoly round trip 和错误设备解密失败。
- 一次性配对、列表、撤销和鉴权。
- 每设备独立 sequence。
- Host 离线 presence。
- 60 秒内存重放。
- Swift/TypeScript 共享 routing fixture。

### Apps

- Mac Hook merge、Relay 恢复发布和 Notch snapshot/activity 规则。
- Xcode UI/runtime 验证三栏布局、Notch、配对和删除。
- iOS Simulator 验证多 Mac 分组、在线门禁和 Timeline。

## 边界检查

`scripts/check-transport-boundaries.sh` 阻止两类漂移：

1. 在 `AgentStatusTransport` 外重复声明核心 Swift DTO。
2. Relay 测试不再消费 Transport Package 的 `transport-v1.json`。

协议变更时先修改 Transport Package 和 fixture，再更新所有消费者。兼容新增字段应保持可选；破坏性改动提升 protocol major。

## 发布门槛

正式可分发版本仍需完成：

1. Developer ID 签名和公证。
2. 干净 Mac 上安装、SMAppService 授权、daemon 更新和卸载。
3. 真实 Codex `/hooks` 触发的端到端链路。
4. 物理 iPhone 摄像头配对、前后台和弱网恢复。
5. 较大 Session 快照、长时间 Relay 连接和 Durable Object 重启测试。

APNs 不属于当前发布门槛；它是后续独立能力。

## 相关文档

- [整体架构设计](system-architecture.md)
- [数据、通信与保存设计](data-communication-storage.md)
- [Agent Hook 设计](agent-hook.md)
- [Relay、配对与安全设计](relay-pairing-security.md)
