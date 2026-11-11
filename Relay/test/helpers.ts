import { SELF } from "cloudflare:test";
import { expect } from "vitest";
import { encodeBinaryFrame, parseBinaryFrame } from "../src/protocol";

export const hostID = "host-test-000001";
export const hostSecret = "host-secret-that-is-long-enough-for-testing-000001";
export const deviceID = "device-test-0001";

export interface PairingFixture {
  sessionID: string;
  code: string;
  commit: string;
  hostPublicKey: string;
}

let sourceCounter = 0;

/**
 * Storage persists across the tests in a file, so per-source rate limits
 * would otherwise accumulate: every unrelated call comes from a fresh address.
 */
export function uniqueSource(): string {
  sourceCounter += 1;
  return `10.${Math.floor(sourceCounter / 65536) % 256}.${Math.floor(sourceCounter / 256) % 256}.${sourceCounter % 256}`;
}

export async function registerHost(id = hostID, secret = hostSecret): Promise<void> {
  const response = await SELF.fetch(`https://example.com/v1/hosts/${id}`, {
    method: "PUT",
    headers: { "content-type": "application/json", "cf-connecting-ip": uniqueSource() },
    body: JSON.stringify({ hostSecret: secret }),
  });
  expect(response.status).toBe(200);
}

/** A host ID and secret nobody else in the file uses, already registered. */
export async function freshHost(label: string): Promise<{ id: string; secret: string }> {
  const id = `host-${label}-${String(Date.now() % 1_000_000).padStart(6, "0")}`;
  const secret = `host-secret-that-is-long-enough-for-${label}-000001`;
  await registerHost(id, secret);
  return { id, secret };
}

export async function createPairingSession(
  id: string,
  secret: string,
  overrides: Record<string, unknown> = {},
): Promise<PairingFixture> {
  const commit = `commit-${id}-0000000000000000000000`;
  const hostPublicKey = `host-public-key-${id}-00000000000000`;
  const response = await SELF.fetch(`https://example.com/v1/hosts/${id}/pairing-sessions`, {
    method: "POST",
    headers: authHeaders(secret),
    body: JSON.stringify({
      commit,
      hostPublicKey,
      hostName: "Test Mac",
      expiresAt: new Date(Date.now() + 60_000).toISOString(),
      ...overrides,
    }),
  });
  expect(response.status).toBe(201);
  const body = await response.json<{ sessionID: string; code: string; expiresAt: string }>();
  return { sessionID: body.sessionID, code: body.code, commit, hostPublicKey };
}

export async function claimCode(code: string, sourceIP = uniqueSource()): Promise<Response> {
  return SELF.fetch("https://example.com/v1/pairing/claim", {
    method: "POST",
    headers: { "content-type": "application/json", "cf-connecting-ip": sourceIP },
    body: JSON.stringify({ code }),
  });
}

export async function submitDevice(
  id: string,
  sessionID: string,
  submitDeviceID: string,
  overrides: Record<string, unknown> = {},
): Promise<Response> {
  return SELF.fetch(`https://example.com/v1/hosts/${id}/pairing-sessions/${sessionID}/device`, {
    method: "POST",
    headers: authHeaders(sessionID),
    body: JSON.stringify({
      deviceID: submitDeviceID,
      deviceName: `${submitDeviceID} iPhone`,
      devicePublicKey: `public-key-${submitDeviceID}-000000000000`,
      ...overrides,
    }),
  });
}

export async function reveal(id: string, secret: string, sessionID: string): Promise<Response> {
  return SELF.fetch(`https://example.com/v1/hosts/${id}/pairing-sessions/${sessionID}/reveal`, {
    method: "POST",
    headers: authHeaders(secret),
    body: JSON.stringify({ hostNonce: `host-nonce-${sessionID.slice(0, 8)}-0000000000000000` }),
  });
}

export async function decide(id: string, secret: string, sessionID: string, approved: boolean): Promise<Response> {
  return SELF.fetch(`https://example.com/v1/hosts/${id}/pairing-sessions/${sessionID}/decision`, {
    method: "POST",
    headers: authHeaders(secret),
    body: JSON.stringify({ approved }),
  });
}

export async function readSession(id: string, sessionID: string, bearer = sessionID): Promise<Response> {
  return SELF.fetch(`https://example.com/v1/hosts/${id}/pairing-sessions/${sessionID}`, {
    headers: authHeaders(bearer),
  });
}

export async function cancelSession(id: string, sessionID: string, bearer: string): Promise<Response> {
  return SELF.fetch(`https://example.com/v1/hosts/${id}/pairing-sessions/${sessionID}`, {
    method: "DELETE",
    headers: authHeaders(bearer),
  });
}

/**
 * Runs the whole v2 flow for one device and returns its token. A temporary
 * host socket is open while the device submits (the relay refuses otherwise)
 * and is closed again before returning.
 */
export async function pairDevice(pairHostID: string, secret: string, pairDeviceID: string): Promise<string> {
  const session = await createPairingSession(pairHostID, secret);
  const claimed = await claimCode(session.code);
  expect(claimed.status).toBe(200);
  const host = await openSocket("host", secret, undefined, pairHostID);
  const hostMessages = collectMessages(host);
  expect((await submitDevice(pairHostID, session.sessionID, pairDeviceID)).status).toBe(200);
  await hostMessages.nextFrame("pairing_device");
  expect((await reveal(pairHostID, secret, session.sessionID)).status).toBe(200);
  expect((await decide(pairHostID, secret, session.sessionID, true)).status).toBe(200);
  const read = await readSession(pairHostID, session.sessionID);
  expect(read.status).toBe(200);
  const body = await read.json<{ state: string; deviceToken?: string }>();
  expect(body.state).toBe("approved");
  if (!body.deviceToken) throw new Error("Approved session has no device token.");
  host.close(1000, "pairing helper done");
  return body.deviceToken;
}

export function authHeaders(token: string): Record<string, string> {
  return {
    authorization: `Bearer ${token}`,
    "content-type": "application/json",
  };
}

export async function openSocket(
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

/** One binary routing frame: `u32 BE header length ‖ header JSON ‖ body`. */
export function routingFrame(
  sequence: number,
  frameHostID = hostID,
  frameDeviceID = deviceID,
  overrides: Record<string, unknown> = {},
  body: Uint8Array = new TextEncoder().encode("opaque-encrypted-payload"),
): ArrayBuffer {
  return encodeBinaryFrame({
    version: { major: 1, minor: 6 },
    hostID: frameHostID,
    deviceID: frameDeviceID,
    sequence,
    kind: "data",
    nonce: "AAECAwQFBgcICQoL",
    ...overrides,
  }, body);
}

/** A device's sealed request, same framing, `kind: "request"`. */
export function requestFrame(sequence: number, overrides: Record<string, unknown> = {}): ArrayBuffer {
  return routingFrame(sequence, hostID, deviceID, { kind: "request", ...overrides });
}

/**
 * Queues everything a socket receives: JSON text as parsed, binary frames as
 * their decoded header plus `bytes` (the whole message) and `bodyBytes`.
 */
export function collectMessages(socket: WebSocket): { nextFrame: (kind: string) => Promise<Record<string, unknown>> } {
  const queue: Array<Record<string, unknown>> = [];
  const waiters: Array<(value: Record<string, unknown>) => void> = [];
  // Binary arrives as a Blob on the client end; decoding it is async, so
  // messages are handed over through one chain to keep their order.
  let chain: Promise<void> = Promise.resolve();
  socket.addEventListener("message", (event) => {
    const data: unknown = event.data;
    chain = chain.then(async () => {
      let value: Record<string, unknown>;
      if (typeof data === "string") {
        value = JSON.parse(data) as Record<string, unknown>;
      } else {
        const buffer = await toArrayBuffer(data);
        value = { ...parseBinaryFrame(buffer), bytes: buffer.byteLength };
      }
      const waiter = waiters.shift();
      if (waiter) waiter(value); else queue.push(value);
    });
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

async function toArrayBuffer(data: unknown): Promise<ArrayBuffer> {
  if (data instanceof Blob) return data.arrayBuffer();
  if (ArrayBuffer.isView(data)) {
    return data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) as ArrayBuffer;
  }
  if (typeof data === "object" && data !== null && "byteLength" in data) {
    return data as ArrayBuffer;
  }
  throw new Error(`Unexpected message type: ${typeof data}`);
}
