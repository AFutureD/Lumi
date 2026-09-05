# `codex-auto-review`：Codex 审批守卫线程的模型名没有价目

记录日期：2026-09-05。状态：保持现状（记无价格）。

## 现象

Usage 页 By agent 表里 Codex 下面出现一行模型 `codex-auto-review`，Cost 显示 `—`，表尾注明这部分 token 没有公开价格。2026-08-01 至 09-04 共 665K token。

## 它是什么

不是一个真实模型名。Codex 在自动审批模式下要执行一个动作时，会另起一条子线程让模型替用户审一遍"该不该放行"：

- rollout 的 `session_meta`：`thread_source: subagent`、`source.subagent.other: guardian`；
- 每回合 `turn_context.model` 写 `codex-auto-review`、`effort: low`；
- user 消息是"以下是 Codex agent 的历史，请评估它请求的这个动作"，模型回复是 JSON（`{"outcome":"allow"}` / `{"risk_level":"high","outcome":"deny","rationale":…}`）。

日志里没有写这条线程实际由哪个后端模型服务。

## 两边的处理

| | ccusage | Lumi |
| --- | --- | --- |
| 模型归属 | 按日期猜：2026-04-23 起猜 gpt-5.5，之前猜 gpt-5.4、gpt-5.3-codex（内置表 `codex-auto-review-fallbacks.json`），JSON 里标 `isFallback: true` | 照上报原样记 `codex-auto-review` |
| 费用 | 按猜的模型计价（本机约 $0.95） | 无价格，token 照常计入 Tokens |

## 为什么先这样

- Lumi 的原则是"没有公开价格就标无价格"，不用猜的数字冒充费用（见 [Usage 设计](../design/usage.md)）。
- 金额小（不到本月 Codex 费用的 0.2%），猜错的代价和猜对的收益都不大。

## 什么时候改

Codex 的 rollout 或 models.dev 明确写出这条线程用的模型时，在 `ModelPriceTable.aliases` 加一条映射即可，不需要动存储。

## 复现

```bash
grep -rl '"codex-auto-review"' ~/.codex/sessions | head -1
```

打开该文件看 `session_meta` 与前几条 `turn_context` / `event_msg`。
