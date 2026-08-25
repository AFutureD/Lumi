import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
      // Tests run quiet: only warnings and errors from `src/log.ts` reach the
      // reporter. (Tens of info lines per test keep the workers pool from
      // shutting down cleanly; LOG_LEVEL=debug here when you need them.)
      miniflare: {
        bindings: {
          LOG_LEVEL: "warn",
          // Throwaway P-256 key for the APNs JWT path; the tests stub the
          // global fetch for push.apple.com, so nothing real is signed for.
          APNS_KEY_ID: "TESTKEY000",
          APNS_TEAM_ID: "TESTTEAM00",
          APNS_PRIVATE_KEY: [
            "-----BEGIN PRIVATE KEY-----",
            "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgiUtD6JEY/l+aTUq1",
            "PQ5CwZu/Gjk66I9TiV4xnUBummehRANCAAQRnv6GZAO1vOMDvBMZ3dEwWSPYhVVH",
            "A7Fgfjbe/TqXuPOd4zYDvxo0g2VMwOuekr17pVeWm3BSJsJyQK+i8nr+",
            "-----END PRIVATE KEY-----",
          ].join("\n"),
        },
      },
    }),
  ],
  test: {
    coverage: {
      enabled: false,
    },
  },
});
