# Website

Lumi 官网落地页，部署在 <https://lumi.huanan.app>。

## 结构

静态单页加一条脚本路由，无框架、无构建步骤：

- `public/index.html` — 整个页面（内联 CSS + 一段缩放脚本）。
- `public/assets/` — App icon 与三张产品截图。
- `src/index.js` — 仅接管 `/download`：查 GitHub 最新 release，302 到其中的 dmg 直链；边缘缓存 5 分钟，查询失败则 302 到 releases 页兜底。其余路径仍由静态资源直出。
- `wrangler.jsonc` — Worker + assets，custom domain 绑定 `lumi.huanan.app`，workers.dev 关闭（与 Relay 同口径）。

`/download` 的 GitHub 查询可带 token 提高限额：`corepack pnpm wrangler secret put GITHUB_TOKEN`（fine-grained、公开仓库只读即可）。secret 只存于 Cloudflare，不进仓库；未配置时匿名查询，行为不变。

文案基准是 `docs/landing-page.md`；视觉基准是设计交接包（`design_handoff_landing_page`），取值来源为其中的 DESIGN SYSTEM。

## 开发与部署

工具链与 Relay 一致：pnpm 经 corepack 使用。

```bash
corepack pnpm install
corepack pnpm dev          # wrangler dev，本地预览
corepack pnpm run deploy   # wrangler deploy，发布到 lumi.huanan.app
                           # 注意要带 run：裸 `pnpm deploy` 是 pnpm 自己的子命令
```

## 已知留白

- Privacy / Terms 页面尚未存在，相关链接按交接文档的选项暂时隐藏。
- 三张产品截图来自设计稿，上线正式版前应换成真机截图；换 Notch 截图时需按新图透明留白重算负边距。
