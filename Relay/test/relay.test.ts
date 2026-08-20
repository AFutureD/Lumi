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

  it("forwards device hellos to the host and a frame burst to the device in order", async () => {
    await registerHost();
    const resyncChallenge = "pairing-challenge-resync-000000000001";
    await SELF.fetch(`https://example.com/v1/hosts/${hostID}/pairing-offers`, {
      method: "POST",
      headers: authHeaders(hostSecret),
      body: JSON.stringify({
        challenge: resyncChallenge,
        hostPublicKey: "host-public-key-resync-000000000000001",
        expiresAt: new Date(Date.now() + 60_000).toISOString(),
      }),
    });
    const paired = await SELF.fetch(`https://example.com/v1/hosts/${hostID}/pair`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        challenge: resyncChallenge,
        deviceID,
        deviceName: "Resync iPhone",
        devicePublicKey: "device-public-key-resync-00000000000001",
      }),
    });
    const pairing = await paired.json<{ deviceToken: string }>();

    const host = await openSocket("host", hostSecret);
    const hostMessages = collectMessages(host);
    const device = await openSocket("device", pairing.deviceToken, deviceID);
    const deviceMessages = collectMessages(device);

    // The relay keeps no replay buffer: a hello behind the host's sequence is
    // forwarded verbatim so the Mac can resend everything itself.
    device.send(JSON.stringify({
      version: { major: 1, minor: 0 },
      hostID,
      deviceID,
      sequence: 0,
      kind: "hello",
      acknowledgedSequence: 0,
    }));
    expect(await hostMessages.nextFrame("hello")).toEqual(
      expect.objectContaining({ deviceID, acknowledgedSequence: 0 }),
    );

    // A publish batch (sessions then index) arrives complete and in order.
    host.send(routingFrame(1));
    host.send(routingFrame(2));
    host.send(routingFrame(3));
    expect(await deviceMessages.nextFrame("data")).toEqual(expect.objectContaining({ sequence: 1 }));
    expect(await deviceMessages.nextFrame("data")).toEqual(expect.objectContaining({ sequence: 2 }));
    expect(await deviceMessages.nextFrame("data")).toEqual(expect.objectContaining({ sequence: 3 }));

    // Non-monotonic host frames are still dropped.
    host.send(routingFrame(2));
    host.send(routingFrame(4));
    expect(await deviceMessages.nextFrame("data")).toEqual(expect.objectContaining({ sequence: 4 }));

    host.close();
    device.close();
  });

  it("tracks monotonic sequences independently for each iOS channel", async () => {
    const multiHostID = "host-multi-000001";
    const multiSecret = "host-secret-that-is-long-enough-for-testing-multi-000001";
    await registerHost(multiHostID, multiSecret);

    const pair = async (channelDeviceID: string, channelChallenge: string): Promise<string> => {
      await SELF.fetch(`https://example.com/v1/hosts/${multiHostID}/pairing-offers`, {
        method: "POST",
        headers: authHeaders(multiSecret),
        body: JSON.stringify({
          challenge: channelChallenge,
          hostPublicKey: "host-public-key-multi-000000000000001",
          expiresAt: new Date(Date.now() + 60_000).toISOString(),
        }),
      });
      const response = await SELF.fetch(`https://example.com/v1/hosts/${multiHostID}/pair`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          challenge: channelChallenge,
          deviceID: channelDeviceID,
          deviceName: channelDeviceID,
          devicePublicKey: `public-key-${channelDeviceID}-000000000000`,
        }),
      });
      expect(response.status).toBe(201);
      return (await response.json<{ deviceToken: string }>()).deviceToken;
    };

    const firstID = "device-multi-0001";
    const secondID = "device-multi-0002";
    const firstToken = await pair(firstID, "challenge-multi-device-000000000000001");
    const secondToken = await pair(secondID, "challenge-multi-device-000000000000002");
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
    const presenceChallenge = "challenge-presence-device-00000000000001";
    await registerHost(presenceHostID, presenceSecret);
    await SELF.fetch(`https://example.com/v1/hosts/${presenceHostID}/pairing-offers`, {
      method: "POST",
      headers: authHeaders(presenceSecret),
      body: JSON.stringify({
        challenge: presenceChallenge,
        hostPublicKey: "host-public-key-presence-0000000000001",
        expiresAt: new Date(Date.now() + 60_000).toISOString(),
      }),
    });
    const paired = await SELF.fetch(`https://example.com/v1/hosts/${presenceHostID}/pair`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        challenge: presenceChallenge,
        deviceID: presenceDeviceID,
        deviceName: "Presence iPhone",
        devicePublicKey: "device-public-key-presence-00000000001",
      }),
    });
    const pairing = await paired.json<{ deviceToken: string }>();
    const host = await openSocket("host", presenceSecret, undefined, presenceHostID);
    const device = await openSocket("device", pairing.deviceToken, presenceDeviceID, presenceHostID);
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
    version: { major: 1, minor: 0 },
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
