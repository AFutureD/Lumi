<div align="center">

[English](README.md) · 简体中文

<img src="Website/public/assets/lumi-app-icon.svg" width="128" alt="Lumi App 图标">

# Lumi

Know when your agents need you.

Lumi 将多个 Agent 的 Session 集中到 Mac 的同一处。<br>
你可以在 Lumi for Mac 或 Notch 查看当前状态；离开 Mac 时，再通过已配对的 iPhone 跟进。

[下载 Mac 版](https://lumi.huanan.app/download) · [加入 iPhone TestFlight](https://testflight.apple.com/join/uYcSWMzV) · [官方网站](https://lumi.huanan.app)

<br>

<img src="docs/assets/lumi-screenshot.jpg" alt="Lumi for Mac 与 Lumi for iPhone">

</div>

## 当前支持

> [!IMPORTANT]
> Lumi 仍在积极开发中。目前仅支持以下 Agent 和 Application。

| 概念 | 当前支持 |
| --- | --- |
| Agent | Codex、Claude Code |
| Application | ChatGPT、Codex、Claude Code、Claude Desktop、Raft、Paseo |

## 从这里开始

**在 Mac 上开始——4 步**

1. 在运行 macOS 26 或更高版本的 Apple silicon Mac 上[下载 Lumi for Mac](https://lumi.huanan.app/download)。
2. 打开 `Settings > Daemon`，点击 `Install & Start daemon`。
3. 打开 `Settings > Agents`，为 Codex 或 Claude Code 点击 `Install`。
4. 在这个 Agent 中开始一项任务。

**完成：** Session 出现在 Lumi 中，并随着 Agent 工作持续更新。

**配对 iPhone——可选，4 步**

1. 在 iOS 26 或更高版本上通过 TestFlight 安装 [Lumi for iPhone](https://testflight.apple.com/join/uYcSWMzV)。
2. 在 Lumi for Mac 中打开 `iPhone` 页面，并停留在这里。
3. 在 iPhone 上打开 `Macs`，点击 `+ > Add Device`，再扫描或输入 Mac 上显示的配对码。
4. 比对两台设备上的数字；数字相同时，在 Mac 上点击 `Match`。

**完成：** Mac 将这台 iPhone 显示为 `Active`，对应 Session 出现在 iPhone 上。

## Lumi 能为你做什么

- **Mac 总览。** 一眼查看所有 Session 的状态；打开其中一个，即可检查完整 Activity 和关键指标。
- **安静的 Notch。** Agent 工作时保持紧凑，回合结束、失败或被中断时才展开。关闭 Mac 窗口不会停止 Notch 或同步。
- **iPhone 查看。** 搜索、过滤多台已配对 Mac 的 Session。Mac 离线时仍可阅读缓存内容；收到通知后可以直接打开需要处理的 Session。
- **更新由你控制。** Lumi 使用签名的 Stable 更新通道；何时检查、下载和安装都由你决定。

## 隐私与产品边界

- **只读。** Lumi 只观察 Agent Session，不控制 Agent。Lumi for iPhone 不能批准操作、停止任务或向 Agent 发送输入。
- **无需账号。** 配对从二维码或短时有效的 6 位配对码开始；只有你确认两台设备显示相同数字后，访问才会生效。
- **Session 隐私。** 内容会针对每台已配对的 iPhone 分别加密。Relay 只转发加密后的 Session 数据，不存储，也无法读取。
- **通知隐私。** 通知的可见文本只包含 Session 标题和状态，不包含 Session 内容、Activity 或工具输出。这段文本会以明文经过 Relay 发送，但不会存储在 Relay 中。

## FAQ

**Session 没有出现**

1. 确认 `Settings > Daemon` 显示 `Running`。
2. 确认 `Settings > Agents` 中的 Agent 显示 `Installed`。
3. 如果 Codex 显示信任警告，点击 `Trust`。
4. 在 Agent 中开始一项新任务。

**iPhone 配对没有完成**

1. 停留在 Mac 的 `iPhone` 页面。
2. 如果配对码显示 `Expired`，点击 `New code`。
3. 比对数字，并在 Mac 上点击 `Match`。

**iPhone 上的 Mac 显示 `Offline`**

缓存的 Session 仍可阅读。恢复 Mac 上的 daemon 和网络连接后，同步会自动继续。

如需查看完整行为与恢复路径，请阅读[功能文档](docs/FEAT.md)。

## License

[Apache License 2.0](LICENSE)