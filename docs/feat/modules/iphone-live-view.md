# iPhone 在线查看

> 验证状态：开发预览。iOS App 已在模拟器完成编译、单元测试、七个页面走查，并通过粘贴配对码与一台真实 Mac 经 Relay 完成配对与 53 个 Session 的同步；iPhone 实机扫码和弱网场景仍待验收。

iPhone 通过产品内置 Relay 与一台或多台 Mac 建立独立通道，只读监看每台 Mac 上的 Session：哪些在跑、跑到哪一步、哪个需要你处理。

## 模块概览

- **iPhone 入口**：底部三个 Tab —— Sessions（合并列表）、Macs（已配对的 Mac）、Settings。
- **Mac 入口**：侧边栏“iPhone”生成一次性配对码。
- **前置条件**：Mac App、daemon 和内置 Relay 可用；配对码在 5 分钟内扫描。
- **主要结果**：Sessions 把所有 Mac 的 Session 合并成一条列表；Macs 显示每台 Mac 的在线状态。
- **隐私提示**：已配对 iPhone 会通过端到端加密通道收到 Session 的完整副本；内容只保存在内存，退出 App 即清除，只有配对凭据进 Keychain（[IOS-R-010](#ios-r-010-session-内容只在内存)）。

## 配对并查看

1. 在 Mac 侧边栏选择“iPhone”，生成二维码。
   - 系统反馈：二维码 5 分钟内有效（[IOS-R-002](#ios-r-002-配对码短时且一次性)）。
2. 在 iPhone 打开 Macs Tab，点右上 `+` > “Scan pairing code”，对准二维码。
   - 系统反馈：扫到即校验并配对，成功后自动返回；Macs 列表出现该 Mac，状态点变绿并显示 Online。
   - 替代路径：Mac 上点 “Copy pairing payload”，iPhone 通过通用剪贴板拿到后点 `+` > “Paste pairing code”，配对结果以弹窗提示。
   - 数据结果：这台 iPhone 获得独立授权（[IOS-R-001](#ios-r-001-每台设备独立授权)）。
3. 切到 Sessions Tab。
   - 系统反馈：该 Mac 在线并完成一轮同步后，它的 Session 出现在合并列表里，状态点颜色与 Mac、Notch 一致（[IOS-R-009](#ios-r-009-session-状态颜色与-mac-一致)）。
4. 点一行 Session。
   - 系统反馈：进入详情，默认 Activity Tab；Info Tab 显示指标和 Session 信息。
   - 数据结果：不向 Agent 发送任何命令（[IOS-R-007](#ios-r-007-在线只读并按-mac-同步)）；绿色「已结束未查看」的 Session 打开即算已查看，列表、Mac 和 Notch 一起变灰（[IOS-R-013](#ios-r-013-iphone-打开即视为已查看)）。

完成信号：Macs 里该 Mac 显示 Online，Sessions 里能打开它的 Session 时间线。

## Sessions 列表

每行从上到下：Mac 名称 + 右侧状态胶囊（`Running` / `Waiting` / `Completed` / `Failed`）；标题（最多两行）+ 相对时间；最新一条活动（类别标签 + 内容）；Subagent 组。四段左边界对齐。

- **状态胶囊**：颜色跟五档状态梯级走（[IOS-R-009](#ios-r-009-session-状态颜色与-mac-一致)）；已完成的 Session 不再显示“最新活动”一行。
- **Subagent 组**：子 Agent 不单独占行，Session 运行中时默认展开、其他状态默认折叠成一条计数条——叠在一起的状态点（running → waiting → done）+ `3 subagents · 2 running · 1 done`（只写非零档）+ 箭头；点整条展开成标签（每枚显示状态点、名字、用时；一行最多两枚，放不下的名字末尾省略），再点收起，逐行独立记忆。点一枚标签进入该 Subagent 自己的详情，按下时标签变深作为反馈（[IOS-R-011](#ios-r-011-subagent-收成父-session-的标签)）。
- **过滤**：标题下方两枚下拉按钮 —— `Macs`（每台已配对 Mac）和 `Status`（Running / Waiting / Completed），点开是带计数的多选勾选菜单，勾选即时生效，一组至少留一项；任一组被过滤时按钮变蓝并显示已选数量角标，右端出现 `Reset` 一键回全选。选择会被记住，新配对的 Mac 默认显示。
- **搜索**：导航栏右上的放大镜默认收拢，点开才展开搜索框（系统搜索控件）；按标题、Agent、工作目录和 Subagent 名称即时过滤当前列表。
- **刷新**：下拉列表，或右上 `···` > “Refresh list”，向每台 Mac 重新索取当前全部 Session。
- **空状态**：未配对时提示去 Macs 扫码；Mac 在线但没有 Session 时显示 No live sessions；Mac 不在线时显示 Mac unavailable，不展示旧 Session（[IOS-R-006](#ios-r-006-mac-离线时不显示旧-session)）。

## Session 详情

头部固定：状态胶囊（如 `Running · Executing`）+ Agent 胶囊（Codex / Claude）、工作目录、Activity / Info 分段。

**Activity**

- 头部下方是三泳道条（Input / Tools / Model）：每个事件一格，按所属泳道着色；泳道与下方列表联动滚动——列表滚到哪，泳道跟到对应格子；拖泳道，列表跳到对应行；点格子也跳。
- 列表按时间顺序显示每条活动：类别标签、时间和内容；新活动到达时自动跟到底部。
- 点一行弹出半高详情：工具调用显示 Command 与 Output（调用和结果自动配对）；其他类别显示完整内容。失败项直接展开到全高。

**Info**

- 三张指标卡：tokens、context、elapsed（运行中的 Session 每秒走动）。
- 分组：Overview（Session ID、Agent、Lifecycle、Turn Phase、Started）、Lineage（有来源信息时显示）、Model、Usage。

**右上 `···`**

- Refresh：向该 Mac 重新索取全部 Session。
- Delete：只在这台 iPhone 上移除该 Session（[IOS-R-012](#ios-r-012-删除只影响这台-iphone)）。

## Macs

- 每行：Mac 名称、状态（`Online · 3 sessions · 已配对 Aug 14` 或 `Unavailable · 上次同步 2h 前`）、在线绿点 / 离线灰点。
- 点一行：切到 Sessions Tab 并只显示这台 Mac。
- 左滑 > Remove：移除这一条通道、凭据和内存中的 Session，其他 Mac 不受影响；Mac 侧的配对记录仍在，撤销访问要回到 Mac 操作。
- `+` 菜单：Scan pairing code；Paste pairing code（用 Mac 复制的配对内容，首次会弹系统“允许粘贴”）；Rename this iPhone —— 改的是下次配对时 Mac 看到的名字，已配对的记录不变。

## Settings

- **Push notifications**：随系统权限三态显示。未请求过显示蓝色 Allow，点击弹系统授权；已允许显示绿点 + Allowed，已拒绝显示灰点 + Not allowed，点击都跳到 iOS 系统设置。当前 Relay 尚未接入推送，授权后也不会收到通知。
- **About**：Version、Clear received data（清空内存里的全部 Session，下拉刷新可重新取回）。

## 规则

### IOS-R-001 每台设备独立授权

- 条件：iPhone 使用有效配对码完成配对。
- 行为：系统为这台 iPhone 建立独立授权和加密关系。
- 结果：Mac 可查看并单独撤销该设备。
- 限制或例外：没有共享账号或一份凭据授权全部设备的入口。

### IOS-R-002 配对码短时且一次性

- 条件：Mac 已连接 Relay 并生成配对码。
- 行为：配对码 5 分钟后失效，成功使用后不能再次使用。
- 结果：过期或重复扫码不会创建新授权。
- 限制或例外：需要回到 Mac 重新生成；iPhone 只接受扫码或粘贴的完整配对内容，不支持手动输入。

### IOS-R-003 已移除：只保存在当前内存

- 状态：removed（2026-08-17），2026-08-21 起由 [IOS-R-010](#ios-r-010-session-内容只在内存) 以新语义重新定义。

### IOS-R-004 撤销按设备生效

- 条件：用户在 Mac 上撤销某台 iPhone。
- 行为：该设备授权失效，现有连接关闭。
- 结果：目标 iPhone 无法继续接收数据，其他设备不受影响。
- 限制或例外：恢复访问需要重新配对。

### IOS-R-005 Relay 不持久化 Session 历史

- 条件：Mac 发送在线更新。
- 行为：内容在 Mac 按目标设备加密，Relay 只转发密文。
- 结果：Relay 不提供 Session 正文、工具详情或历史查询。
- 限制或例外：Relay 可以保存设备授权、限流和过期时间等运行所需信息。

### IOS-R-006 Mac 离线时不显示旧 Session

- 条件：iPhone 未取得该 Mac 的在线状态，或本轮同步尚未收全。
- 行为：Sessions 不展示该 Mac 的 Session；Macs 里该 Mac 显示 Unavailable 和上次同步时间。
- 结果：旧数据不会被误认为当前 Agent 状态。
- 限制或例外：已打开的详情页继续显示最后一次收到的内容，直到该 Session 被移除。

### IOS-R-007 在线只读并按 Mac 同步

- 条件：对应 Mac 在线且本轮同步已收全。
- 行为：iPhone 展示该 Mac 的全部 Session。
- 结果：daemon、Mac 和该 iPhone 的可见数据一致。
- 限制或例外：iPhone 不提供审批、终止、输入或其他远程控制。

### IOS-R-008 一台 iPhone 可连接多台 Mac

- 条件：用户分别完成多台 Mac 的配对。
- 行为：iPhone 为每台 Mac 维护独立通道和状态；Sessions 合并显示，并可按 Mac 过滤。
- 结果：不同 Mac 的 Session 不会混淆，每行都标出来源 Mac。
- 限制或例外：移除一条通道不影响其他通道。

### IOS-R-009 Session 状态颜色与 Mac 一致

- 条件：iPhone 显示来自任意已配对 Mac 的 Session。
- 行为：列表状态胶囊与详情状态胶囊遵循五档梯级 [MAC-R-013](./mac-session-view.md#mac-r-013-session-状态颜色跨端一致)，包括绿色“已结束但还没看过”档。
- 结果：切换 Mac 通道或查看同一 Session 的不同客户端时，颜色含义不变。
- 限制或例外：绿色标记在任一端打开即清除——Mac 侧见 [MAC-R-019](./mac-session-view.md#mac-r-019-打开-session-即视为已查看)，iPhone 侧见 [IOS-R-013](#ios-r-013-iphone-打开即视为已查看)。

### IOS-R-010 Session 内容只在内存

- 条件：iPhone 收到任意 Mac 的 Session。
- 行为：内容只保存在内存；每次连接都向 Mac 重新索取全部 Session。
- 结果：退出 App 后本机不留 Session 正文；只有配对凭据、设备名、过滤选择和上次同步时间保留。
- 限制或例外：Settings > Clear received data 可立即清空，下拉刷新重新取回。

### IOS-R-011 Subagent 收成父 Session 的标签

- 条件：某个 Session 的子 Agent 也在同一台 Mac 的列表里。
- 行为：子 Agent 不单独占行，折叠成父行下的一条计数条；展开后显示为标签（状态点 + 名字 + 用时），两枚里较窄的一枚不到可用宽一半就并成一行，较宽的一枚封顶三分之二宽、名字末尾省略。
- 结果：一眼看到父 Session 下有几个子 Agent、各自是否还在跑；点标签直接打开该子 Agent 的 Activity / Info。
- 限制或例外：父 Session 不在列表里时，子 Agent 以独立行显示。

### IOS-R-012 删除只影响这台 iPhone

- 条件：用户在详情页 `···` > Delete 并确认。
- 行为：该 Session 从这台 iPhone 的内存移除。
- 结果：Mac、其他 iPhone 不受影响；Mac 发来该 Session 的更新版本时它会重新出现。
- 限制或例外：退出 App 或 Clear received data 后，下一次同步会重新收到它。

### IOS-R-013 iPhone 打开即视为已查看

- 条件：iPhone 打开一个绿色「已结束未查看」的 Session 详情。
- 行为：这台 iPhone 上立刻变灰，并把「已查看」告诉对应的 Mac；Mac 更新后，Notch 和其他已配对 iPhone 一起变灰。
- 结果：同一个 Session 在哪一端看过，其他端都不再提示。
- 限制或例外：Mac 离线时只有本机变灰，重连后以 Mac 再次发来的状态为准；这是 iPhone 唯一会发给 Mac 的状态变更，仍不提供审批、终止或输入。

## 空状态与故障

- **No Macs paired**：去 Macs Tab 扫码。
- **Mac unavailable**：通道断开、Mac App 退出或 daemon 不可用；不展示旧 Session。
- **相机不可用**：扫码页提示去 iOS 设置允许相机；改用 `+` > “Paste pairing code”。
- **配对码过期或无效**：扫码页停留并提示，回到 Mac 重新生成。

更多恢复步骤见[用户摩擦点](../friction-points.md)。

## 业务数据

iPhone 为每台 Mac 维护一条通道；Session 内容只在内存，收到在线状态且本轮同步完整后才展示。Keychain 保存配对凭据；本机还保存设备名、设备过滤选择和每台 Mac 的上次同步时间。完整生命周期见[数据流](../data-flows.md)。

## 相关文档

- [功能全景](../index.md)
- [远程查看旅程](../journeys/check-session-away.md)
- [数据流](../data-flows.md)
- [摩擦点](../friction-points.md)
