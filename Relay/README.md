# Lumi Relay

The Relay is a TypeScript Cloudflare Worker backed by one `HostRelay` Durable Object per Mac plus a single `PairingDirectory` Durable Object. It provides host registration, code-based pairing, per-device credentials, revocation, hibernating WebSockets and online presence.

Pairing is a short session between a Mac and one iPhone. The Mac opens a session with a commitment to its public key (`POST /v1/hosts/:h/pairing-sessions`) and the directory issues a six-character code; the iPhone spends that code once (`POST /v1/pairing/claim`), submits its device key, and the two sides compare a short number derived from both keys after the Mac reveals its nonce. Only the Mac's explicit `decision` mints a device token. The directory stores only SHA-256(code) → host and session; the host relay stores the session's state, the commitment and the keys both parties already published. The Relay cannot derive the channel key, and it only learns the nonce behind the comparison number after both keys are fixed, so a key swap by the Relay shows up as mismatching numbers.

Revocation is `DELETE /v1/hosts/:h/devices/:d` (the row stays, listed as revoked, and the device's sockets close); `?purge=1` deletes the record so a Mac can clear a revoked iPhone from its list.

It keeps no replay buffer: a frame for a device that is not connected is dropped, and the device asks the host for the index again when it reconnects. Hosts send sealed `data` frames (per-device monotonic sequences); devices may send only sealed `request` frames (sync index, fetch session, session reviewed, …), which are forwarded to the host verbatim — anything else closes the socket as a read-only violation.

Session content is opaque to the Worker and is not written to persistent storage. Durable Object storage contains authorization, pairing-session, rate-limit, expiry, and per-channel sequence metadata only. Finished pairing sessions are purged by a Durable Object alarm once their deadline passes.

Every request is rate limited at the edge per client address (IPv6 per /64) through the `RATE_LIMITER` binding in `wrangler.jsonc` before it can reach a Durable Object, and plain `http://` is refused outside loopback. Pairing-code claims are limited again inside the directory, per source and globally.

APNs alerts are forwarded through `POST /v1/hosts/:h/notifications`: the daemon sends a short plaintext title and subtitle (the session's state word), the Durable Object signs an ES256 provider JWT (`APNS_KEY_ID` / `APNS_TEAM_ID` / `APNS_PRIVATE_KEY` secrets, `APNS_TOPIC` var) and posts to APNs — sandbox or production per the token each device registered via `PUT /v1/hosts/:h/devices/:d/push-token`. The alert text is never stored and never logged; a 410 (or `BadDeviceToken`) drops the stored token, and the device re-registers on its next launch or foregrounding — the iPhone re-reports its token unconditionally every time it starts, precisely so a token the Relay dropped on its own comes back without re-pairing.

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
