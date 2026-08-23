import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
      // Tests run quiet: only warnings and errors from `src/log.ts` reach the
      // reporter. (Tens of info lines per test keep the workers pool from
      // shutting down cleanly; LOG_LEVEL=debug here when you need them.)
      miniflare: { bindings: { LOG_LEVEL: "warn" } },
    }),
  ],
  test: {
    coverage: {
      enabled: false,
    },
  },
});
