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

## Codex 未信任 Hook

**用户会看到**：daemon 已连接、Hook 显示已安装，但 Codex Session 完全不出现，或停在某个时间点不再更新。Codex 侧没有任何报错——它只是不运行未信任的 Hook。“Settings > Agents”的 Codex 卡片会显示还有几个处理项未被信任。

**为什么会发生**：Codex 按处理项在 `hooks.json` 中的位置记录信任。任何工具改写这个文件，位置一变，信任就失效。

**恢复步骤**：

1. 在 Settings 中栏选择“Agents”。
2. 点击 Codex 卡片上的“Authorize”。
3. 若按钮之后仍提示未信任，在 Codex 打开 `/hooks`，核对 Lumi 命令后手动信任。

**完成信号**：卡片改为显示“Trusted by Codex”，新 Session 的首个受支持事件到达后 Mac 列表自动更新。

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

**用户会看到**：Codex 侧已经有可识别标题，但 Lumi 列表仍显示 `Codex Session`，Subagent 也没有放在 Main Session 下。

**可能原因**：运行中的 daemon 还是升级前版本，尚未从 Codex `state_5.sqlite` 同步标题与 Subagent lineage。Mac App 启动时会自动检测并重启过期 daemon，因此这个状态通常只出现在自动重启还没完成、或自动重启失败的时候。

**恢复步骤**：

1. 重启 Mac App，等待几秒让它自动更新 daemon。
2. 仍未恢复时打开“Settings > Daemon”，点击“Reinstall daemon”。
3. 返回 Sessions，点击刷新图标（Refresh）与 daemon 重新同步。

**完成信号**：Main Session 显示与 Codex 一致的标题；有 parent 的 Subagent 显示为可折叠子项，并标记为 `Codex Subagent`。

## Delete Session 失败

**用户会看到**：确认删除后 Session 立即从列表消失；如果 daemon 侧删除失败，它会在随后的一次同步中回到列表，并显示连接错误。

**恢复步骤**：

1. 确认 daemon 已连接。
2. 再次选择目标 Session。
3. 点击删除图标（Delete Session），再在确认框点击“Delete”。

**完成信号**：该 Session 从 Mac 和在线 iPhone 中消失；之后只有你在同一会话里再次发出请求（或会话重启）它才会回来。Codex 自身 Session 不受影响。

## Relay unavailable

**用户会看到**：Mac“iPhone”页显示 Relay unavailable，没有配对码，不能完成配对或同步。

**恢复步骤**：

1. 确认 Mac 网络可用。
2. 稍后重新打开“iPhone”页。
3. 如果持续失败，检查当前产品构建对应的 Relay 服务状态。

**完成信号**：页面显示 Relay connected 并出现配对码。Mac 侧 Relay 地址由编译配置固定，App 内没有可编辑地址；iPhone 侧的地址只在添加 Mac 时填（Advanced），之后跟着那台 Mac 走。

已有多个 Mac 通道时，每台受影响的 Mac 都会显示 Offline；恢复后逐个确认回到 Online。

## 配对失败

**用户会看到**：iPhone 停在 Add Mac 流程里，提示四种之一：

| 提示 | 意思 | 下一步 |
| --- | --- | --- |
| 配对码不对或已过期（六格变红） | 输错，或 Mac 上的码已换新 / 被用过 | 回 Mac 看一眼当前的码，改好后 Try again |
| Mac 不在线 | 码是对的，但这台 Mac 没连上 Relay | 确认 Mac 上 Lumi 在运行、显示 Relay connected，Try again（接着这一次继续） |
| Mac 拒绝了这次配对 | Mac 点了 Don't match，或 60 秒没点 | 如果只是没来得及点，Start over 重来；数字确实不一样就别配 |
| 校验失败（红色） | Relay 返回的数据不一致——可能有人在中间换钥匙 | 换个网络 Try again；仍失败停止配对，检查这台 Mac 用的 Relay |

Mac 上的码在中途换掉或过期，也按 ① 处理——回到输码屏重输。任何一种失败都没有保存凭据（[IOS-R-014](modules/iphone-live-view.md#ios-r-014-配对时两端比对数字mac-点-match-才生效)）。

**恢复步骤**：

1. 在 Mac“iPhone”页确认 Relay connected，看当前的 6 位码（到点自动换新，也可点 New code）。
2. 在 iPhone Macs Tab 点 `+` > “Add Device”，输入这 6 位或扫二维码；自托管 Relay 时展开 Advanced 核对 Relay URL。
3. 两边出现同一组 6 位数字后，在 Mac 上点 Match。

**完成信号**：iPhone Macs 列表出现该 Mac 并显示 `Online · <Relay 地址>`；Mac 的 Paired iPhones 里这台 iPhone 显示 Active。

**例外**：两边数字不一样、或换了网络仍提示校验失败，说明 Mac 与 iPhone 之间的中转服务不可信，停止配对，检查这台 Mac 用的 Relay 部署。

## iPhone 在 Mac 上显示 Unverified

**用户会看到**：Mac“iPhone”页 Paired iPhones 里这台 iPhone 的状态是 Unverified，下方提示 `Key not verified · pair this iPhone again`；这台 iPhone 的 Macs 页该 Mac 仍显示 Online，但 Session 不再更新。这台 iPhone 的身份不是这台 Mac 点 Match 批准过的：此版本之前配对的 iPhone 升级后都会这样，中转服务换过钥匙也会这样。

**恢复步骤**：

1. 在 Mac“iPhone”页看当前的 6 位码。
2. 在这台 iPhone 的 Macs Tab 点 `+` > “Add Device” 重新配对，两边对数字，在 Mac 上点 Match（沿用原设备身份，不会多出第二条记录）。

**完成信号**：Mac 上该记录变为 Active，iPhone 上该 Mac 开始同步。

## Mac unavailable

**用户会看到**：iPhone Macs 里某台 Mac 显示 `Offline · <多久前> · <Relay 地址>`；Sessions 里仍能翻看它上次同步的内容（本机没有缓存时才显示 Mac unavailable）。

**可能原因**：daemon 不可用、Mac 网络断开或实时通道尚未恢复。退出 Mac App 不会导致这个状态——Relay 连接由 daemon 持有。

**恢复步骤**：

1. 确认目标 Mac 开机联网；daemon 由 launchd 常驻，必要时在 Mac 打开 Lumi 让它自检重装。
2. 等待 iPhone 自动重新对账（上线后几秒内）。

**完成信号**：该 Mac 显示 Online，差异补齐后列表回到最新。其他 Mac 通道不受影响。

## 设备被撤销

**用户会看到**：目标 iPhone 的 Macs 页这台 Mac 显示 `Revoked · <Relay 地址>`，Sessions 没有内容时提示 Access revoked；缓存仍可翻看；其他设备正常。

**恢复步骤**：

1. 在 Mac“iPhone”页看当前的 6 位码。
2. 在目标 iPhone 点 `+` > “Add Device” 重新配对，两边对数字，在 Mac 上点 Match。

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

## Check for Updates… 显示错误

受影响目标：确认或安装最新的 Lumi for Mac。

**用户会看到**：从 App 菜单或“Settings > About”检查时出现无法读取、验证或安装更新的提示；“Settings > About”仍显示当前版本。

**可能原因**：Mac 无法访问 Stable 更新信息或下载地址，更新尚未完整发布，或下载内容没有通过来源验证。

规则引用：[UPD-R-004](modules/software-updates.md#upd-r-004-只接受签名的-stable-更新)、[UPD-R-005](modules/software-updates.md#upd-r-005-不静默下载或安装)。

**恢复步骤**：

1. 保留当前 Lumi，不从其他不明来源替换 App。
2. 确认 Mac 网络可用。
3. 稍后从任一“Check for Updates…”入口重试。

**完成信号**：检查显示当前已是最新版，或出现可确认的新版本；失败和取消期间 Session 历史不受影响。

相关文档：[软件更新](modules/software-updates.md) / [让 Lumi 保持最新](journeys/keep-lumi-up-to-date.md)

## 更新安装要求授权

受影响目标：把已验证的新版本安装到当前 App 位置。

**触发条件**：用户确认安装，但当前 App 位置需要 macOS 提升权限才能替换。

**用户会看到**：macOS 在安装前要求确认或输入管理员凭据。

规则引用：[UPD-R-005](modules/software-updates.md#upd-r-005-不静默下载或安装)、[UPD-R-006](modules/software-updates.md#upd-r-006-app-更新后刷新本机组件)。

**恢复步骤**：

1. 确认提示针对 Lumi 更新。
2. 要继续安装就完成 macOS 授权；不确定时取消。
3. 取消后需要更新时，再从“Check for Updates…”重新开始。

**完成信号**：Lumi 重新打开，“Settings > About”显示新版本；取消时当前版本与 Session 历史保持不变。

相关文档：[软件更新](modules/software-updates.md) / [让 Lumi 保持最新](journeys/keep-lumi-up-to-date.md)

## 仍无法恢复：先看日志

三个本机进程各写一份日志，错误另外汇总成一份：

| 文件 | 谁写的 | 先看什么 |
| --- | --- | --- |
| `errors.log` | daemon、helper、Mac App 的全部 ERROR | 出问题先打开它 |
| `daemon.log` | 后台 daemon | 启动 / 监听、每批事件入库、Relay 连接与配对、给 iPhone 推了什么 |
| `helper.log` | 每次 Codex / Claude Hook 触发的 helper | 每次 Hook 一行：会话、Hook 名、读了多少行、发了几个事件；读不到对话记录是 WARN |
| `app.log` | Mac App | 与 daemon 的连接、每次同步的数量、daemon 自动更新、配对页操作 |

位置：`~/Library/Logs/Lumi/`。打开方式：“Settings > Daemon”最下方的 Logs 卡片点“Show in Finder”；或在 Console.app 按子系统 `app.huanan.lumi` 筛选（记得勾上 Action › Include Info Messages）。

每行的样子：`[时间] [级别:进程] [模块] ['trace':请求id] 事件 key=value …`。同一次操作的所有行共用一个 trace id——helper 一次 hook、Mac 一次同步、daemon 处理的对应请求都是同一个，按它 grep 就能把一件事从头看到尾。模块名：`lifecycle`（启动 / 更新）、`agent`（Agent 事件流入）、`convert`（对话记录解析）、`db`、`ipc`（本机连接）、`relay`、`pairing`、`ui`。

日志只记标识、数量、字节数和耗时，不记 Session 正文、工具参数、配对码或任何凭据，可以直接附到问题里。

需要更细的内容（每一帧、每条事件）时，临时把级别调到 debug：daemon 用环境变量 `LUMI_LOG_LEVEL=debug`，Mac App 用启动参数 `-LumiLogLevel debug`，helper 在 Hook 命令后加 `--verbose`。单文件超过 5 MB 自动轮转，最多保留 3 份旧的。

仍然说不清时，再补上：

- Mac Settings 中 daemon 状态；
- Mac“iPhone”页 Relay 状态；
- 发生问题的是哪台 Mac 通道；
- 问题发生在启动、手动 Refresh 还是 Agent 事件之后。
