# 在 iPhone 上查看多台 Mac

> 验证状态：开发预览。iOS 模拟器已与真实 Mac 经 Relay 配对并同步 Session，合并列表、详情、Macs 和 Settings 均已走查；配对（6 位码 + 两端比对数字 + Mac 点 Match）与推送链路三端有单元测试，但尚未在真机 iPhone 上端到端验收；弱网恢复同样待验收。

最短路径：Mac 打开“iPhone”看到 6 位码 > iPhone Macs Tab 点 `+` > Add Device 输码（或扫码）> 两边数字一样就在 Mac 点 Match > 回到 Sessions Tab 点 Session。

## 用户目标

- 离开 Mac 屏幕后继续查看 Agent 进度，回合结束时收到提醒。
- 在一台 iPhone 上看全多台 Mac 的 Session，并能按 Mac 过滤。
- 只查看状态，不从手机审批、终止或操作 Agent。

## 前置条件

- Mac 的 daemon 和网络可用；配对全程需要停在 Mac 的“iPhone”页完成（离开页面或退出 Mac App 会取消配对），配对之后的日常同步不需要打开 Mac App。
- iPhone 运行 iOS 26 或更高版本，能访问这台 Mac 用的 Relay：内置 Relay 不用填；自托管时扫码自动带上，手输要在 Advanced 里填。
- 配对码 5 分钟有效、只能用一次；最后一步 Match 在 Mac 上完成。

## 第一台 Mac

1. 在 Mac 侧边栏选择“iPhone”。
   - 系统反馈：显示 Relay connected、6 位配对码（如 `7KF-3QP`）、二维码、Relay 地址和倒计时。
2. 在 iPhone 打开 Macs Tab，点右上 `+` > “Add Device”，输入这 6 位后点 Continue（或点 “Scan code” 扫二维码）。
   - 系统反馈：iPhone 显示 Mac 名、Relay 地址和一组 6 位数字（如 `482 913`）；Mac 上同时出现 “<iPhone 名> wants to pair” 和同一组数字。
3. 两边数字一样，在 Mac 上点 Match。
   - 系统反馈：iPhone 显示 “Paired · syncing…” 后自动回到 Macs 列表，该 Mac 显示 `Online · <Relay 地址>`；Mac 的 Paired iPhones 里这台 iPhone 显示 Active。
   - 数据变化：为这台 iPhone 建立独立授权，双方互相核对了身份（[IOS-R-001](../modules/iphone-live-view.md#ios-r-001-每台设备独立授权)、[IOS-R-014](../modules/iphone-live-view.md#ios-r-014-配对时两端比对数字mac-点-match-才生效)）。
4. 切到 Sessions Tab。
   - 系统反馈：对账完成后它的 Session 出现在列表里，每行标出 Mac 名称，之后新活动实时到达（[IOS-R-007](../modules/iphone-live-view.md#ios-r-007-在线只读并按-mac-增量同步)）。
5. 点目标 Session。
   - 系统反馈：Activity 显示三泳道和时间线，Info 显示指标与 Session 信息。
   - 数据变化：只改变查看位置，不发送控制操作；绿色待查看的 Session 打开即算已查看并同步到所有端（[IOS-R-013](../modules/iphone-live-view.md#ios-r-013-iphone-打开即视为已查看)）。
6. 在 Settings 点 Allow 允许通知（可选）。
   - 系统反馈：弹出系统授权；允许后该行显示绿点 + Allowed。
   - 数据变化：之后任一已配对 Mac 的 Session 回合结束、失败或被中断时，这台 iPhone 收到系统推送，点通知直接落在该 Session 详情页（[IOS-R-016](../modules/iphone-live-view.md#ios-r-016-关键时刻推送提醒)）。

完成信号：Macs 里该 Mac 显示 Online，Sessions 里能打开它的 Session 时间线；允许通知后，App 不在前台也能收到回合结束提醒。

## 再添加一台 Mac

1. 在另一台 Mac 打开“iPhone”页。
2. 在 iPhone Macs Tab 点 `+` > “Add Device”，输入那台 Mac 的码（或扫码），对数字，在那台 Mac 上点 Match。
   - 那台 Mac 用的是另一个自托管 Relay 时：扫码自动带上；手输展开 Advanced 填它的 Relay URL（[IOS-R-015](../modules/iphone-live-view.md#ios-r-015-relay-地址跟着每台-mac-走)）。
3. 回到 Sessions Tab。
   - 系统反馈：两台 Mac 的 Session 合并在一条列表里；标题下方的 `Macs` 下拉里多出这台 Mac；Macs 页每行写着各自的 Relay 地址。
   - 数据变化：新增一条独立通道，原通道不受影响（[IOS-R-008](../modules/iphone-live-view.md#ios-r-008-一台-iphone-可连接多台-mac)）。

只想看其中一台：在 `Macs` 下拉里取消其他 Mac，或在 Macs Tab 点那台 Mac 的行；`Status` 下拉可再按 Running / Waiting / Completed 过滤，`Reset` 回全选。过滤选择会被记住。

## 失败路径

### Relay unavailable

- 用户看到：Mac“iPhone”页药丸显示 Relay unavailable，配对码区显示 `···-···`。
- 可执行动作：确认网络可用，停在页面等自动重试（每 30 秒）或点 New code；Mac 侧 Relay 地址由构建固定，App 内无法修改。
- 完成信号：页面恢复 Relay connected 并出现配对码。

已有配对时 Relay 中断，Macs 里每台 Mac 分别显示 Offline，Sessions 继续显示缓存；恢复后各自回到 Online 并按索引补差异。

### 相机不可用

- 用户看到：扫码页提示相机不可用。
- 可执行动作：在 iOS 设置里允许相机后重新扫码；或直接在 Add Mac 页手输 6 位码。
- 数据影响：成功前不会创建设备授权。

### 配对码不对或已过期

- 用户看到：Add Mac 页六格变红，提示“配对码不对或已过期”，输入内容保留。
- 可执行动作：回到 Mac 看一眼当前的码（显示 Expired 就点 New code），改好后 Try again（[IOS-R-002](../modules/iphone-live-view.md#ios-r-002-配对码短时且一次性)）。
- 数据影响：不会创建设备授权。

### Mac 不在线

- 用户看到：iPhone 提示“Mac 不在线”——码是对的，但这台 Mac 没连上 Relay。
- 可执行动作：确认 Mac 上 Lumi 在运行、“iPhone”页显示 Relay connected，点 Try again（接着这一次继续）；或 Cancel。

### Mac 拒绝了这次配对

- 用户看到：iPhone 提示“Mac 拒绝了这次配对”；Mac 上显示 Pairing declined 后自动换新码。
- 可执行动作：如果只是 60 秒没来得及点，Start over 重新输码再来一次；如果数字确实不一样，停止配对（[IOS-R-014](../modules/iphone-live-view.md#ios-r-014-配对时两端比对数字mac-点-match-才生效)、[摩擦点：配对失败](../friction-points.md#配对失败)）。
- 数据影响：没有保存任何凭据。

### 校验失败

- 用户看到：iPhone 红色提示“校验失败”：Relay 返回的数据不一致，已中止配对。
- 可执行动作：换个网络 Try again；仍失败时停止配对，检查这台 Mac 用的 Relay（[摩擦点：配对失败](../friction-points.md#配对失败)）。
- 数据影响：不会创建设备授权。

### Mac 离线

- 用户看到：Macs 里该 Mac 显示 `Offline · 2h ago · <Relay 地址>`，Sessions 里仍能翻看它上次同步的内容。
- 可执行动作：恢复 Mac 的 daemon 和网络；上线后自动补差异。
- 数据影响：配对关系和本机缓存保留，其他 Mac 通道继续工作（[IOS-R-006](../modules/iphone-live-view.md#ios-r-006-mac-离线时继续显示缓存)）；离线期间没有推送提醒。

### 设备被撤销

- 用户看到：连接关闭；Macs 页这台 Mac 显示 `Revoked · <Relay 地址>`，缓存仍可翻看；推送提醒停止。
- 可执行动作：在 Mac“iPhone”页看码，iPhone 重新走一遍配对（沿用原设备身份）。
- 数据影响：只影响被撤销的 iPhone。

### 升级后 Mac 上显示 Unverified

- 用户看到：iPhone 的 Macs 页该 Mac 显示 Online，但 Session 停止更新；Mac 的 Paired iPhones 里这台 iPhone 显示 Unverified。旧版本配对过的 iPhone 升级后都会遇到。
- 可执行动作：重新走一遍配对（输码、对数字、Mac 点 Match），沿用原设备身份（[IOS-R-014](../modules/iphone-live-view.md#ios-r-014-配对时两端比对数字mac-点-match-才生效)、[摩擦点：Unverified](../friction-points.md#iphone-在-mac-上显示-unverified)）。
- 数据影响：本机缓存保留，重配后继续增量同步。

## 为同一台 Mac 配对第二台 iPhone

1. 在 Mac 打开“iPhone”页（码显示 Expired 就点 New code）。
2. 在第二台 iPhone 输码或扫码，两边对数字，在 Mac 上点 Match。
3. 返回 Mac 查看 Paired iPhones。
   - 系统反馈：出现第二条独立记录，两台 iPhone 都可以在线查看。
4. 在 Mac 对其中一条记录执行“Revoke”。
   - 系统反馈：只有目标 iPhone 断开，另一台继续工作。

## 移除一台 Mac

在 iPhone Macs Tab 左滑该 Mac > Remove 并确认。这台 iPhone 上的通道、凭据和本机缓存被删除，其他 Mac 保持连接；Mac 和 Relay 侧的授权记录仍在。若目标是撤销访问权，还需在 Mac“iPhone”页对该设备执行“Revoke”。

Mac 上删除一个 Session 时，在线 iPhone 立即移除对应条目，离线的 iPhone 在重连对账时移除；这不影响其他 Session 或其他 Mac。

## 持久化结果

- iPhone 为每台 Mac 保存独立凭据（含那台 Mac 的 Relay 地址）和一个本机缓存数据库；重启 App 立即显示上次内容（[IOS-R-010](../modules/iphone-live-view.md#ios-r-010-session-内容缓存在本机)）。
- Relay 保存授权、进行中的配对会话和推送地址等运行所需信息，不保存可浏览的 Session 历史。
- Mac 离线时继续显示缓存并标 Offline；恢复后按索引补差异。

## 用户可见的完成状态

- 完成信号：Macs 里目标 Mac 显示 Online；Sessions 能打开它的 Session；允许通知后回合结束能收到推送。
- 尚未完成的区别：只输完码、还没在 Mac 点 Match 时没有任何授权；Mac 显示 Offline 时看到的是缓存，不是实时状态。

## 下一目标

回到 [Mac 会话查看](../modules/mac-session-view.md)，处理需要输入或发生错误的 Session。

## 涉及模块与数据

- [iPhone 在线查看](../modules/iphone-live-view.md)
- [业务数据流](../data-flows.md)
- [用户摩擦点](../friction-points.md)
