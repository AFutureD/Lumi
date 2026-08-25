# 让 Lumi 保持最新

> 验证状态：开发预览。入口与设置已在本机 App 中完成点击核对；第二次启动许可提示和真实跨版本安装仍需在正式发布后验收。

最短路径：Lumi App 菜单 > Check for Updates… > 确认更新 > Lumi 重新打开。

## 用户目标

- **触发场景**：用户想确认当前 Lumi 是否已经包含最新修复和能力。
- **想改变的状态**：旧版本仍在运行，随附的 helper 和 daemon 也可能落后。
- **预期结果**：安装经过验证的 Stable 版本，并继续查看原有 Session 历史。

## 前置条件

- Lumi for Mac 已安装并可以启动。
- 首个签名 Release 和正式更新信息已经发布，且 Mac 可以访问公开下载地址。
- 安装目录需要权限时，用户可以完成 macOS 授权。

## 实际入口

- **主入口**：Lumi App 菜单 >“Check for Updates…”。
- **替代入口**：侧边栏“Settings”> 中栏“About”>“Check for Updates…”。
- **到达状态**：Lumi 开始检查；尚未下载或替换 App。
- **规则引用**：[UPD-R-001](../modules/software-updates.md#upd-r-001-两个入口使用同一个更新状态)。

## 主路径

1. 点击“Check for Updates…”。
   - 系统反馈：出现 Lumi 更新窗口。
   - 数据变化：只读取更新信息，不改变本地 Session。
   - 规则引用：[UPD-R-001](../modules/software-updates.md#upd-r-001-两个入口使用同一个更新状态)。
2. 发现新版本后确认继续。
   - 系统反馈：Lumi 下载并验证 Stable 更新；验证不通过时停止。
   - 数据变化：当前 App 在验证和确认完成前保持不变。
   - 规则引用：[UPD-R-004](../modules/software-updates.md#upd-r-004-只接受签名的-stable-更新)、[UPD-R-005](../modules/software-updates.md#upd-r-005-不静默下载或安装)。
3. 确认安装并允许 Lumi 重新打开。
   - 系统反馈：App 完成替换后启动；需要时 macOS 先显示授权提示。
   - 数据变化：原有 Session 历史保留；已安装的 helper 跟随刷新，正在运行且已连接的已安装 daemon 在版本不一致时重启刷新。
   - 规则引用：[UPD-R-006](../modules/software-updates.md#upd-r-006-app-更新后刷新本机组件)。

## 分支和失败路径

### 当前已是最新版

- 用户看到：检查结果表明没有更高版本。
- 可执行动作：关闭结果并继续使用 Lumi。
- 持久化影响：App、设置和 Session 历史均不变化。
- 规则引用：[UPD-R-001](../modules/software-updates.md#upd-r-001-两个入口使用同一个更新状态)。
- 结束状态：当前 App 继续运行，本次检查完成。

### 无法读取或验证更新

- 用户看到：更新检查或安装错误。
- 可执行动作：保留当前版本，检查网络后重新使用任一手动入口。
- 持久化影响：当前 App 和 Session 历史保持不变。
- 规则引用：[UPD-R-004](../modules/software-updates.md#upd-r-004-只接受签名的-stable-更新)。

### 取消安装或授权

- 用户看到：更新流程结束，当前 Lumi 继续运行或下次重新打开仍是原版本。
- 可执行动作：之后再次点击“Check for Updates…”。
- 持久化影响：不会删除 Session 历史，也不会安装部分版本。
- 规则引用：[UPD-R-005](../modules/software-updates.md#upd-r-005-不静默下载或安装)。
- 结束状态：当前 App 保持原版本，本次更新流程结束。

## 持久化结果

- **成功后**：新 App 版本保留；已安装的 helper 跟随刷新，符合运行和连接条件的已安装 daemon 跟随刷新；Session 历史继续可见。
- **取消或失败后**：当前 App、自动检查选择和 Session 历史保持原状。
- **数据流**：[软件更新](../data-flows.md#软件更新)。

## 用户可见的完成状态

- **完成信号**：“Settings > About”显示新的版本和 build，再次检查时显示当前已是最新版。
- **尚未完成的区别**：只完成下载或只看到授权提示都不代表 App 已替换；以重新打开后的版本为准。

## 下一目标

[在 Mac 上跟进一次 Codex Session](observe-session-locally.md)。

## 涉及模块与数据

- [软件更新](../modules/software-updates.md)
- [软件更新数据流](../data-flows.md#软件更新)
- [用户摩擦点](../friction-points.md#check-for-updates-显示错误)
