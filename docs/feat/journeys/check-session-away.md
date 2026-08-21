# 在 iPhone 上查看多台 Mac

> 验证状态：开发预览。iOS 模拟器已通过粘贴配对码与真实 Mac 经 Relay 配对并同步 Session，合并列表、详情、Macs 和 Settings 均已走查；iPhone 实机扫码和弱网恢复仍待验收。

最短路径：Mac 打开“iPhone”生成二维码 > iPhone 打开 Macs Tab 点 `+` 扫码 > 回到 Sessions Tab 点 Session。

## 用户目标

- 离开 Mac 屏幕后继续查看 Agent 进度。
- 在一台 iPhone 上看全多台 Mac 的 Session，并能按 Mac 过滤。
- 只查看状态，不从手机审批、终止或操作 Agent。

## 前置条件

- Mac 的 daemon 和网络可用（Mac App 只在生成配对码时需要打开）。
- iPhone 与 Mac 使用同一产品构建所配置的 Relay。
- 只把配对码交给受信任设备。

## 第一台 Mac

1. 在 Mac 侧边栏选择“iPhone”，生成二维码。
   - 系统反馈：显示 Relay connected、二维码和配对记录。
2. 在 iPhone 打开 Macs Tab，点右上 `+` > “Scan pairing code”，对准二维码。
   - 系统反馈：配对成功自动返回，Macs 列表出现该 Mac 并显示 Online。
   - 数据变化：为这台 iPhone 建立独立授权（[IOS-R-001](../modules/iphone-live-view.md#ios-r-001-每台设备独立授权)）。
3. 切到 Sessions Tab。
   - 系统反馈：对账完成后它的 Session 出现在列表里，每行标出 Mac 名称，之后新活动实时到达（[IOS-R-007](../modules/iphone-live-view.md#ios-r-007-在线只读并按-mac-增量同步)）。
4. 点目标 Session。
   - 系统反馈：Activity 显示三泳道和时间线，Info 显示指标与 Session 信息。
   - 数据变化：只改变查看位置，不发送控制操作。

完成信号：Macs 里该 Mac 显示 Online，Sessions 里能打开它的 Session 时间线。

## 再添加一台 Mac

1. 在 iPhone Macs Tab 点 `+` > “Scan pairing code”。
2. 扫描另一台 Mac“iPhone”页生成的二维码。
3. 回到 Sessions Tab。
   - 系统反馈：两台 Mac 的 Session 合并在一条列表里；搜索栏下方的 `Macs` 下拉里多出这台 Mac。
   - 数据变化：新增一条独立通道，原通道不受影响（[IOS-R-008](../modules/iphone-live-view.md#ios-r-008-一台-iphone-可连接多台-mac)）。

只想看其中一台：在 `Macs` 下拉里取消其他 Mac，或在 Macs Tab 点那台 Mac 的行；`Status` 下拉可再按 Running / Waiting / Completed 过滤，`Reset` 回全选。

## 失败路径

### Relay unavailable

- 用户看到：Mac“iPhone”页显示 Relay unavailable，无法生成有效配对。
- 可执行动作：确认网络可用；Relay 地址由构建固定，App 内无法修改。
- 完成信号：页面恢复 Relay connected。

已有配对时 Relay 中断，Macs 里每台 Mac 分别显示 Unavailable，Sessions 继续显示缓存；恢复后各自回到 Online 并按索引补差异。

### 相机不可用

- 用户看到：扫码页提示相机不可用。
- 可执行动作：在 iOS 设置里允许相机后重新扫码；或在 Mac 点 “Copy pairing payload”，iPhone 用 `+` > “Paste pairing code”。
- 数据影响：成功前不会创建设备授权。

### 配对码过期或已使用

- 用户看到：扫码页停留并提示过期或不兼容。
- 可执行动作：回到 Mac 生成新二维码（[IOS-R-002](../modules/iphone-live-view.md#ios-r-002-配对码短时且一次性)）。

### Mac unavailable

- 用户看到：Macs 里该 Mac 显示 Unavailable 和上次同步时间，Sessions 里仍能翻看它上次同步的内容。
- 可执行动作：恢复 Mac 的 daemon 和网络；上线后自动补差异。
- 数据影响：配对关系和本机缓存保留，其他 Mac 通道继续工作（[IOS-R-006](../modules/iphone-live-view.md#ios-r-006-mac-离线时继续显示缓存)）。

### 设备被撤销

- 用户看到：连接关闭，后续连接被拒绝。
- 可执行动作：在 Mac 重新生成配对码并再次配对。
- 数据影响：只影响被撤销的 iPhone。

## 为同一台 Mac 配对第二台 iPhone

1. 在 Mac“iPhone”页生成新的二维码。
2. 在第二台 iPhone 完成扫码。
3. 返回 Mac 查看配对记录。
   - 系统反馈：出现第二条独立记录，两台 iPhone 都可以在线查看。
4. 在 Mac 对其中一条记录执行“Revoke”。
   - 系统反馈：只有目标 iPhone 断开，另一台继续工作。

## 移除一台 Mac

在 iPhone Macs Tab 左滑该 Mac > Remove。这台 iPhone 上的通道、凭据和本机缓存被删除，其他 Mac 保持连接；Mac 和 Relay 侧的授权记录仍存在。若目标是撤销访问权，还需在 Mac“iPhone”页对该设备执行“Revoke”。

Mac 上删除一个 Session 时，在线 iPhone 会移除对应条目；这不影响其他 Session 或其他 Mac。

## 持久化结果

- iPhone 为每台 Mac 保存独立凭据和一个本机缓存数据库；重启 App 立即显示上次内容（[IOS-R-010](../modules/iphone-live-view.md#ios-r-010-session-内容缓存在本机)）。
- Relay 保存授权和运行所需信息，不保存可浏览的 Session 历史。
- Mac 离线时继续显示缓存并标 Unavailable；恢复后按索引补差异。

## 下一目标

回到[Mac 会话查看](../modules/mac-session-view.md)，处理需要输入或发生错误的 Session。

## 涉及模块与数据

- [iPhone 在线查看](../modules/iphone-live-view.md)
- [业务数据流](../data-flows.md)
- [用户摩擦点](../friction-points.md)
