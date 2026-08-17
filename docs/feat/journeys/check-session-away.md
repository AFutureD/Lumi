# 在 iPhone 上查看多台 Mac

> 验证状态：开发预览。内置 Relay 已部署；iOS 模拟器已完成 Mac 在线、Session 到达、时间线打开和跨端删除验证。iPhone 实机扫码与弱网恢复仍待验收。

最短路径：Mac 打开“iPhone” > 生成二维码 > iPhone 扫码 > 选择 Mac 下的 Session。

## 用户目标

- 离开 Mac 屏幕后继续查看 Codex 进度。
- 在一台 iPhone 中区分多台 Mac 的 Session。
- 只查看状态，不从手机审批、终止或操作 Agent。

## 前置条件

- Mac App、daemon 和网络可用。
- iPhone 与 Mac 使用同一产品构建所配置的 Relay。
- 只把配对码交给受信任设备。

## 第一台 Mac

1. 在 Mac 侧边栏选择“iPhone”。
   - 系统反馈：显示 Relay connected、二维码和配对记录。
2. 在 iPhone 点“Pair”，扫描二维码或使用“Paste”。
   - 系统反馈：配对成功后，列表出现该 Mac 分组。
   - 数据变化：为这台 iPhone 建立独立授权。
   - 规则引用：[IOS-R-001](../modules/iphone-live-view.md#ios-r-001-每台设备独立授权)。
3. 保持 Mac 在线，打开 iPhone App。
   - 系统反馈：Mac 分组显示 Online；收到当前快照后显示 Session。
   - 数据变化：该 Mac 的同步内容保存到独立本地副本。
   - 规则引用：[IOS-R-007](../modules/iphone-live-view.md#ios-r-007-在线只读并按-mac-同步)。
4. 选择目标 Session。
   - 系统反馈：显示消息、工具、计划、子 Agent 或错误。
   - 数据变化：只改变查看位置，不发送控制操作。

完成信号：每台 Mac 形成独立分组，状态可区分，并能打开目标 Session 时间线。

## 再添加一台 Mac

1. 在 iPhone 点“Device”。
2. 选择“Add another Mac”。
3. 扫描另一台 Mac“iPhone”页生成的二维码。
4. 返回列表。
   - 系统反馈：两台 Mac 分别显示自己的 Online 或 Unavailable 状态。
   - 数据变化：新增一条独立通道，原通道不受影响。
   - 规则引用：[IOS-R-008](../modules/iphone-live-view.md#ios-r-008-一台-iphone-可连接多台-mac)。

## 失败路径

### Relay unavailable

- 用户看到：Mac“iPhone”页显示 Relay unavailable，无法生成有效配对。
- 可执行动作：确认网络可用；Relay 地址由构建固定，App 内无需也无法手动修改。
- 完成信号：页面恢复 Relay connected。

已有配对时 Relay 中断，各 Mac 通道会分别进入 Unavailable；恢复后以每个分组重新显示 Online 并取得当前快照为完成信号。

### 摄像头不可用或粘贴无效

- 用户看到：提示使用 Paste，或显示配对内容无效。
- 可执行动作：从 Mac 复制新的配对内容，再在 iPhone 点“Paste”。
- 数据影响：成功前不会创建设备授权。

### 配对码过期或已使用

- 用户看到：配对失败并停留在配对页。
- 可执行动作：回到 Mac 生成新二维码。
- 规则引用：[IOS-R-002](../modules/iphone-live-view.md#ios-r-002-配对码短时且一次性)。

### Mac unavailable

- 用户看到：该 Mac 分组显示 Unavailable，不显示旧 Session。
- 可执行动作：恢复 Mac App、daemon 和网络；等待当前快照重新到达。
- 数据影响：配对关系保留，其他 Mac 通道继续工作。
- 规则引用：[IOS-R-006](../modules/iphone-live-view.md#ios-r-006-mac-离线时不显示旧-session)。

### 设备被撤销

- 用户看到：连接关闭，后续连接被拒绝。
- 可执行动作：在 Mac 重新生成配对码并再次配对。
- 数据影响：只影响被撤销的 iPhone。

## 为同一台 Mac 配对第二台 iPhone

1. 在 Mac“iPhone”页生成新的二维码。
2. 在第二台 iPhone 完成 Pair。
3. 返回 Mac 查看配对记录。
   - 系统反馈：出现第二条独立记录，两台 iPhone 都可以在线查看。
4. 在 Mac 对其中一条记录执行“Revoke”。
   - 系统反馈：只有目标 iPhone 断开，另一台继续工作。

## 移除一台 Mac

在 iPhone 点“Device”，选择“Remove <Mac 名称>”。该 iPhone 上的通道、凭据和同步内容被删除，其他 Mac 保持连接；Mac 和 Relay 侧的授权记录仍存在。若目标是撤销访问权，还需在 Mac“iPhone”页对该设备执行“Revoke”。

Mac 上删除一个 Session 时，在线 iPhone 会移除对应条目；这不影响其他 Session 或其他 Mac 分组。

## 二维码生成失败

- 用户看到：Mac 显示 Unable to generate a pairing code。
- 可执行动作：确认 Relay connected，再点击“Generate new code”。
- 完成信号：出现新的二维码和有效期。

## 持久化结果

- iPhone 为每台 Mac 保存独立凭据和同步内容。
- Relay 保存授权和运行所需信息，不保存可浏览的 Session 历史。
- Mac 离线时不展示旧内容；恢复后由当前快照重新确认。

## 下一目标

回到[Mac 会话查看](../modules/mac-session-view.md)，处理需要输入或发生错误的 Session。

## 涉及模块与数据

- [iPhone 在线查看](../modules/iphone-live-view.md)
- [业务数据流](../data-flows.md)
- [用户摩擦点](../friction-points.md)
