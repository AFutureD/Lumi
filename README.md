<div align="center">

<img src="Website/public/assets/lumi-app-icon.svg" width="128" alt="Lumi app icon">

# Lumi

Know when your agents need you.

回合结束、任务失败、中途被打断——需要你的那一刻，Lumi 会找到你。<br>其余时间，它保持安静。

[lumi.huanan.app](https://lumi.huanan.app)

<br>

<img src="docs/assets/lumi-screenshot.jpg" alt="Lumi for Mac 与 Lumi for iPhone">

</div>

## 功能

- Agent 支持：Codex 与 Claude Code，一台 Mac 上的多个 Agent、多个 Session 集中查看。
- Mac 主窗口：三栏布局；Session 列表显示标题、状态、最近更新、模型与 Subagent；详情含 Activity 时间轴（可切换密度、按类别与重要性过滤）和 Token / Context / 耗时指标。
- Notch：屏幕顶部常驻状态条，回合结束或失败时自动展开提示，过程事件全部静默；处理完的 Session 可就地归档。
- iPhone 查看：只读；一台 iPhone 连多台 Mac，所有 Session 合并成一条列表，可过滤、可搜索；内容缓存在本机，Mac 离线也能翻看。目前通过 TestFlight 提供。
- 推送通知：回合结束、失败或被中断时 iPhone 收到推送，点开直达 Session 详情。
- 配对与同步：6 位码 / 二维码配对加双端数字比对，无账号体系；daemon 常驻后台，Mac App 关闭也照样同步。
- 隐私：Session 内容按配对 iPhone 端到端加密，Relay 只转发、不存储；推送仅含 Session 标题和状态词。
- 软件更新：内置签名更新通道，检查与安装均由用户确认。

## FAQ

- 支持哪些 agent？——当前支持主流 coding agent，后续持续扩展。
- 会不会很吵？——不会。只有回合结束、失败、中断三种时刻会提醒你，过程性事件全部静默。
- 关掉窗口 Lumi 还在吗？——在。Notch 和同步照常运行。
- 需要账号吗？——不需要。配对用 6 位码 + 双端数字比对，不经过任何账号体系。
- iPhone 能操控 agent 吗？——不能，v1 是刻意设计的只读。
- 系统要求？——Mac 端 Apple silicon + macOS 26，iPhone 端 iOS 26。

## License

[Apache License 2.0](LICENSE)
