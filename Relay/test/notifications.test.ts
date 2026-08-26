import { SELF } from "cloudflare:test";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { authHeaders, freshHost, pairDevice, uniqueSource } from "./helpers";

const APNS_TOKEN = "a".repeat(64);

interface RecordedPush {
  url: URL;
  headers: Headers;
  body: Record<string, unknown>;
}

// `SELF` runs in the same isolate as the tests, so replacing the global
// `fetch` intercepts the Durable Object's outbound APNs calls. Everything
// that is not APNs falls through to the real fetch.
let recorded: RecordedPush[] = [];
let apnsResponse: () => Response = okResponse;
const realFetch = globalThis.fetch;

function okResponse(): Response {
  return new Response(null, { status: 200, headers: { "apns-id": "apns-id-test-0001" } });
}

beforeAll(() => {
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const request = new Request(input, init);
    const url = new URL(request.url);
    if (!url.hostname.endsWith("push.apple.com")) return realFetch(input, init);
    recorded.push({ url, headers: request.headers, body: JSON.parse(await request.text()) as Record<string, unknown> });
    return apnsResponse();
  });
});

afterAll(() => {
  globalThis.fetch = realFetch;
});

beforeEach(() => {
  recorded = [];
  apnsResponse = okResponse;
});

async function putPushToken(
  hostID: string,
  deviceID: string,
  bearer: string,
  body: Record<string, unknown> = { token: APNS_TOKEN, environment: "development" },
): Promise<Response> {
  return SELF.fetch(`https://example.com/v1/hosts/${hostID}/devices/${deviceID}/push-token`, {
    method: "PUT",
    headers: { ...authHeaders(bearer), "cf-connecting-ip": uniqueSource() },
    body: JSON.stringify(body),
  });
}

async function postNotification(
  hostID: string,
  secret: string,
  body: Record<string, unknown>,
): Promise<Response> {
  return SELF.fetch(`https://example.com/v1/hosts/${hostID}/notifications`, {
    method: "POST",
    headers: { ...authHeaders(secret), "cf-connecting-ip": uniqueSource() },
    body: JSON.stringify(body),
  });
}

async function results(response: Response): Promise<Array<{ deviceID: string; status: string }>> {
  expect(response.status).toBe(200);
  return (await response.json<{ results: Array<{ deviceID: string; status: string }> }>()).results;
}

describe("push token registration", () => {
  it("stores the token for a paired device and rejects bad bearers", async () => {
    const host = await freshHost("pt-auth");
    const deviceID = "device-pt-auth-01";
    const deviceToken = await pairDevice(host.id, host.secret, deviceID);

    expect((await putPushToken(host.id, deviceID, "not-the-token")).status).toBe(401);
    expect((await putPushToken(host.id, deviceID, host.secret)).status).toBe(401);
    expect((await putPushToken(host.id, deviceID, deviceToken)).status).toBe(204);
  });

  it("rejects malformed tokens and environments", async () => {
    const host = await freshHost("pt-shape");
    const deviceID = "device-pt-shape-1";
    const deviceToken = await pairDevice(host.id, host.secret, deviceID);

    const badToken = await putPushToken(host.id, deviceID, deviceToken, {
      token: "not hex!", environment: "development",
    });
    expect(badToken.status).toBe(400);
    const badEnvironment = await putPushToken(host.id, deviceID, deviceToken, {
      token: APNS_TOKEN, environment: "staging",
    });
    expect(badEnvironment.status).toBe(400);
  });

  it("clears the token on DELETE", async () => {
    const host = await freshHost("pt-clear");
    const deviceID = "device-pt-clear-1";
    const deviceToken = await pairDevice(host.id, host.secret, deviceID);
    expect((await putPushToken(host.id, deviceID, deviceToken)).status).toBe(204);

    const cleared = await SELF.fetch(`https://example.com/v1/hosts/${host.id}/devices/${deviceID}/push-token`, {
      method: "DELETE",
      headers: { ...authHeaders(deviceToken), "cf-connecting-ip": uniqueSource() },
    });
    expect(cleared.status).toBe(204);

    const sent = await postNotification(host.id, host.secret, { title: "t", subtitle: "Completed" });
    expect(await results(sent)).toEqual([{ deviceID, status: "no_token" }]);
    expect(recorded).toHaveLength(0);
  });
});

describe("notification send", () => {
  it("requires the host secret", async () => {
    const host = await freshHost("nt-auth");
    const response = await postNotification(host.id, "wrong-secret", { title: "t", subtitle: "Completed" });
    expect(response.status).toBe(401);
  });

  it("pushes to the sandbox for a development token and shapes the request", async () => {
    const host = await freshHost("nt-send");
    const deviceID = "device-nt-send-01";
    const deviceToken = await pairDevice(host.id, host.secret, deviceID);
    expect((await putPushToken(host.id, deviceID, deviceToken)).status).toBe(204);

    const response = await postNotification(host.id, host.secret, {
      title: "Fix relay tests",
      subtitle: "Completed",
      sessionID: "session-nt-0001",
      collapseID: "session-nt-0001",
    });
    expect(await results(response)).toEqual([{ deviceID, status: "sent" }]);

    expect(recorded).toHaveLength(1);
    const push = recorded[0];
    if (!push) throw new Error("missing recorded push");
    expect(push.url.hostname).toBe("api.sandbox.push.apple.com");
    expect(push.url.pathname).toBe(`/3/device/${APNS_TOKEN}`);
    expect(push.headers.get("apns-topic")).toBe("app.huanan.lumi");
    expect(push.headers.get("apns-push-type")).toBe("alert");
    expect(push.headers.get("apns-collapse-id")).toBe("session-nt-0001");
    expect(push.headers.get("authorization")).toMatch(/^bearer ey/u);
    expect(push.body).toEqual({
      aps: {
        alert: { title: "Fix relay tests", subtitle: "Completed" },
        sound: "default",
        "thread-id": "session-nt-0001",
      },
      lumi: { hostID: host.id, sessionID: "session-nt-0001" },
    });
  });

  it("pushes to the production endpoint for a production token", async () => {
    const host = await freshHost("nt-prod");
    const deviceID = "device-nt-prod-01";
    const deviceToken = await pairDevice(host.id, host.secret, deviceID);
    expect((await putPushToken(host.id, deviceID, deviceToken, {
      token: APNS_TOKEN, environment: "production",
    })).status).toBe(204);

    const response = await postNotification(host.id, host.secret, { title: "t", subtitle: "Completed" });
    expect(await results(response)).toEqual([{ deviceID, status: "sent" }]);
    expect(recorded[0]?.url.hostname).toBe("api.push.apple.com");
  });

  it("drops the token on APNs 410 and reports no_token afterwards", async () => {
    const host = await freshHost("nt-gone");
    const deviceID = "device-nt-gone-01";
    const deviceToken = await pairDevice(host.id, host.secret, deviceID);
    expect((await putPushToken(host.id, deviceID, deviceToken)).status).toBe(204);

    apnsResponse = () => Response.json({ reason: "Unregistered" }, { status: 410 });
    const first = await postNotification(host.id, host.secret, { title: "t", subtitle: "Completed" });
    expect(await results(first)).toEqual([{ deviceID, status: "unregistered" }]);

    const second = await postNotification(host.id, host.secret, { title: "t", subtitle: "Completed" });
    expect(await results(second)).toEqual([{ deviceID, status: "no_token" }]);
    expect(recorded).toHaveLength(1);
  });

  it("reports failed and keeps the token when the APNs connection itself dies", async () => {
    const host = await freshHost("nt-neterr");
    const deviceID = "device-nt-neterr1";
    const deviceToken = await pairDevice(host.id, host.secret, deviceID);
    expect((await putPushToken(host.id, deviceID, deviceToken)).status).toBe(204);

    apnsResponse = () => { throw new TypeError("fetch failed: connection reset"); };
    const first = await postNotification(host.id, host.secret, { title: "t", subtitle: "Completed" });
    expect(await results(first)).toEqual([{ deviceID, status: "failed" }]);

    apnsResponse = okResponse;
    const second = await postNotification(host.id, host.secret, { title: "t", subtitle: "Completed" });
    expect(await results(second)).toEqual([{ deviceID, status: "sent" }]);
  });

  it("keeps the token on a transient APNs failure", async () => {
    const host = await freshHost("nt-flaky");
    const deviceID = "device-nt-flaky-1";
    const deviceToken = await pairDevice(host.id, host.secret, deviceID);
    expect((await putPushToken(host.id, deviceID, deviceToken)).status).toBe(204);

    apnsResponse = () => Response.json({ reason: "InternalServerError" }, { status: 500 });
    const first = await postNotification(host.id, host.secret, { title: "t", subtitle: "Completed" });
    expect(await results(first)).toEqual([{ deviceID, status: "failed" }]);

    apnsResponse = okResponse;
    const second = await postNotification(host.id, host.secret, { title: "t", subtitle: "Completed" });
    expect(await results(second)).toEqual([{ deviceID, status: "sent" }]);
  });

  it("reports revoked devices and clears their tokens on revocation", async () => {
    const host = await freshHost("nt-revoke");
    const deviceID = "device-nt-rvk-01";
    const deviceToken = await pairDevice(host.id, host.secret, deviceID);
    expect((await putPushToken(host.id, deviceID, deviceToken)).status).toBe(204);

    const revoked = await SELF.fetch(`https://example.com/v1/hosts/${host.id}/devices/${deviceID}`, {
      method: "DELETE",
      headers: { ...authHeaders(host.secret), "cf-connecting-ip": uniqueSource() },
    });
    expect(revoked.status).toBe(204);

    // Broadcast skips the revoked row; addressing it directly names the state.
    const broadcast = await postNotification(host.id, host.secret, { title: "t", subtitle: "Completed" });
    expect(await results(broadcast)).toEqual([]);
    const direct = await postNotification(host.id, host.secret, {
      title: "t", subtitle: "Completed", deviceIDs: [deviceID],
    });
    expect(await results(direct)).toEqual([{ deviceID, status: "revoked" }]);
    expect(recorded).toHaveLength(0);
  });

  it("addresses only the named devices when deviceIDs is present", async () => {
    // The daemon names its key-verified devices on every send; a paired
    // device the Mac never verified stays outside the list and gets nothing,
    // even with a registered token.
    const host = await freshHost("nt-target");
    const verifiedID = "device-nt-tgt-01";
    const unverifiedID = "device-nt-tgt-02";
    const verifiedToken = await pairDevice(host.id, host.secret, verifiedID);
    const unverifiedToken = await pairDevice(host.id, host.secret, unverifiedID);
    expect((await putPushToken(host.id, verifiedID, verifiedToken)).status).toBe(204);
    expect((await putPushToken(host.id, unverifiedID, unverifiedToken, {
      token: "b".repeat(64), environment: "development",
    })).status).toBe(204);

    const response = await postNotification(host.id, host.secret, {
      title: "t", subtitle: "Completed", deviceIDs: [verifiedID],
    });
    expect(await results(response)).toEqual([{ deviceID: verifiedID, status: "sent" }]);
    expect(recorded).toHaveLength(1);
    expect(recorded[0]?.url.pathname).toBe(`/3/device/${APNS_TOKEN}`);
  });

  it("reports unknown device IDs as revoked", async () => {
    const host = await freshHost("nt-unknown");
    const response = await postNotification(host.id, host.secret, {
      title: "t", subtitle: "Completed", deviceIDs: ["device-never-heard-of"],
    });
    expect(await results(response)).toEqual([{ deviceID: "device-never-heard-of", status: "revoked" }]);
  });

  it("rejects oversized text", async () => {
    const host = await freshHost("nt-size");
    expect((await postNotification(host.id, host.secret, { title: "t".repeat(121), subtitle: "Completed" })).status).toBe(400);
    expect((await postNotification(host.id, host.secret, { title: "t", subtitle: "s".repeat(61) })).status).toBe(400);
    expect((await postNotification(host.id, host.secret, { title: "t", subtitle: "Completed", collapseID: "bad collapse id" })).status).toBe(400);
  });
});
