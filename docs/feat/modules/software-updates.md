# 软件更新

> 验证状态：开发预览。v0.1.0–v0.1.3 已正式发布，签名的 Stable 更新信息（appcast）已上线并包含跨版本升级路径；两个检查入口、自动检查开关和发布流水线的签名验证均已核对。第二次启动的许可提示与真实跨版本替换的端到端体验仍待验收。

Lumi for Mac 可以主动或定期检查正式版本。检查和安装使用同一个 Lumi 更新窗口，Lumi 不会静默下载或安装。

## 模块概览

- **实际入口**：Lumi App 菜单 > “Check for Updates…”；或侧边栏“Settings”> 中栏“About”>“Check for Updates…”。
- **设置入口**：侧边栏“Settings”> 中栏“General”>“Automatically check for updates”，开关下方注明下载或安装前 Lumi 都会先询问。
- **可触达条件**：Apple silicon Mac，macOS 26 或更高版本，且能访问公开下载地址；更新信息只提供满足硬件与系统门槛的版本。
- **主要结果**：当前版本已是最新时得到明确结果；存在更高 build 时，可以查看提示并决定是否安装。
- **相关旅程**：[让 Lumi 保持最新](../journeys/keep-lumi-up-to-date.md)。

## 主流程

1. 从 App 菜单或“Settings > About”点击“Check for Updates…”。
   - 系统反馈：Lumi 打开更新窗口并读取正式更新信息。
   - 数据结果：不会改变 Session 历史或 Agent 状态。
   - 规则引用：[UPD-R-001](#upd-r-001-两个入口使用同一个更新状态)。
2. 有新版本时，确认继续，由 Lumi 下载并验证更新包。
   - 系统反馈：Lumi 展示可用版本；下载或安装前仍需用户确认。
   - 数据结果：更新包（DMG）只有通过来源和完整性验证后才可进入安装。
   - 规则引用：[UPD-R-004](#upd-r-004-只接受签名的-stable-更新)、[UPD-R-005](#upd-r-005-不静默下载或安装)。
3. 确认安装并等待 Lumi 重新打开。
   - 系统反馈：App 退出、由 Lumi 的更新程序完成替换后重新启动；系统可能先要求安装授权。
   - 数据结果：Lumi 保存的 Session 历史不因 App 替换而清空；启动后已安装的 helper 与 daemon 自动刷新到新版本。
   - 规则引用：[UPD-R-006](#upd-r-006-app-更新后刷新本机组件)。

完成信号：“Settings > About”显示新版本和 build；再次检查时显示当前已是最新版本。

## 自动检查

第二次启动时，Lumi 先询问是否允许自动检查（[UPD-R-002](#upd-r-002-第二次启动先询问自动检查)）。选择结果保存在这台 Mac 上，并反映到“Settings > General”的开关；之后也可以从这里更改（[UPD-R-003](#upd-r-003-自动检查设置可随时更改)）。关闭自动检查不影响两个手动入口。

自动检查只负责发现新版本。即使开关已打开，Lumi 仍不会静默下载或安装。

“Settings > About”的 Updates 行随时显示当前通道与自动检查状态（`Stable · Automatic checks on` / `Stable · Automatic checks off`）。

## 规则

### UPD-R-001 两个入口使用同一个更新状态

- 条件：用户从 App 菜单或“Settings > About”主动检查。
- 行为：两个入口共享当前更新状态；一次只能进行一个检查。
- 结果：正在检查时入口会按当前状态禁用，不会启动重复检查。
- 限制或例外：更新入口只存在于 Lumi for Mac。

### UPD-R-002 第二次启动先询问自动检查

- 条件：用户尚未选择是否允许自动检查，并第二次启动 Lumi。
- 行为：Lumi 显示更新检查许可提示，不在首次启动直接开启。
- 结果：选择写入这台 Mac；“Settings > General”的开关显示相同状态。
- 限制或例外：用户在提示出现前手动改变开关时，以该选择为准。

### UPD-R-003 自动检查设置可随时更改

- 条件：用户打开“Settings > General”。
- 行为：切换“Automatically check for updates”会直接改变定期检查状态。
- 结果：设置跨 App 重启保留；手动检查不受自动检查开关影响。
- 限制或例外：关闭开关不会撤销已经由用户开始的检查；已有检查进行时，手动入口暂不可用。

### UPD-R-004 只接受签名的 Stable 更新

- 条件：Lumi 从公开正式更新信息中发现一个更高 build。
- 行为：验证更新信息本身的签名，并在解压安装前验证更新包的来源与完整性，再允许安装。
- 结果：任一必需验证失败时保留当前 App，不用未验证的内容替换它。
- 限制或例外：当前没有 Beta 或其他更新通道；更新信息只面向 Apple silicon 与 macOS 26 及以上。

### UPD-R-005 不静默下载或安装

- 条件：自动或手动检查发现新版本。
- 行为：向用户显示更新提示；下载和安装不会在后台无确认完成。
- 结果：用户可以先继续使用当前版本，再自行决定是否更新。
- 限制或例外：安装位置需要更高权限时，macOS 会显示授权提示。

### UPD-R-006 App 更新后刷新本机组件

- 条件：新版本完成安装并重新启动，且 Hook 或 daemon 曾经安装过。
- 行为：Lumi 启动时检查已安装的 helper 和已启用的 daemon，把不一致的组件刷新为当前 App 随附的版本；已注册但起不来的 daemon 也会被自动重装一次。
- 结果：Hook 和后台采集使用新 App 随附的组件，Session 历史继续保留。
- 限制或例外：从未安装过的 Hook 或 daemon 不会因为 App 更新而自动安装。完整触发条件与重试上限见 [MAC-R-020](mac-session-view.md#mac-r-020-启动时自动更新已安装的-hook-helper) 和 [MAC-R-022](mac-session-view.md#mac-r-022-启动时自动更新已安装的-daemon)。

## 摩擦点与恢复

- 无法读取更新信息或安装失败时，当前 App 保持不变；恢复步骤见[用户摩擦点](../friction-points.md#check-for-updates-显示错误)。
- 系统要求授权时，确认安装来源是 Lumi 后完成 macOS 授权；取消不会删除当前版本或 Session 历史。详见[更新安装要求授权](../friction-points.md#更新安装要求授权)。

## 业务数据

- **自动检查选择**：保存在这台 Mac 上，供启动调度、General 开关和 About 的 Updates 行读取。
- **更新信息**：来自公开正式更新通道，只用于比较版本、展示更新和定位已验证的安装包。
- **更新包**：验证并安装成功后替换 App；不属于 Lumi 的 Session 历史。
- **完整生命周期**：[软件更新数据流](../data-flows.md#软件更新)。

## 相关文档

- [功能全景](../index.md)
- [让 Lumi 保持最新](../journeys/keep-lumi-up-to-date.md)
- [数据流](../data-flows.md#软件更新)
- [摩擦点](../friction-points.md#check-for-updates-显示错误)
