# iPhone 用量

> 验证状态：开发预览。按 2026-09-08 的设计交接（`design_handoff_ios_usage`）实现；数据链（Relay 请求与应答、iPhone 侧合并）有单元测试，页面在模拟器用预览数据走查，真机与多 Mac 跨时区待验收。

iPhone 的 Usage Tab 把每台 Mac 的两组数字带到手机上：**Plan** 是订阅额度用了百分之几，**History** 是花了多少 token 与钱。只看不改：开关、Percent 在 Mac 上设，明细表也留在 Mac。

## 模块概览

- **入口**：底部第二个 Tab `Usage`，页内 Segmented 切 `Plan` / `History`，默认 Plan。
- **前置条件**：至少配对一台 Mac 且它在线（[iPhone 在线查看](iphone-live-view.md)）；数字来自 Mac 上的 daemon。
- **主要结果**：Plan 一台 Mac 一张卡，每个账号每个窗口一行百分比；History 一张数字卡（Cost、Tokens、Sessions / Turns / Calls）加一张每日花费柱状图。
- **只读边界**：iPhone 不向服务商请求、不落盘——退出 App 再进就是加载态；开关、Percent、Detail 表都在 Mac 上。
- **相关文档**：[Mac 用量](mac-usage.md)、[Mac 套餐用量](mac-plan-usage.md)、[数据流](../data-flows.md#用量)。

## 主流程

1. 点底部 `Usage`。
   - 系统反馈：Plan 段先出现，每台 Mac 一张卡：卡上方是 Mac 名与在线状态，卡内 `Claude Code` 在前、`Codex` 在后，卡头右端 `updated 2m ago`，每个窗口一行——`SESSION · 5 HOURS` / `WEEKLY · 7 DAYS` / `FABLE · 7 DAYS`、右端百分比、6pt 用量条、`resets in 2h 10m`。第一次进入先是卡头 + `Loading plan limits…`，一两秒后换成数字。
   - 规则引用：[IOS-R-017](iphone-live-view.md#ios-r-017-用量与套餐额度只读且不缓存)、[USE-R-001](#use-r-001-数字来自每台-mac-iphone-只读)。
2. 切到 `History`。
   - 系统反馈：标题下是两个菜单 `This week ⌄`、`All Macs ⌄`；数字卡卡头写范围（`Sep 1 – 7, 2026`），`COST` 大数字带 `↑ 18% vs last week`，`TOKENS` 大数字下面是四段构成条与 `Cache read 78% · output 7%`，最后一行 `SESSIONS · TURNS · CALLS`；图卡 `COST PER DAY`，一天一根柱，Claude Code 深蓝、Codex 浅蓝叠着，图例在下。
   - 规则引用：[USE-R-002](#use-r-002-history-只有总览合计不受图的过滤影响)。
3. 点图里的一根柱子。
   - 系统反馈：其余柱子变淡，卡头换成这一天（`Thu, Sep 4`）和 `Clear`，Cost / Tokens 换成这一天的数字，Cost 下面写两家拆分 `Claude Code $4.05 · Codex $1.12`。再点一次或点 `Clear` 回到整段。
4. 在图卡右上点 `All agents ⌄` 选一家。
   - 系统反馈：标题变 `COST PER DAY · BY MODEL`，柱子改按这家的模型堆叠，图例换成模型名（模型多于四个时只画前三 + `Other N models`）；数字卡不变。柱子整体变矮——纵轴不重新标定，量级差异自己显现。
   - 规则引用：[USE-R-002](#use-r-002-history-只有总览合计不受图的过滤影响)。
5. 换范围（`Today` / `This month`）或换 scope（某台 Mac）。
   - 系统反馈：换范围清掉柱子的选中态，Today 按小时画柱、This month 30 根；换成某台 Mac 时 Cost、Tokens、三个计数一起缩到那台的份额。
   - 规则引用：[USE-R-003](#use-r-003-范围按每台-mac-自己的本地日算)。

完成信号：Plan 的数字与 Mac 上 Settings › Usage 的卡一致；History 的 Cost 与 Mac 上 Usage 页同范围的 Summary 一致。

## 页面结构

- **Plan**：Inset Grouped 列表，一台 Mac 一段。段头 = Mac 名 + 状态点 + `Online` / `Offline · 2h ago`。卡内一账号一小节：Agent 标记 + 名字 + `updated 2m ago`（关着写 `off`），下面每个服务商报了的窗口一行（没报的不占位）。条永远画已用；数字按这台 Mac 的 `Percent` 设置显示已用或剩余（剩余时右下补 `42% used`）；≥ 90% 只有数字变橙。段脚说明数字每 5 分钟由各台 Mac 刷新。
- **History**：范围行（`Today · This week · This month` 与 `All Macs` / 某台 Mac 两个菜单）→ 数字卡（卡头范围或选中的那天 + Clear / `updated 2m ago`；`COST`、`TOKENS` 同一号大数字；`SESSIONS / TURNS / CALLS` 三等分）→ 图卡（`COST PER DAY[ · BY MODEL]` + agent 菜单；152 高的堆叠柱；图例）。
- **刷新**：进入 Tab 立即问一次；下拉刷新；页面可见时 Plan 每 60 秒、History 每 30 秒；离开 Tab 停。

## 规则

### USE-R-001 数字来自每台 Mac，iPhone 只读

- 条件：Usage Tab 可见。
- 行为：iPhone 经 Relay 向每台配对的 Mac 索取套餐额度快照与用量报表；Mac 上的 daemon 是唯一数据源。
- 结果：与该 Mac 自己的 Settings › Usage、Usage 页数字一致；「已用 / 剩余」跟这台 Mac 的 `Percent` 设置走，两台 Mac 设置不同就各显各的。
- 限制或例外：iPhone 上没有开关、没有 Percent 设置、没有 Detail 表；不向服务商请求、不落盘。

### USE-R-002 History 只有总览，合计不受图的过滤影响

- 条件：在图卡里选了某一家 Agent。
- 行为：只有图与图例变成按这家的模型堆叠；数字卡的 Cost、Tokens、三个计数仍是整段所有 Agent 的合计。
- 结果：合计永远有入口；纵轴不随过滤重标定，只看一家时柱子整体变矮。
- 限制或例外：Mac 端的 Agent 分段作用于整张 Summary 卡，这是两端有意的差异；没有价目的模型不产生花费，不入图，数字卡下方注明 `N models have no price · counted in tokens, not in cost`。

### USE-R-003 范围按每台 Mac 自己的本地日算

- 条件：History 选了 `Today` / `This week` / `This month`。
- 行为：iPhone 只把档位发给每台 Mac，每台 Mac 按自己的本地日历展开（周从周一起），`All Macs` 把各台的结果按日相加。
- 结果：每台 Mac 的数字与它自己 Usage 页同档位一致。
- 限制或例外：iPhone 与某台 Mac 跨时区时，柱子下的日期标签按 iPhone 的日历画，可能与那台 Mac 差一天，数字不受影响；没有 `Custom`。

## 空状态与故障

- **No Macs paired**：两段各一句说明和一个 `Pair a Mac` 行，点了去 Macs Tab。
- **Mac 离线**：Plan 卡数字不撤，卡头 `updated 2h ago`，卡内一行写明 `<Mac> offline · numbers from 2h ago`；History 注明 `<Mac> data as of 2h ago`，`All Macs` 照算但写清算到哪一刻。
- **全部拉不到**：History 数字卡换成 `Can't reach any Mac` 和上次成功的时间，图卡不出现。
- **iPhone 断网**：页顶一条黄底提示写明数字有多旧，两段的数字都保留。
- **登录过期 / 未登录 / 被拒 / 限流**：Plan 卡里那一小节按 Mac 上同样的文案写原因（`Saved sign-in expired · sign in again with Claude Code`、`Not signed in · …`、`Rate limited · retry in 4m 0s`）；限流时保留上一次的数字。去 Mac 上处理。
- **开关关着**：卡头右端 `off`，一行灰说明；要打开去 Mac 的 Settings › Usage。
- **本范围无用量**：`$0.00` + `no spend in this range`，图只剩底线。

## 业务数据

iPhone 不保存任何用量数据：报表与套餐额度快照只在本次运行的内存里，每台 Mac 一份；`All Macs` 的合计在 iPhone 上现算。范围、scope、agent 菜单的选择也不记忆，每次进入都是默认值（Plan、This week、All Macs、All agents）。完整生命周期见[数据流](../data-flows.md#用量)。

## 相关文档

- [功能全景](../index.md)
- [iPhone 在线查看](iphone-live-view.md)
- [Mac 用量](mac-usage.md) · [Mac 套餐用量](mac-plan-usage.md)
- [数据流](../data-flows.md)
