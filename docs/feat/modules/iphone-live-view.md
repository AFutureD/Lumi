# iPhone 在线查看

> 验证状态：开发预览。iOS App 已在模拟器完成编译、单元测试（含缓存与 index 对账的通道测试、配对码 + 数字比对的配对状态机测试）、七个页面走查；2026-08-21 起 Relay Host 移入 daemon、iPhone 改为本机 SQLite 缓存 + index 对账；2026-08-23 起配对改为“6 位配对码 + 两端比对数字 + Mac 点 Match”（已实现并有单元测试，尚未在真机 iPhone 上端到端验收）；真机、弱网与大历史仍待验收。

iPhone 经 Relay（默认内置，也可自托管）与一台或多台 Mac 建立独立通道，只读监看每台 Mac 上的 Session：哪些在跑、跑到哪一步、哪个需要你处理。

## 模块概览

- **iPhone 入口**：底部三个 Tab —— Sessions（合并列表）、Macs（已配对的 Mac）、Settings。
- **Mac 入口**：侧边栏“iPhone”显示 6 位配对码和二维码，并在这里按 Match 批准某台 iPhone。
- **前置条件**：Mac 的 daemon 和 Relay 可用（Mac App 只在配对时需要打开）；配对码 5 分钟内使用。
- **主要结果**：Sessions 把所有 Mac 的 Session 合并成一条列表；Macs 显示每台 Mac 的在线状态和它的 Relay 地址。
- **隐私提示**：已配对 iPhone 会通过端到端加密通道收到 Session 的完整副本，并缓存在本机（每台 Mac 一个数据库）；配对凭据进 Keychain（[IOS-R-010](#ios-r-010-session-内容缓存在本机)）。

## 配对并查看

1. 在 Mac 侧边栏选择“iPhone”。
   - 系统反馈：页面显示 6 位配对码（如 `7KF 3QP`）、二维码、Relay 地址和倒计时；码 5 分钟到期自动换新（[IOS-R-002](#ios-r-002-配对码短时且一次性)）。
2. 在 iPhone 打开 Macs Tab，点右上 `+` > “Add Device”，输入这 6 位（不分大小写，O/0、I/L/1 自动纠正，粘贴整串也行），点 Continue；或点 “Scan code” 扫 Mac 上的二维码（用系统相机扫也会跳进同一页）。
   - 系统反馈：iPhone 显示 Mac 名、Relay 地址和一组 6 位数字（如 `482 913`）；同时 Mac 上出现 “<iPhone 名> wants to pair” 和同一组数字。
   - 替代路径：自托管 Relay 时展开 Advanced 填 Relay URL（留空 = 内置 Relay，填过一次下次预填）；扫码时地址随二维码带过来（[IOS-R-015](#ios-r-015-relay-地址跟着每台-mac-走)）。
3. 核对两边数字一样，在 Mac 上点 Match（iPhone 上没有确认按钮，只有 Cancel）。
   - 系统反馈：iPhone 显示 “Paired · syncing…” 约 1.5 秒后回到 Macs 列表，该 Mac 显示 `Online · <Relay 地址>`；Mac 的 Paired iPhones 里这台 iPhone 显示 Active。
   - 数据结果：这台 iPhone 获得独立授权，并与 Mac 互相核对了身份（[IOS-R-001](#ios-r-001-每台设备独立授权)、[IOS-R-014](#ios-r-014-配对时两端比对数字mac-点-match-才生效)）。数字不一样就在 Mac 上点 Don't match：iPhone 提示 “Mac 拒绝了这次配对”，什么都不保存。
4. 切到 Sessions Tab。
   - 系统反馈：该 Mac 在线并完成一轮对账后，它的 Session 出现在合并列表里，状态点颜色与 Mac、Notch 一致（[IOS-R-009](#ios-r-009-session-状态颜色与-mac-一致)）；之后 Agent 的每条活动实时到达。
5. 点一行 Session。
   - 系统反馈：进入详情，默认 Activity Tab；Info Tab 显示指标和 Session 信息。
   - 数据结果：不向 Agent 发送任何命令（[IOS-R-007](#ios-r-007-在线只读并按-mac-增量同步)）；绿色「已结束未查看」的 Session 打开即算已查看，列表、Mac 和 Notch 一起变灰（[IOS-R-013](#ios-r-013-iphone-打开即视为已查看)）。

完成信号：Macs 里该 Mac 显示 Online，Sessions 里能打开它的 Session 时间线。

## Sessions 列表

每行从上到下：Mac 名称 + 右侧状态胶囊（`Running` / `Waiting` / `Completed` / `Failed`）；标题（最多两行）+ 相对时间；最新一条活动（类别标签 + 内容）；Subagent 组。四段左边界对齐。

- **状态胶囊**：颜色跟五档状态梯级走（[IOS-R-009](#ios-r-009-session-状态颜色与-mac-一致)）；已完成的 Session 不再显示“最新活动”一行。
- **Subagent 组**：子 Agent（包括子 Agent 的子 Agent）不单独占行，Session 运行中时默认展开、其他状态默认折叠成一条计数条——叠在一起的状态点（running → waiting → failed → done）+ `3 subagents · 2 running · 1 done`（只写非零档，与 Mac Notch 文案一致）+ 箭头；点整条展开成标签（每枚显示状态点、名字、用时；一行最多两枚，放不下的名字末尾省略），再点收起，逐行独立记忆。点一枚标签进入该 Subagent 自己的详情，按下时标签变深作为反馈（[IOS-R-011](#ios-r-011-subagent-收成父-session-的标签)）。
- **过滤**：标题下方两枚下拉按钮 —— `Macs`（每台已配对 Mac）和 `Status`（Running 蓝 / Waiting 橙 / Completed 灰，与行上的状态胶囊同色），点开在按钮下方落下一张勾选面板（每项一个复选框、图标和 Session 计数），勾选即时生效、面板不关，一组至少留一项；点面板外或再点一次按钮收起，直接点另一个按钮可切换组；任一组被过滤时按钮变蓝并显示已选数量角标，右端出现 `Reset` 一键回全选。选择会被记住，新配对的 Mac 默认显示。
- **搜索**：导航栏右上的放大镜默认收拢，点开才展开搜索框（系统搜索控件）；按标题、Agent、工作目录和 Subagent 名称即时过滤当前列表。
- **刷新**：下拉列表，或右上 `···` > “Refresh list”，向每台 Mac 重新索取 Session 索引并只补差异。
- **空状态**：未配对时提示去 Macs 添加 Mac；Mac 在线但没有 Session 时显示 No live sessions；Mac 不在线且本机没有缓存时显示 Mac unavailable；有缓存就照常显示（[IOS-R-006](#ios-r-006-mac-离线时继续显示缓存)）。

## Session 详情

头部固定：状态胶囊（如 `Running · Executing`）+ Agent 胶囊（Codex / Claude）、工作目录、Activity / Info 分段。

**Activity**

- 头部下方是三泳道条（User / Model / Exec，与 Mac 同名同序）：列表每一行一格，按所属泳道着色；泳道与下方列表联动滚动——列表滚到哪，泳道跟到对应格子；拖泳道，列表跳到对应行；点格子也跳。
- 列表按时间顺序显示每条活动：类别标签、时间和内容；新活动到达时自动跟到底部。模型每次思考占一行 REASONING，Claude 没有正文的思考显示为 `Empty`（与 Mac 一致）。
- 点一行弹出半高详情：工具调用显示 Command 与 Output（调用和结果自动配对）；其他类别显示完整内容。失败项直接展开到全高。

**Info**

- 三张指标卡：tokens、context、elapsed（运行中的 Session 每秒走动）。
- 分组：Overview（Session ID、Agent、Lifecycle、Turn Phase、Started）、Lineage（有来源信息时显示）、Model、Usage。

**右上 `···`**

- Refresh session：把这个 Session 从 Mac 整个重新取一遍（修复本机缓存与 Mac 不一致）。
- Delete：只在这台 iPhone 上移除该 Session（[IOS-R-012](#ios-r-012-删除只影响这台-iphone)）。

## Macs

- 每行：Mac 名称、状态 + 这台 Mac 的 Relay 地址（`Online · afuture.workers.dev`、`Offline · 2h ago · afuture.workers.dev`，或被撤销后的 `Revoked · afuture.workers.dev`）、在线绿点 / 离线灰点。离线时 Sessions 里仍显示这台 Mac 的缓存内容，这一行是判断新鲜度的地方。
- 点一行：切到 Sessions Tab 并只显示这台 Mac。
- 左滑 > Remove：移除这一条通道、凭据和本机缓存，其他 Mac 不受影响；Mac 侧的配对记录仍在，撤销访问要回到 Mac 操作。
- `+` 菜单：Add Device —— 打开 “Add Mac” 页，输码、扫码、Advanced 里填 Relay URL 都在这一页；Rename this iPhone —— 改的是下次配对时 Mac 看到的名字，已配对的记录不变。
- 脚注：“左滑移除某台 Mac 只关闭这一条通道，其他设备不受影响。凭据保存在 Keychain，每台 Mac 各自记着自己的 Relay。”

## Settings

- **Push notifications**：随系统权限三态显示。未请求过显示蓝色 Allow，点击弹系统授权；已允许显示绿点 + Allowed，已拒绝显示灰点 + Not allowed，点击都跳到 iOS 系统设置。当前 Relay 尚未接入推送，授权后也不会收到通知。
- **About**：Version、Clear received data（清空本机缓存的全部 Session，随后自动从每台 Mac 重新取回）。

## 规则

### IOS-R-001 每台设备独立授权

- 条件：iPhone 用有效配对码提交自己，且 Mac 上点了 Match。
- 行为：系统为这台 iPhone 建立独立授权和加密关系。
- 结果：Mac 可查看并单独撤销该设备。
- 限制或例外：没有共享账号或一份凭据授权全部设备的入口。

### IOS-R-002 配对码短时且一次性

- 条件：Mac 已连接 Relay 并打开“iPhone”页。
- 行为：6 位配对码（字母 + 数字，不分大小写）5 分钟后失效并自动换新；被一台 iPhone 用掉后立即作废；离开“iPhone”页或点 New code 也作废。
- 结果：过期、用过或输错的码在 iPhone 输入页提示“配对码不对或已过期”，不会创建授权。
- 限制或例外：码可以手输（六格，粘贴整串自动分配）或扫码（App 内扫描器、系统相机）；二维码和码里都没有秘密，只有 Relay 地址 + 这 6 位；猜码每分钟次数受限。

### IOS-R-003 已移除：只保存在当前内存

- 状态：removed（2026-08-17）；2026-08-21 由 [IOS-R-010](#ios-r-010-session-内容缓存在本机) 定义为本机缓存。

### IOS-R-004 撤销按设备生效

- 条件：用户在 Mac 上撤销某台 iPhone。
- 行为：该设备授权失效，现有连接关闭；这台 iPhone 识别出凭据被拒后停止重连，Macs 页该 Mac 显示 `Revoked · <Relay 地址>`，Sessions 没有内容时提示 Access revoked。
- 结果：目标 iPhone 无法继续接收数据，已缓存的内容仍可翻看，其他设备不受影响。
- 限制或例外：恢复访问需要重新配对（Mac 出码 → iPhone 输码 → 对数字 → Match）；重新配对同一台 Mac 沿用原来的设备身份，Mac 的 Paired iPhones 里不会多出第二条记录。

### IOS-R-005 Relay 不持久化 Session 历史

- 条件：Mac 发送在线更新。
- 行为：内容在 Mac 按目标设备加密，Relay 只转发密文。
- 结果：Relay 不提供 Session 正文、工具详情或历史查询。
- 限制或例外：Relay 可以保存设备授权、限流和过期时间等运行所需信息。

### IOS-R-006 Mac 离线时继续显示缓存

- 条件：iPhone 未取得该 Mac 的在线状态，或本轮对账尚未完成。
- 行为：Sessions 继续显示该 Mac 本机缓存的 Session；Macs 里该 Mac 显示 Offline、上次同步时间和它的 Relay 地址。
- 结果：启动立即有内容；新鲜度由 Macs 页表达，而不是靠隐藏内容。
- 限制或例外：本机没有缓存且 Mac 离线时，列表显示 Mac unavailable。

### IOS-R-007 在线只读并按 Mac 增量同步

- 条件：对应 Mac 在线。
- 行为：iPhone 先用 Session 索引与本机缓存对账（多余的删、缺失的整取、有变化的只补差异），之后实时应用 Mac 上的每条 Agent 活动。
- 结果：daemon、Mac 和该 iPhone 的可见数据一致；Mac App 是否打开不影响同步。
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

### IOS-R-010 Session 内容缓存在本机

- 条件：iPhone 收到任意 Mac 的 Session。
- 行为：内容写入本机的每台 Mac 一个数据库（与 Mac 同一种格式），重启 App 立即显示；Mac 永远是数据源，本机只是缓存。
- 结果：退出 App 不丢内容；Mac 离线也能翻看；重新上线只传差异。
- 限制或例外：Settings > Clear received data 清空全部缓存并自动重新取回；移除某台 Mac 会删掉它的缓存文件；Keychain 只存配对凭据、设备名、过滤选择和上次同步时间另存。

### IOS-R-011 Subagent 收成父 Session 的标签

- 条件：某个 Session 的子 Agent 也在同一台 Mac 的列表里。
- 行为：子 Agent 不单独占行，折叠成父行下的一条计数条；展开后显示为标签（状态点 + 名字 + 用时），两枚里较窄的一枚不到可用宽一半就并成一行，较宽的一枚封顶三分之二宽、名字末尾省略。
- 结果：一眼看到父 Session 下有几个子 Agent、各自是还在跑、等待、失败还是已完成（计数条按 running → waiting → failed → done 分档计数）；点标签直接打开该子 Agent 的 Activity / Info。
- 限制或例外：父 Session 不在列表里时，子 Agent 以独立行显示。

### IOS-R-012 删除只影响这台 iPhone

- 条件：用户在详情页 `···` > Delete 并确认。
- 行为：该 Session 从这台 iPhone 的列表隐藏。
- 结果：Mac、其他 iPhone 不受影响；隐藏期间它仍在后台更新本机缓存，Mac 发来更新的版本（新的活动或状态变化）时它会重新出现；内容没变的对账不会把它带回来。
- 限制或例外：隐藏只在本次运行有效；重启 App 或 Clear received data 会让它回来。

### IOS-R-013 iPhone 打开即视为已查看

- 条件：iPhone 打开一个绿色「已结束未查看」的 Session 详情。
- 行为：这台 iPhone 上立刻变灰，并把「已查看」告诉对应的 Mac；Mac 更新后，Notch 和其他已配对 iPhone 一起变灰。
- 结果：同一个 Session 在哪一端看过，其他端都不再提示。
- 限制或例外：Mac 离线时只有本机变灰（也写进本机缓存），重连后以 Mac 再次发来的状态为准；这是 iPhone 唯一会发给 Mac 的状态变更，仍不提供审批、终止或输入。

### IOS-R-014 配对时两端比对数字，Mac 点 Match 才生效

- 条件：iPhone 用 Mac 的配对码提交了自己；此版本之前配对过的 iPhone 也要重新配对一次。
- 行为：Mac 先把自己的身份“封”起来交给 Relay，等 iPhone 的身份到了才揭开；两端各自算出同一组 6 位数字。iPhone 先核对揭开的内容和之前封好的一致（不一致就是“校验失败”，放弃），再显示数字；Mac 显示同一组数字和 iPhone 的名字，人比对后点 Match，Mac 才承认并记住这台 iPhone 的身份，Relay 才签发它的凭据。
- 结果：中转服务替换不了任何一方的身份——换了，两边的数字就对不上；Match 后 Mac 的 Paired iPhones 里这台 iPhone 显示 Active 并开始同步。
- 限制或例外：Mac 上 60 秒没点视为拒绝；Don't match 或超时后 iPhone 提示“Mac 拒绝了这次配对”，没有保存任何凭据。Mac 没批准过、或钥匙被中转服务换过的 iPhone 在 Paired iPhones 里显示 Unverified（`Key not verified · pair this iPhone again`），收不到任何内容；这台 iPhone 的 Macs 页仍显示该 Mac Online，但 Session 不再更新，重新配对后恢复。

### IOS-R-015 Relay 地址跟着每台 Mac 走

- 条件：iPhone 添加一台 Mac。
- 行为：扫码时 Relay 地址随二维码带过来；手输时默认用内置 Relay，Add Mac › Advanced 可填自托管地址（只收 https，留空即内置，填过一次下次预填）。配对成功后这条通道一直用当时选定的 Relay。
- 结果：同一台 iPhone 可以同时连着不同 Relay 上的 Mac；Macs 列表每行都写出这台 Mac 的 Relay 地址。
- 限制或例外：Relay 地址不代表可信——填错或扫到别人的二维码最多配上一台“别人的 Mac”，碰不到你自己的 Mac；配对前后都看一眼界面上的 Relay 地址。Mac 侧的 Relay 地址仍由构建配置决定，App 内不可改。

## 空状态与故障

- **No Macs paired**：去 Macs Tab 点 `+` > Add Device。
- **Mac unavailable**：通道断开或 daemon 不可用，且本机没有这台 Mac 的缓存；有缓存时列表照常显示，只在 Macs 页标 Offline。退出 Mac App 不影响。
- **相机不可用**：扫码页提示去 iOS 设置允许相机；改为手输 6 位码。
- **配对码不对或已过期**：输入页六格变红、内容保留，Try again；回到 Mac 看一眼新码（[IOS-R-002](#ios-r-002-配对码短时且一次性)）。
- **Mac 不在线**：码有效，但这台 Mac 没连上 Relay；确认 Mac 上 Agent Status 在运行后 Try again（接着这一次继续）或 Cancel。
- **Mac 拒绝了这次配对**：Mac 点了 Don't match 或 60 秒没点；Start over，在 Mac 上换个新码再来（[IOS-R-014](#ios-r-014-配对时两端比对数字mac-点-match-才生效)）。
- **校验失败**（红色）：Relay 返回的数据不一致，可能有人在中间换钥匙；已中止、没保存任何凭据；Try again（换个网络）或 Cancel，反复出现见[用户摩擦点](../friction-points.md#配对失败)。
- **Mac 上显示 Unverified**：这台 Mac 在 iPhone 上显示 Online 但 Session 不更新；重新配对。

更多恢复步骤见[用户摩擦点](../friction-points.md)。

## 业务数据

iPhone 为每台 Mac 维护一条通道和一个 SQLite 缓存；启动先显示缓存，在线后用索引对账补差异，再实时应用 Agent 活动。Keychain 保存配对凭据（每台 Mac 连同自己的 Relay 地址）；本机还保存设备名、设备过滤选择、每台 Mac 的上次同步时间和 Advanced 里上次填的 Relay URL（只作预填）。完整生命周期见[数据流](../data-flows.md)。

## 相关文档

- [功能全景](../index.md)
- [远程查看旅程](../journeys/check-session-away.md)
- [数据流](../data-flows.md)
- [摩擦点](../friction-points.md)
