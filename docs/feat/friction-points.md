# 用户摩擦点与恢复路径

按界面上看到的症状选择恢复步骤。

## daemon unavailable

**用户会看到**：Settings 中 daemon 显示 Not connected；Session 工具栏显示 Daemon unavailable。

**可能原因**：daemon 尚未安装、等待系统允许、已停止或启动失败。

**恢复步骤**：

1. 打开侧边栏“Settings”，在中栏选择“Daemon”。
2. 点击“Install & Start daemon”。
3. 如系统要求允许后台项目，完成授权后返回 App。
4. 回到“Sessions”，点击刷新图标（Refresh）。

**完成信号**：Settings 显示 daemon 已连接。断线期间 Mac 上已同步的 Session 不会自动删除。

## Hook 尚未信任

**用户会看到**：daemon 已连接，但新 Agent 活动不能及时出现在列表；Codex 将 Hook 标为待审核。

**恢复步骤**：

1. 在 Settings 中栏选择“Agents”，点击“Install Hook”。
2. 在 Codex 打开 /hooks。
3. 核对 Agent Status 命令后完成信任。
4. 新建一个 Codex Session 进行验证。

**完成信号**：新 Session 的首个受支持事件到达后，Mac 列表自动更新。

## No Sessions

**用户会看到**：中栏显示 No Sessions，右栏显示 Select a Session。

**可能原因**：启用后尚未新建 Session，或用户已删除全部记录。daemon 不会导入首次启用前的旧 Session。

**恢复步骤**：

1. 确认 daemon 已连接。
2. 新建一个 Codex Session。
3. 提交一次任务；必要时点击刷新图标（Refresh）。

**完成信号**：新 Session 出现在中栏。

## Refresh 后没有变化

**用户会看到**：点击刷新图标后数据没有变化；当前版本没有单独的刷新完成提示。选中某个 Session 时刷新会先让 daemon 用它的本机对话记录重算这个 Session；对话记录不存在或不可读时该步跳过，只做同步。重算不会重置已查看和 Notch 归档标记。

**恢复步骤**：

1. 回到“Settings > Daemon”检查 daemon 状态。
2. 重新执行“Install & Start daemon”。
3. 返回 Sessions 再点击刷新图标（Refresh）。

**完成信号**：连接错误消失，列表与 daemon 当前数据一致。

## Session 标题仍显示 Codex Session

**用户会看到**：Codex 侧已经有可识别标题，但 Agent Status 列表仍显示 `Codex Session`，Subagent 也没有放在 Main Session 下。

**可能原因**：运行中的 daemon 还是升级前版本，尚未从 Codex `state_5.sqlite` 同步标题与 Subagent lineage；只重启 Mac App 不会替换已经注册的 daemon 进程。

**恢复步骤**：

1. 打开“Settings > Daemon”。
2. 点击“Stop & Uninstall daemon”。
3. 点击“Install & Start daemon”。
4. 返回 Sessions，点击刷新图标（Refresh）与 daemon 重新同步。

**完成信号**：Main Session 显示与 Codex 一致的标题；有 parent 的 Subagent 显示为可折叠子项，并标记为 `Codex Subagent`。

## Delete Session 失败

**用户会看到**：确认删除后 Session 立即从列表消失；如果 daemon 侧删除失败，它会在随后的一次同步中回到列表，并显示连接错误。

**恢复步骤**：

1. 确认 daemon 已连接。
2. 再次选择目标 Session。
3. 点击删除图标（Delete Session），再在确认框点击“Delete”。

**完成信号**：该 Session 从 Mac 和在线 iPhone 中消失且不再回来。Codex 自身 Session 不受影响。

## Relay unavailable

**用户会看到**：Mac“iPhone”页显示 Relay unavailable，不能完成配对或同步。

**恢复步骤**：

1. 确认 Mac 网络可用。
2. 稍后重新打开“iPhone”页。
3. 如果持续失败，检查当前产品构建对应的 Relay 服务状态。

**完成信号**：页面显示 Relay connected。Relay 地址由编译配置固定，App 内没有可编辑地址。

已有多个 Mac 通道时，每个受影响的分组都会显示 Unavailable；恢复后逐个确认分组回到 Online。

## 配对失败

**用户会看到**：iPhone 停留在配对页，并提示内容无效、过期或不兼容。

**恢复步骤**：

1. 回到 Mac“iPhone”页生成新二维码。
2. 在 5 分钟内重新扫描。
3. 摄像头不可用时，从 Mac 复制配对内容并在 iPhone 点“Paste”。

**完成信号**：iPhone 列表出现该 Mac 分组。

## Mac unavailable

**用户会看到**：iPhone 中某台 Mac 显示 Unavailable，并且不显示旧 Session。

**可能原因**：Mac App 退出、daemon 不可用、网络断开或实时通道尚未恢复。

**恢复步骤**：

1. 在目标 Mac 启动 Agent Status。
2. 确认 daemon 与 Relay 均已连接。
3. 保持 App 在线，等待同步完成。

**完成信号**：该 Mac 显示 Online，并重新出现当前 Session。其他 Mac 通道不受影响。

## 设备被撤销

**用户会看到**：目标 iPhone 无法重新连接，但其他设备正常。

**恢复步骤**：

1. 在 Mac“iPhone”页生成新二维码。
2. 在目标 iPhone 重新配对。

**完成信号**：Mac 配对记录出现新的有效设备，iPhone 恢复 Online。

## 多台 Mac 同名

**用户会看到**：iPhone 的多个分组显示相同 Mac 名称，当前版本没有额外的可见设备标识。

**可执行动作**：在 macOS 系统设置中为设备使用不同名称，再重新配对；移除通道前先确认对应 Mac 的在线状态。

**完成信号**：各分组名称可以区分。

## Notch 未出现在选定屏幕

**用户会看到**：曾经指定的屏幕断开后，Notch 出现在内建屏幕或当前主屏幕。

**恢复步骤**：

1. 重新连接原屏幕；已保存的指定屏幕会自动恢复。
2. 如需立即改用其他屏幕，打开“Settings > Notch”。
3. 在 Screen 中选择 Built-in Display、Main Display 或当前已连接的指定屏幕。

**完成信号**：Notch 出现在所选屏幕；之后的紧凑、展开和活动提示都使用同一屏幕。

## 仍无法恢复

保留界面上的错误文字，并记录以下信息：

- Mac Settings 中 daemon 状态；
- Mac“iPhone”页 Relay 状态；
- 发生问题的是哪台 Mac 通道；
- 问题发生在启动、手动 Refresh 还是 Agent 事件之后。

不要复制 Session 正文、工具参数、配对内容或设备凭据到公开问题中。
