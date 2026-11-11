import { env, SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import {
  authHeaders,
  collectMessages,
  deviceID,
  freshHost,
  hostID,
  hostSecret,
  openSocket,
  pairDevice,
  registerHost,
  requestFrame,
  routingFrame,
} from "./helpers";

describe("relay authorization and forwarding", () => {
  it("lists and revokes a paired device", async () => {
    await registerHost();
    const deviceToken = await pairDevice(hostID, hostSecret, deviceID);

    const listed = await SELF.fetch(`https://example.com/v1/hosts/${hostID}/devices`, {
      headers: authHeaders(hostSecret),
    });
    expect(listed.status).toBe(200);
    const list = await listed.json<{ devices: Array<{ id: string; publicKey: string; revokedAt: string | null }> }>();
    expect(list.devices).toEqual([
      expect.objectContaining({
        id: deviceID,
        publicKey: `public-key-${deviceID}-000000000000`,
        revokedAt: null,
      }),
    ]);

    const revoked = await SELF.fetch(`https://example.com/v1/hosts/${hostID}/devices/${deviceID}`, {
      method: "DELETE",
      headers: authHeaders(hostSecret),
    });
    expect(revoked.status).toBe(204);
    // Revoked rows stay listed (the Mac shows them) until purged.
    const stillListed = await SELF.fetch(`https://example.com/v1/hosts/${hostID}/devices`, { headers: authHeaders(hostSecret) });
    const stillList = await stillListed.json<{ devices: Array<{ id: string; revokedAt: string | null }> }>();
    expect(stillList.devices.find((d) => d.id === deviceID)?.revokedAt).not.toBeNull();
    const purged = await SELF.fetch(`https://example.com/v1/hosts/${hostID}/devices/${deviceID}?purge=1`, {
      method: "DELETE",
      headers: authHeaders(hostSecret),
    });
    expect(purged.status).toBe(204);
    const afterPurge = await SELF.fetch(`https://example.com/v1/hosts/${hostID}/devices`, { headers: authHeaders(hostSecret) });
    const afterList = await afterPurge.json<{ devices: Array<{ id: string }> }>();
    expect(afterList.devices.find((d) => d.id === deviceID)).toBeUndefined();

    const denied = await SELF.fetch(
      `https://example.com/v1/hosts/${hostID}/ws?role=device&deviceId=${deviceID}`,
      { headers: { ...authHeaders(deviceToken), Upgrade: "websocket" } },
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
    const deviceToken = await pairDevice(hostID, hostSecret, deviceID);

    const host = await openSocket("host", hostSecret);
    const hostMessages = collectMessages(host);
    const device = await openSocket("device", deviceToken, deviceID);

    // A sealed device request (sync index, fetch session, session reviewed…)
    // is forwarded verbatim; the relay cannot read it.
    device.send(requestFrame(1));
    expect(await hostMessages.nextFrame("request")).toEqual(
      expect.objectContaining({ deviceID, sequence: 1, kind: "request", bodyBytes: 24 }),
    );

    // A request without a sealed body is rejected as an invalid frame, not forwarded.
    device.send(routingFrame(2, hostID, deviceID, { kind: "request" }, new Uint8Array()));
    const deviceMessages = collectMessages(device);
    expect(await deviceMessages.nextFrame("error")).toEqual(expect.objectContaining({ code: "invalid_frame" }));

    // Text on a routing socket is not a frame: the socket closes.
    const textSocket = await openSocket("device", deviceToken, deviceID);
    const textClosed = new Promise<number>((resolve) => textSocket.addEventListener("close", (event) => resolve(event.code)));
    textSocket.send(JSON.stringify({ version: { major: 1, minor: 6 }, hostID, deviceID, sequence: 3, kind: "request" }));
    expect(await textClosed).toBe(4004);

    // Devices cannot publish data frames (or the retired hello/ack/attention kinds).
    for (const kind of ["data", "hello", "ack", "attention"]) {
      const socket = await openSocket("device", deviceToken, deviceID);
      const closed = new Promise<number>((resolve) => socket.addEventListener("close", (event) => resolve(event.code)));
      socket.send(routingFrame(3, hostID, deviceID, { kind }));
      expect(await closed).toBe(1008);
    }
    host.close();
    device.close();
  });

  it("delivers a host frame burst in order and reports reused sequences with the channel cursor", async () => {
    await registerHost();
    const deviceToken = await pairDevice(hostID, hostSecret, deviceID);

    const host = await openSocket("host", hostSecret);
    const hostMessages = collectMessages(host);
    const device = await openSocket("device", deviceToken, deviceID);
    const deviceMessages = collectMessages(device);

    host.send(routingFrame(1));
    host.send(routingFrame(2));
    host.send(routingFrame(3));
    expect(await deviceMessages.nextFrame("data")).toEqual(expect.objectContaining({ sequence: 1, bodyBytes: 24 }));
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
    const firstToken = await pairDevice(multiHostID, multiSecret, firstID);
    const secondToken = await pairDevice(multiHostID, multiSecret, secondID);
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
    const deviceToken = await pairDevice(presenceHostID, presenceSecret, presenceDeviceID);
    const host = await openSocket("host", presenceSecret, undefined, presenceHostID);
    const device = await openSocket("device", deviceToken, presenceDeviceID, presenceHostID);
    const messages = collectMessages(device);

    expect(await messages.nextFrame("presence")).toEqual(expect.objectContaining({ online: true }));
    host.close(1000, "test complete");
    expect(await messages.nextFrame("presence")).toEqual(expect.objectContaining({ online: false }));
    device.close();
  });
});

describe("relay host notices and sequence floors", () => {
  it("tells the host when a device row changes", async () => {
    const { id, secret } = await freshHost("notice");
    const noticeDeviceID = "device-notice-0001";
    // Pairing runs with the helper's own host socket; this host connects after.
    const deviceToken = await pairDevice(id, secret, noticeDeviceID);
    const host = await openSocket("host", secret, undefined, id);
    const hostMessages = collectMessages(host);

    const tokenResponse = await SELF.fetch(`https://example.com/v1/hosts/${id}/devices/${noticeDeviceID}/push-token`, {
      method: "PUT",
      headers: authHeaders(deviceToken),
      body: JSON.stringify({ token: "a".repeat(64), environment: "development" }),
    });
    expect(tokenResponse.status).toBe(204);
    expect(await hostMessages.nextFrame("devices_changed")).toEqual(expect.objectContaining({ reason: "push_token" }));

    const revoked = await SELF.fetch(`https://example.com/v1/hosts/${id}/devices/${noticeDeviceID}`, {
      method: "DELETE",
      headers: authHeaders(secret),
    });
    expect(revoked.status).toBe(204);
    expect(await hostMessages.nextFrame("devices_changed")).toEqual(expect.objectContaining({ reason: "revoked" }));
    host.close();
  });

  it("takes the first frame of a channel as the floor and refuses only reuse after it", async () => {
    const { id, secret } = await freshHost("floor");
    const floorDeviceID = "device-floor-0001";
    const deviceToken = await pairDevice(id, secret, floorDeviceID);
    const host = await openSocket("host", secret, undefined, id);
    const hostMessages = collectMessages(host);
    const device = await openSocket("device", deviceToken, floorDeviceID, id);
    const deviceMessages = collectMessages(device);

    // A channel whose cursor this object never saw starts wherever the host is.
    host.send(routingFrame(900, id, floorDeviceID));
    expect(await deviceMessages.nextFrame("data")).toEqual(expect.objectContaining({ sequence: 900 }));
    host.send(routingFrame(900, id, floorDeviceID));
    expect(await hostMessages.nextFrame("error")).toEqual(
      expect.objectContaining({ code: "non_monotonic_sequence", sequence: 900, lastSequence: 900, deviceID: floorDeviceID }),
    );
    host.send(routingFrame(901, id, floorDeviceID));
    expect(await deviceMessages.nextFrame("data")).toEqual(expect.objectContaining({ sequence: 901 }));
    host.close();
    device.close();
  });
});
