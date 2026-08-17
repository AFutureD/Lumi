# Agent Status Relay

The Relay is a TypeScript Cloudflare Worker backed by one Durable Object per Mac. It provides host registration, one-time pairing, per-device credentials, revocation, hibernating WebSockets, online presence, and a 60-second in-memory ciphertext replay window.

Session content is opaque to the Worker and is not written to persistent storage. Durable Object storage contains authorization, rate-limit, expiry, and per-channel sequence metadata only.

APNs is not part of the current implementation.

## Local verification

```sh
pnpm install --frozen-lockfile
pnpm run check
pnpm test
pnpm run deploy:dry-run
```

## Deployment

```sh
pnpm exec wrangler deploy
```

The deployed health endpoint is `GET /health`.
