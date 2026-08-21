# Agent Status Relay

The Relay is a TypeScript Cloudflare Worker backed by one Durable Object per Mac. It provides host registration, one-time pairing, per-device credentials, revocation, hibernating WebSockets and online presence. It keeps no replay buffer: a frame for a device that is not connected is dropped, and the device asks the host for the index again when it reconnects. Hosts send sealed `data` frames (per-device monotonic sequences); devices may send only sealed `request` frames (sync index, fetch session, session reviewed, …), which are forwarded to the host verbatim — anything else closes the socket as a read-only violation.

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
