# iPhone 在线查看

> 验证状态：开发预览。iOS App 已在模拟器完成编译、启动、实时 Session 列表、时间线、离线隐藏和跨端删除验证；iPhone 实机扫码、App 重启恢复与弱网场景仍待验收。

iPhone 通过产品内置 Relay 与一台或多台 Mac 建立独立通道。每条通道承载对应 Mac 的全部 Session，界面只读。

## 模块概览

- **Mac 入口**：侧边栏“iPhone”。
- **iPhone 入口**：首次打开时点“Pair”；已有通道时点“Device”后选择“Add another Mac”。
- **前置条件**：Mac App、daemon 和内置 Relay 可用；一次性配对码仍有效。
- **主要结果**：iPhone 按 Mac 分组显示连接状态、Session 列表和时间线。
- **隐私提示**：已配对设备可以看到 Session 标题、工作目录、消息、工具、计划、子 Agent 和错误，只应配对受信任设备。
- **相关旅程**：[在 iPhone 上查看多台 Mac](../journeys/check-session-away.md)。

## 配对并查看

1. 在 Mac 侧边栏选择“iPhone”。
   - 系统反馈：页面显示 Relay 状态、二维码和已配对记录。
2. 生成或刷新一次性二维码。
   - 系统反馈：二维码和可复制的配对内容在 5 分钟内有效。
   - 规则引用：[IOS-R-002](#ios-r-002-配对码短时且一次性)。
3. 在 iPhone 点“Pair”，扫码或使用“Paste”。
   - 系统反馈：成功后显示 Mac 名称和 Online 状态。
   - 数据结果：这台 iPhone 获得独立授权。
   - 规则引用：[IOS-R-001](#ios-r-001-每台设备独立授权)。
4. 选择一个 Session。
   - 系统反馈：显示用户/Assistant 消息、工具、计划、子 Agent 和错误；列表状态标记与 Mac 和 Notch 使用相同颜色语义。
   - 数据结果：只改变查看对象，不向 Agent 发送命令。
   - 规则引用：[IOS-R-007](#ios-r-007-在线只读并按-mac-同步)、[IOS-R-009](#ios-r-009-session-状态颜色与-mac-一致)。

完成信号：对应 Mac 显示 Online，并能打开 Session 时间线。

## 多设备关系

- 一台 iPhone 可以重复选择“Add another Mac”，为多台 Mac 分别建立通道。
- 每台 Mac 在列表中形成独立分组，拥有自己的连接状态和 Session。
- 一台 Mac 可以同时授权多台 iPhone；Mac 的已配对记录可单独撤销任意设备。
- 一条 Mac—iPhone 通道承载该 Mac 的全部 Session，不会为每个 Session 新建连接。

## 撤销与移除

### Mac 撤销某台 iPhone

在 Mac“iPhone”页对目标记录执行“Revoke”。该设备连接关闭，其他 iPhone 保持授权。

### iPhone 移除某台 Mac

点击“Device”，选择“Remove <Mac 名称>”。只删除该 Mac 的通道、凭据和本地同步内容，不影响其他 Mac。

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
- 限制或例外：需要回到 Mac 重新生成。

### IOS-R-003 已移除：只保存在当前内存

- 状态：removed。
- 移除日期：2026-08-17。
- 原因：只保存在当前内存不再符合产品行为。
- 替代规则：[IOS-R-006](#ios-r-006-mac-离线时不显示旧-session)、[IOS-R-007](#ios-r-007-在线只读并按-mac-同步)。

### IOS-R-004 撤销按设备生效

- 条件：用户在 Mac 上撤销某台 iPhone。
- 行为：该设备授权失效，现有连接关闭。
- 结果：目标 iPhone 无法继续接收数据，其他设备不受影响。
- 限制或例外：恢复访问需要重新配对。

### IOS-R-005 Relay 不持久化 Session 历史

- 条件：Mac 发送在线更新。
- 行为：内容在 Mac 按目标设备加密，Relay 只转发密文，并可在短暂断线窗口内重放尚未过期的数据。
- 结果：Relay 不提供 Session 正文、工具详情或历史查询。
- 限制或例外：Relay 可以保存设备授权、限流和过期时间等运行所需信息。

### IOS-R-006 Mac 离线时不显示旧 Session

- 条件：iPhone 未取得该 Mac 的在线状态和当前快照。
- 行为：该 Mac 显示 Unavailable，不展示上次同步的 Session。
- 结果：旧数据不会被误认为当前 Agent 状态。
- 限制或例外：配对凭据和本地同步副本保留；恢复后等待 Mac 发送当前快照。

### IOS-R-007 在线只读并按 Mac 同步

- 条件：对应 Mac 在线并发送当前快照。
- 行为：iPhone 更新该 Mac 的独立本地副本并展示 Session。
- 结果：daemon、Mac 和该 iPhone 的可见数据一致。
- 限制或例外：iPhone 不提供审批、终止、输入或其他远程控制。

### IOS-R-008 一台 iPhone 可连接多台 Mac

- 条件：用户分别完成多台 Mac 的配对。
- 行为：iPhone 为每台 Mac 维护独立通道、状态和同步内容。
- 结果：不同 Mac 的 Session 不会混合。
- 限制或例外：移除一条通道不影响其他通道。

### IOS-R-009 Session 状态颜色与 Mac 一致

- 条件：iPhone 在线显示来自任意已配对 Mac 的 Session。
- 行为：状态标记遵循 [MAC-R-013 Session 状态颜色跨端一致](./mac-session-view.md#mac-r-013-session-状态颜色跨端一致)。
- 结果：切换 Mac 通道或查看同一 Session 的不同客户端时，颜色含义不变。
- 限制或例外：iPhone 的状态文字使用系统标签色，颜色由列表左侧状态标记表达。

## 空状态与故障

- **No live sessions**：Mac 在线，但当前同步结果为空。
- **Mac unavailable**：通道断开、Mac App 退出或 daemon 不可用；不展示旧 Session。
- **摄像头不可用**：从 Mac 复制配对内容，在 iPhone 配对页点“Paste”。
- **配对码过期**：回到 Mac 生成新二维码。

更多恢复步骤见[用户摩擦点](../friction-points.md)。

## 业务数据

iPhone 为每台 Mac 保留独立同步副本，用于高效更新和恢复连接；只有在收到在线状态和当前快照后才展示。用户移除该 Mac 通道时，对应同步内容一并删除。

Relay 不保存可浏览的 Session 业务历史。完整生命周期见[数据流](../data-flows.md)。

## 相关文档

- [功能全景](../index.md)
- [远程查看旅程](../journeys/check-session-away.md)
- [数据流](../data-flows.md)
- [摩擦点](../friction-points.md)
