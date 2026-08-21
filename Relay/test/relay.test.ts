import { env, SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

const hostID = "host-test-000001";
const hostSecret = "host-secret-that-is-long-enough-for-testing-000001";
const challenge = "pairing-challenge-00000000000000000001";
const deviceID = "device-test-0001";

describe("relay pairing and authorization", () => {
  it("pairs once, lists, and revokes a device", async () => {
    await registerHost();
    const offer = await SELF.fetch(`https://example.com/v1/hosts/${hostID}/pairing-offers`, {
      method: "POST",
      headers: authHeaders(hostSecret),
      body: JSON.stringify({
        challenge,
        hostPublicKey: "host-public-key-00000000000000000001",
        expiresAt: new Date(Date.now() + 60_000).toISOString(),
      }),
    });
    expect(offer.status).toBe(201);

    const paired = await SELF.fetch(`https://example.com/v1/hosts/${hostID}/pair`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        challenge,
        deviceID,
        deviceName: "Test iPhone",
        devicePublicKey: "device-public-key-0000000000000000001",
      }),
    });
    expect(paired.status).toBe(201);
    const pairing = await paired.json<{ deviceToken: string }>();
    expect(pairing.deviceToken.length).toBeGreaterThan(32);

    const reused = await SELF.fetch(`https://example.com/v1/hosts/${hostID}/pair`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        challenge,
        deviceID: "device-test-0002",
        deviceName: "Second iPhone",
        devicePublicKey: "device-public-key-0000000000000000002",
      }),
    });
    expect(reused.status).toBe(401);

    const listed = await SELF.fetch(`https://example.com/v1/hosts/${hostID}/devices`, {
      headers: authHeaders(hostSecret),
    });
    expect(listed.status).toBe(200);
    const list = await listed.json<{ devices: Array<{ id: string; publicKey: string; revokedAt: string | null }> }>();
    expect(list.devices).toEqual([
      expect.objectContaining({
        id: deviceID,
        publicKey: "device-public-key-0000000000000000001",
        revokedAt: null,
      }),
    ]);

    const revoked = await SELF.fetch(`https://example.com/v1/hosts/${hostID}/devices/${deviceID}`, {
      method: "DELETE",
      headers: authHeaders(hostSecret),
    });
    expect(revoked.status).toBe(204);

    const denied = await SELF.fetch(
      `https://example.com/v1/hosts/${hostID}/ws?role=device&deviceId=${deviceID}`,
      { headers: { ...authHeaders(pairing.deviceToken), Upgrade: "websocket" } },
    );
    expect(denied.status).toBe(401);
  });

  it("does not expose a shared global relay object", () => {
    const first = env.HOST_RELAY.idFromName("host-one-0000001");
    const second = env.HOST_RELAY.idFromName("host-two-0000002");
    expect(first.toString()).not.toBe(second.toString());
  });

  it("forwards sealed device requests to the host and closes on anything else", async () => {
    await registerHost();
    const deviceToken = await pairDevice(hostID, hostSecret, deviceID, "pairing-challenge-req-00000000000001");

    const host = await openSocket("host", hostSecret);
    const hostMessages = collectMessages(host);
    const device = await openSocket("device", deviceToken, deviceID);

    // A sealed device request (sync index, fetch session, session reviewed…)
    // is forwarded verbatim; the relay cannot read it.
    device.send(JSON.stringify({
      version: { major: 1, minor: 2 },
      hostID,
      deviceID,
      sequence: 1,
      kind: "request",
      nonce: "bm9uY2U=",
      ciphertext: "Y2lwaGVydGV4dA==",
    }));
    expect(await hostMessages.nextFrame("request")).toEqual(
      expect.objectContaining({ deviceID, sequence: 1, kind: "request" }),
    );

    // A request without a sealed body is rejected as an invalid frame, not forwarded.
    device.send(JSON.stringify({ version: { major: 1, minor: 2 }, hostID, deviceID, sequence: 2, kind: "request" }));
    const deviceMessages = collectMessages(device);
    expect(await deviceMessages.nextFrame("error")).toEqual(expect.objectContaining({ code: "invalid_frame" }));

    // Devices cannot publish data frames (or the retired hello/ack/attention kinds).
    for (const kind of ["data", "hello", "ack", "attention"]) {
      const socket = await openSocket("device", deviceToken, deviceID);
      const closed = new Promise<number>((resolve) => socket.addEventListener("close", (event) => resolve(event.code)));
      socket.send(JSON.stringify({
        version: { major: 1, minor: 2 },
        hostID,
        deviceID,
        sequence: 3,
        kind,
        nonce: "bm9uY2U=",
        ciphertext: "Y2lwaGVydGV4dA==",
      }));
      expect(await closed).toBe(1008);
    }
    host.close();
    device.close();
  });

  it("delivers a host frame burst in order and reports reused sequences with the channel cursor", async () => {
    await registerHost();
    const deviceToken = await pairDevice(hostID, hostSecret, deviceID, "pairing-challenge-seq-00000000000001");

    const host = await openSocket("host", hostSecret);
    const hostMessages = collectMessages(host);
    const device = await openSocket("device", deviceToken, deviceID);
    const deviceMessages = collectMessages(device);

    host.send(routingFrame(1));
    host.send(routingFrame(2));
    host.send(routingFrame(3));
    expect(await deviceMessages.nextFrame("data")).toEqual(expect.objectContaining({ sequence: 1 }));
    expect(await deviceMessages.nextFrame("data")).toEqual(expect.objectContaining({ sequence: 2 }));
    expect(await deviceMessages.nextFrame("data")).toEqual(expect.objectContaining({ sequence: 3 }));

    // Non-monotonic host frames are dropped and the host learns the cursor.
    host.send(routingFrame(2));
    expect(await hostMessages.nextFrame("error")).toEqual(
      expect.objectContaining({ code: "non_monotonic_sequence", sequence: 2, lastSequence: 3, deviceID }),
    );
    host.send(routingFrame(4));
    expect(await deviceMessages.nextFrame("data")).toEqual(expect.objectContaining({ sequence: 4 }));

    host.close();
    device.close();
  });

  it("tracks monotonic sequences independently for each iOS channel", async () => {
    const multiHostID = "host-multi-000001";
    const multiSecret = "host-secret-that-is-long-enough-for-testing-multi-000001";
    await registerHost(multiHostID, multiSecret);

    const firstID = "device-multi-0001";
    const secondID = "device-multi-0002";
    const firstToken = await pairDevice(multiHostID, multiSecret, firstID, "challenge-multi-device-000000000000001");
    const secondToken = await pairDevice(multiHostID, multiSecret, secondID, "challenge-multi-device-000000000000002");
    const host = await openSocket("host", multiSecret, undefined, multiHostID);
    const firstDevice = await openSocket("device", firstToken, firstID, multiHostID);
    const secondDevice = await openSocket("device", secondToken, secondID, multiHostID);
    const firstMessages = collectMessages(firstDevice);
    const secondMessages = collectMessages(secondDevice);

    host.send(routingFrame(1, multiHostID, firstID));
    host.send(routingFrame(1, multiHostID, secondID));

    expect(await firstMessages.nextFrame("data")).toEqual(expect.objectContaining({ sequence: 1, deviceID: firstID }));
    expect(await secondMessages.nextFrame("data")).toEqual(expect.objectContaining({ sequence: 1, deviceID: secondID }));
    host.close();
    firstDevice.close();
    secondDevice.close();
  });

  it("marks a Mac unavailable when its host socket closes", async () => {
    const presenceHostID = "host-presence-0001";
    const presenceSecret = "host-secret-that-is-long-enough-for-presence-0001";
    const presenceDeviceID = "device-presence-0001";
    await registerHost(presenceHostID, presenceSecret);
    const deviceToken = await pairDevice(presenceHostID, presenceSecret, presenceDeviceID, "challenge-presence-device-00000000000001");
    const host = await openSocket("host", presenceSecret, undefined, presenceHostID);
    const device = await openSocket("device", deviceToken, presenceDeviceID, presenceHostID);
    const messages = collectMessages(device);

    expect(await messages.nextFrame("presence")).toEqual(expect.objectContaining({ online: true }));
    host.close(1000, "test complete");
    expect(await messages.nextFrame("presence")).toEqual(expect.objectContaining({ online: false }));
    device.close();
  });
});

async function registerHost(id = hostID, secret = hostSecret): Promise<void> {
  const response = await SELF.fetch(`https://example.com/v1/hosts/${id}`, {
    method: "PUT",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ hostSecret: secret }),
  });
  expect(response.status).toBe(200);
}

async function pairDevice(pairHostID: string, secret: string, pairDeviceID: string, pairChallenge: string): Promise<string> {
  const offer = await SELF.fetch(`https://example.com/v1/hosts/${pairHostID}/pairing-offers`, {
    method: "POST",
    headers: authHeaders(secret),
    body: JSON.stringify({
      challenge: pairChallenge,
      hostPublicKey: `host-public-key-${pairDeviceID}-00000000000000`,
      expiresAt: new Date(Date.now() + 60_000).toISOString(),
    }),
  });
  expect(offer.status).toBe(201);
  const paired = await SELF.fetch(`https://example.com/v1/hosts/${pairHostID}/pair`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      challenge: pairChallenge,
      deviceID: pairDeviceID,
      deviceName: pairDeviceID,
      devicePublicKey: `public-key-${pairDeviceID}-000000000000`,
    }),
  });
  expect(paired.status).toBe(201);
  return (await paired.json<{ deviceToken: string }>()).deviceToken;
}

function authHeaders(token: string): Record<string, string> {
  return {
    authorization: `Bearer ${token}`,
    "content-type": "application/json",
  };
}

async function openSocket(
  role: "host" | "device",
  token: string,
  socketDeviceID?: string,
  socketHostID = hostID,
): Promise<WebSocket> {
  const query = role === "host" ? "role=host" : `role=device&deviceId=${socketDeviceID}`;
  const response = await SELF.fetch(`https://example.com/v1/hosts/${socketHostID}/ws?${query}`, {
    headers: { ...authHeaders(token), Upgrade: "websocket" },
  });
  expect(response.status).toBe(101);
  const socket = response.webSocket;
  if (!socket) throw new Error("Missing WebSocket endpoint");
  socket.accept();
  return socket;
}

function routingFrame(sequence: number, frameHostID = hostID, frameDeviceID = deviceID): string {
  return JSON.stringify({
    version: { major: 1, minor: 2 },
    hostID: frameHostID,
    deviceID: frameDeviceID,
    sequence,
    kind: "data",
    nonce: "AAECAwQFBgcICQoL",
    ciphertext: "opaque-encrypted-payload",
  });
}

function collectMessages(socket: WebSocket): { nextFrame: (kind: string) => Promise<Record<string, unknown>> } {
  const queue: Array<Record<string, unknown>> = [];
  const waiters: Array<(value: Record<string, unknown>) => void> = [];
  socket.addEventListener("message", (event) => {
    if (typeof event.data !== "string") return;
    const value = JSON.parse(event.data) as Record<string, unknown>;
    const waiter = waiters.shift();
    if (waiter) waiter(value); else queue.push(value);
  });
  return {
    async nextFrame(kind: string): Promise<Record<string, unknown>> {
      while (true) {
        const value = queue.shift() ?? await new Promise<Record<string, unknown>>((resolve) => waiters.push(resolve));
        if (value.kind === kind || value.type === kind) return value;
      }
    },
  };
}
