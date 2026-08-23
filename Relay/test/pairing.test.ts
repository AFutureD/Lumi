import { env, runDurableObjectAlarm, SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { PAIRING_CODE_ALPHABET } from "../src/pairing-code";
import {
  authHeaders,
  cancelSession,
  claimCode,
  collectMessages,
  createPairingSession,
  decide,
  deviceID,
  freshHost,
  openSocket,
  readSession,
  reveal,
  submitDevice,
} from "./helpers";

interface SessionView {
  state: string;
  hostName: string | null;
  hostPublicKey?: string;
  hostNonce?: string;
  deviceToken?: string;
  pairedAt?: string;
}

describe("pairing sessions", () => {
  it("walks a device from code to token", async () => {
    const { id: hostID, secret: hostSecret } = await freshHost("happy");
    const session = await createPairingSession(hostID, hostSecret);
    expect(session.code).toHaveLength(6);
    for (const symbol of session.code) expect(PAIRING_CODE_ALPHABET).toContain(symbol);

    const claimed = await claimCode(session.code);
    expect(claimed.status).toBe(200);
    expect(await claimed.json()).toEqual({
      sessionID: session.sessionID,
      hostID,
      hostName: "Test Mac",
      commit: session.commit,
    });

    const host = await openSocket("host", hostSecret, undefined, hostID);
    const hostMessages = collectMessages(host);
    const submitted = await submitDevice(hostID, session.sessionID, deviceID);
    expect(submitted.status).toBe(200);
    expect(await submitted.json()).toEqual({ state: "submitted" });
    expect(await hostMessages.nextFrame("pairing_device")).toEqual({
      type: "pairing_device",
      sessionID: session.sessionID,
      deviceID,
      deviceName: `${deviceID} iPhone`,
      devicePublicKey: `public-key-${deviceID}-000000000000`,
    });

    let view = await (await readSession(hostID, session.sessionID)).json<SessionView>();
    expect(view).toEqual({ state: "submitted", hostName: "Test Mac" });

    const revealed = await reveal(hostID, hostSecret, session.sessionID);
    expect(revealed.status).toBe(200);
    view = await (await readSession(hostID, session.sessionID)).json<SessionView>();
    expect(view.state).toBe("revealed");
    expect(view.hostPublicKey).toBe(session.hostPublicKey);
    expect(view.hostNonce).toMatch(/^host-nonce-/u);
    expect(view.deviceToken).toBeUndefined();

    const approved = await decide(hostID, hostSecret, session.sessionID, true);
    expect(approved.status).toBe(200);
    expect(await approved.json()).toEqual({ state: "approved", deviceID });
    view = await (await readSession(hostID, session.sessionID)).json<SessionView>();
    expect(view.state).toBe("approved");
    expect(view.hostNonce).toBeDefined();
    expect(view.deviceToken?.length).toBeGreaterThan(32);
    expect(view.pairedAt).toBeDefined();
    if (!view.deviceToken) throw new Error("missing token");

    const device = await openSocket("device", view.deviceToken, deviceID, hostID);
    device.close();
    const listed = await SELF.fetch(`https://example.com/v1/hosts/${hostID}/devices`, {
      headers: authHeaders(hostSecret),
    });
    const list = await listed.json<{ devices: Array<Record<string, unknown>> }>();
    expect(list.devices).toEqual([
      expect.objectContaining({
        id: deviceID,
        name: `${deviceID} iPhone`,
        publicKey: `public-key-${deviceID}-000000000000`,
        revokedAt: null,
      }),
    ]);
    expect(Object.keys(list.devices[0] ?? {}).sort()).toEqual(["id", "name", "pairedAt", "publicKey", "revokedAt"]);
    host.close();
  });

  it("spends a code once and rejects unknown or expired codes", async () => {
    const { id: hostID, secret: hostSecret } = await freshHost("once");
    const session = await createPairingSession(hostID, hostSecret);
    expect((await claimCode(session.code)).status).toBe(200);
    const again = await claimCode(session.code);
    expect(again.status).toBe(404);
    expect(await again.json()).toEqual({ error: "invalid_or_expired_code" });

    expect((await claimCode("ZZZZZZ")).status).toBe(404);
    expect((await claimCode("not a code")).status).toBe(404);

    const shortLived = await createPairingSession(hostID, hostSecret, {
      expiresAt: new Date(Date.now() + 1_000).toISOString(),
    });
    await new Promise((resolve) => setTimeout(resolve, 1_100));
    expect((await claimCode(shortLived.code)).status).toBe(404);
    const view = await (await readSession(hostID, shortLived.sessionID)).json<SessionView>();
    expect(view.state).toBe("expired");
  });

  it("refuses a device submission while the Mac is offline", async () => {
    const { id: hostID, secret: hostSecret } = await freshHost("offline");
    const session = await createPairingSession(hostID, hostSecret);
    expect((await claimCode(session.code)).status).toBe(200);
    const submitted = await submitDevice(hostID, session.sessionID, deviceID);
    expect(submitted.status).toBe(409);
    expect(await submitted.json()).toEqual({ error: "host_offline" });
    const view = await (await readSession(hostID, session.sessionID)).json<SessionView>();
    expect(view.state).toBe("claimed");
  });

  it("enforces the state machine", async () => {
    const { id: hostID, secret: hostSecret } = await freshHost("states");
    const session = await createPairingSession(hostID, hostSecret);
    const host = await openSocket("host", hostSecret, undefined, hostID);

    // Reveal before any device submitted.
    const early = await reveal(hostID, hostSecret, session.sessionID);
    expect(early.status).toBe(409);
    expect(await early.json()).toEqual({ error: "invalid_state", state: "offered" });

    // Submit before claim.
    expect((await submitDevice(hostID, session.sessionID, deviceID)).status).toBe(409);
    expect((await claimCode(session.code)).status).toBe(200);
    expect((await submitDevice(hostID, session.sessionID, deviceID)).status).toBe(200);

    // Approve before reveal.
    const premature = await decide(hostID, hostSecret, session.sessionID, true);
    expect(premature.status).toBe(409);
    expect(await premature.json()).toEqual({ error: "invalid_state", state: "submitted" });

    // Reject straight from submitted.
    const rejected = await decide(hostID, hostSecret, session.sessionID, false);
    expect(rejected.status).toBe(200);
    expect(await rejected.json()).toEqual({ state: "rejected" });
    const view = await (await readSession(hostID, session.sessionID)).json<SessionView>();
    expect(view).toEqual({ state: "rejected", hostName: "Test Mac" });

    // Terminal states refuse further transitions.
    expect((await reveal(hostID, hostSecret, session.sessionID)).status).toBe(409);
    expect((await decide(hostID, hostSecret, session.sessionID, true)).status).toBe(409);
    const listed = await SELF.fetch(`https://example.com/v1/hosts/${hostID}/devices`, {
      headers: authHeaders(hostSecret),
    });
    expect(await listed.json()).toEqual({ devices: [] });
    host.close();
  });

  it("tells the Mac when the device cancels after submitting", async () => {
    const { id: hostID, secret: hostSecret } = await freshHost("devcancel");
    const session = await createPairingSession(hostID, hostSecret);
    expect((await claimCode(session.code)).status).toBe(200);
    const host = await openSocket("host", hostSecret, undefined, hostID);
    const hostMessages = collectMessages(host);
    expect((await submitDevice(hostID, session.sessionID, deviceID)).status).toBe(200);
    await hostMessages.nextFrame("pairing_device");

    const cancelled = await cancelSession(hostID, session.sessionID, session.sessionID);
    expect(cancelled.status).toBe(204);
    expect(await hostMessages.nextFrame("pairing_closed")).toEqual({
      type: "pairing_closed",
      sessionID: session.sessionID,
      reason: "cancelled",
    });
    const view = await (await readSession(hostID, session.sessionID)).json<SessionView>();
    expect(view.state).toBe("cancelled");
    // Cancelling again is idempotent.
    expect((await cancelSession(hostID, session.sessionID, hostSecret)).status).toBe(204);
    host.close();
  });

  it("lets the Mac cancel its own session", async () => {
    const { id: hostID, secret: hostSecret } = await freshHost("hostcancel");
    const session = await createPairingSession(hostID, hostSecret);
    expect((await cancelSession(hostID, session.sessionID, hostSecret)).status).toBe(204);
    expect((await claimCode(session.code)).status).toBe(404);
    const view = await (await readSession(hostID, session.sessionID)).json<SessionView>();
    expect(view.state).toBe("cancelled");
  });

  it("retires the previous session when a new one is created", async () => {
    const { id: hostID, secret: hostSecret } = await freshHost("retire");
    const first = await createPairingSession(hostID, hostSecret);
    const second = await createPairingSession(hostID, hostSecret);
    expect((await claimCode(first.code)).status).toBe(404);
    const view = await (await readSession(hostID, first.sessionID)).json<SessionView>();
    expect(view.state).toBe("cancelled");
    expect((await claimCode(second.code)).status).toBe(200);
  });

  it("rejects a wrong session bearer", async () => {
    const { id: hostID, secret: hostSecret } = await freshHost("bearer");
    const session = await createPairingSession(hostID, hostSecret);
    expect((await readSession(hostID, session.sessionID, "not-the-session-id")).status).toBe(401);
    expect((await submitDevice(hostID, session.sessionID, deviceID, {})).status).toBe(409);
    const forged = await SELF.fetch(`https://example.com/v1/hosts/${hostID}/pairing-sessions/${session.sessionID}/device`, {
      method: "POST",
      headers: authHeaders("not-the-session-id"),
      body: JSON.stringify({ deviceID, deviceName: "x", devicePublicKey: "public-key-0000000000000000" }),
    });
    expect(forged.status).toBe(401);
    expect((await cancelSession(hostID, session.sessionID, "not-the-session-id")).status).toBe(401);
    const missing = await readSession(hostID, "no-such-session-000000000000000000000000000");
    expect(missing.status).toBe(404);
  });

  it("requires the host secret for host-only calls", async () => {
    const { id: hostID, secret: hostSecret } = await freshHost("hostauth");
    const session = await createPairingSession(hostID, hostSecret);
    expect((await reveal(hostID, session.sessionID, session.sessionID)).status).toBe(401);
    expect((await decide(hostID, session.sessionID, session.sessionID, true)).status).toBe(401);
    const create = await SELF.fetch(`https://example.com/v1/hosts/${hostID}/pairing-sessions`, {
      method: "POST",
      headers: authHeaders("wrong-secret"),
      body: JSON.stringify({ commit: "commit-0000000000000000", hostPublicKey: "key-00000000000000000", expiresAt: new Date(Date.now() + 1000).toISOString() }),
    });
    expect(create.status).toBe(401);
  });

  it("rate limits claims per source address", async () => {
    await freshHost("ratelimit");
    for (let attempt = 0; attempt < 5; attempt += 1) {
      expect((await claimCode("ZZZZZZ", "198.51.100.7")).status).toBe(404);
    }
    const limited = await claimCode("ZZZZZZ", "198.51.100.7");
    expect(limited.status).toBe(429);
    expect(await limited.json()).toEqual({ error: "rate_limited" });
    // Another address is unaffected.
    expect((await claimCode("ZZZZZZ", "198.51.100.8")).status).toBe(404);
  });

  it("counts claims from one IPv6 /64 as one source", async () => {
    await freshHost("ratelimit6");
    for (let attempt = 0; attempt < 5; attempt += 1) {
      expect((await claimCode("ZZZZZZ", "2001:db8:77:1::1")).status).toBe(404);
    }
    // Another address in the same /64 shares the budget…
    expect((await claimCode("ZZZZZZ", "2001:db8:77:1:ffff:ffff:ffff:ffff")).status).toBe(429);
    // …a neighbouring /64 does not.
    expect((await claimCode("ZZZZZZ", "2001:db8:77:2::1")).status).toBe(404);
  });

  it("purges finished sessions, and the device token in them, once the deadline passes", async () => {
    const { id: hostID, secret: hostSecret } = await freshHost("purge");
    const session = await createPairingSession(hostID, hostSecret, {
      expiresAt: new Date(Date.now() + 2_500).toISOString(),
    });
    expect((await claimCode(session.code)).status).toBe(200);
    const host = await openSocket("host", hostSecret, undefined, hostID);
    const hostMessages = collectMessages(host);
    expect((await submitDevice(hostID, session.sessionID, "device-purge-0001")).status).toBe(200);
    await hostMessages.nextFrame("pairing_device");
    expect((await reveal(hostID, hostSecret, session.sessionID)).status).toBe(200);
    expect((await decide(hostID, hostSecret, session.sessionID, true)).status).toBe(200);
    host.close(1000, "done");

    const approved = await readSession(hostID, session.sessionID);
    expect(approved.status).toBe(200);
    expect((await approved.json<SessionView>()).deviceToken).toBeDefined();

    // The alarm is scheduled for just after the deadline; run it after the
    // deadline has passed.
    await new Promise((resolve) => setTimeout(resolve, 2_600));
    const stub = env.HOST_RELAY.getByName(hostID);
    expect(await runDurableObjectAlarm(stub)).toBe(true);

    const gone = await readSession(hostID, session.sessionID);
    expect(gone.status).toBe(404);
    // Nothing left to purge: no alarm is re-armed.
    expect(await runDurableObjectAlarm(stub)).toBe(false);
    // The Mac's device list is untouched.
    const listed = await SELF.fetch(`https://example.com/v1/hosts/${hostID}/devices`, { headers: authHeaders(hostSecret) });
    const list = await listed.json<{ devices: Array<{ id: string }> }>();
    expect(list.devices.map((device) => device.id)).toEqual(["device-purge-0001"]);
  });

  it("validates the session body", async () => {
    const { id: hostID, secret: hostSecret } = await freshHost("validate");
    const create = await SELF.fetch(`https://example.com/v1/hosts/${hostID}/pairing-sessions`, {
      method: "POST",
      headers: authHeaders(hostSecret),
      body: JSON.stringify({
        commit: "commit-0000000000000000",
        hostPublicKey: "key-00000000000000000",
        expiresAt: new Date(Date.now() + 11 * 60_000).toISOString(),
      }),
    });
    expect(create.status).toBe(400);
    const claim = await SELF.fetch("https://example.com/v1/pairing/claim", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({}),
    });
    expect(claim.status).toBe(400);
  });
});
