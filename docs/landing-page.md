# Landing Page 内容稿

Lumi 官网落地页的 Section 结构与文案基准。搭页时以此为内容来源；文案改动先改这里。

核心主张：Know when your agents need you。全页从 SEO 到首屏到尾部 CTA 只讲这一句话——agent 自主干活，Lumi 只在需要你的时刻找到你，其余时间保持安静。

命名口径：Lumi / Notch / Session / Activity / daemon / Hook / Relay，agent 全程统称、不点名具体产品。英文承担骨架句（Hero、Tagline、Privacy boundary、How it works、底部 CTA、SEO），中文承担功能正文与 FAQ。

叙事线：Hero 立题 → Tagline 情绪锤 → 三功能按场景递进（离开 Mac → 在 Mac 前 → 回来之后）→ Privacy boundary 信任背书 → 三步上手 → FAQ 消疑 → 尾部呼应闭环。

---

## 1. Hero（首屏）

标题

> Know when your agents need you.

副标题

> 回合结束、任务失败、中途被打断——需要你的那一刻，Lumi 会找到你。其余时间，它保持安静。

CTA

- 主按钮：Download for Mac
- 次按钮：Join TestFlight
- 按钮下方小字：iPhone 端 Beta 测试中 · Apple silicon · macOS 26

配图建议：iPhone 锁屏推送做主视觉，Notch 自动展开做次要元素——两个「找到你」的瞬间。

## 2. Tagline reveal

> Your agents keep moving.
> You only step in when it matters.

呈现建议：大字排版、滚动渐显（第一句先出现，第二句随滚动浮现），无正文、无按钮——两句话独立成屏。

## 3. 功能一：iPhone 远程查看 + 推送

小标题

> 离开 Mac，也不会错过需要你的时刻。

正文

> 回合结束、失败或被中断，iPhone 收到推送，点开直达 Session 详情——该回去还是继续待着，十秒判断。
>
> 一台 iPhone 连多台 Mac；Mac App 关着照样同步，离线时缓存照样能翻。

小字补充

> 只读设计——看得见，改不了。目前通过 TestFlight 提供。

## 4. 功能二：Notch

小标题

> 人在 Mac 前，一抬眼就够了。

正文

> 平时只是顶部一小条；回合结束或失败才自动展开提示，过程一概不打扰。
>
> 打扰你的每一次，都是真的需要你。

## 5. 功能三：Mac 主窗口

小标题

> 被叫回来，完整历史都在。

正文

> 三栏窗口，像看邮件一样看 Session：谁在等你一眼可见，时间轴还原它停在哪一步，Token、Context、耗时随手可查。

## 6. Privacy boundary

Heading

> Your Session content is encrypted for each paired iPhone.

Primary explanation

> Relay forwards encrypted Session payloads — it stores nothing and reads nothing. The daemon on your Mac is the only source of truth; your iPhone keeps its own local cache.

Small print

> Push notifications carry only the Session title and status — never the content.

Image：架构图：Mac（daemon，数据源）→ 按 iPhone 加密的通道 → Relay（只转发，无存储）→ iPhone（本地缓存）。重点视觉：加密发生在 Mac 上、Relay 处在加密段中间碰不到内容。图注避免使用 p2p，用 end-to-end encrypted channel。

Link

> Read the privacy policy

## 7. How it works

小标题

> Three steps, then forget about it.

1. Connect Lumi

   Install Lumi for Mac, start the daemon, and enable the Hook for the agents you use. One-time setup, about a minute.

2. Keep working

   Use your agents exactly as you do now — nothing about your workflow changes. Lumi picks up every new Session and keeps its Activity updating as work happens.

3. Check what matters

   When a Session needs you, it finds you — a glance at the Notch, the full timeline in Lumi for Mac, or a push on your paired iPhone.

## 8. FAQ

- 支持哪些 agent？——当前支持主流 coding agent，后续持续扩展。
- 会不会很吵？——不会。只有回合结束、失败、中断三种时刻会提醒你，过程性事件全部静默。
- 关掉窗口 Lumi 还在吗？——在。Notch 和同步照常运行。
- 需要账号吗？——不需要。配对用 6 位码 + 双端数字比对，不经过任何账号体系。
- iPhone 能操控 agent 吗？——不能，v1 是刻意设计的只读。
- 系统要求？——Mac 端 Apple silicon + macOS 26，iPhone 端 iOS 26。

## 9. 底部 CTA

> Your agents will need you.
> 到时候，别靠运气知道。

- 主按钮：Download for Mac
- 次按钮：Join TestFlight
- 辅助链接：文档 · 更新日志

## 10. Footer

Brand

> Lumi

Links

- GitHub
- Privacy
- Terms
- Back to top

Copyright

> © 2026 Lumi

## SEO

Title

> Lumi — Know when your agents need you

Meta description

> Track agent sessions from Mac and iPhone with clear status, complete Activity, read-only remote viewing, and encrypted device sync.

---

## 待办

- Privacy 与 Terms 页面尚未准备，Section 6 与 Footer 各有一处链接指向 Privacy。
- 三个功能段的文案假设旁边有截图在干活；某个 Section 最终没配图的话，文字需要补回描述性内容。
