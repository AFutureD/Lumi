import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

describe("edge gates", () => {
  it("refuses plain HTTP except on loopback", async () => {
    const refused = await SELF.fetch("http://example.com/health");
    expect(refused.status).toBe(403);
    expect(await refused.json()).toEqual({ error: "https_required" });

    const refusedHost = await SELF.fetch("http://example.com/v1/hosts/host-http-000001", {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ hostSecret: "host-secret-that-is-long-enough-for-testing-000001" }),
    });
    expect(refusedHost.status).toBe(403);

    for (const origin of ["http://localhost:8787", "http://127.0.0.1:8787", "http://[::1]:8787", "https://example.com"]) {
      const allowed = await SELF.fetch(`${origin}/health`);
      expect(allowed.status, origin).toBe(200);
    }
  });

  it("rate limits one client address at the edge before any object is reached", { timeout: 60_000 }, async () => {
    // Limit is 300/min per bucket (wrangler.jsonc); a bogus host path would
    // otherwise instantiate a Durable Object per request.
    const limited = await hammerUntilLimited("198.51.100.250");
    expect(await limited.json()).toEqual({ error: "rate_limited" });

    // A different address is unaffected.
    const other = await SELF.fetch("https://example.com/health", { headers: { "cf-connecting-ip": "198.51.100.251" } });
    expect(other.status).toBe(200);
  });

  it("buckets IPv6 clients by /64 at the edge", { timeout: 60_000 }, async () => {
    // Trip the bucket from one address; a sibling in the same /64 must then
    // be limited too, while a neighbouring /64 stays clean. An epoch reset
    // between the trip and the probe clears the bucket, so trip again.
    for (let round = 0; round < 3; round += 1) {
      await hammerUntilLimited("2001:db8:ed9e:1::1");
      const sibling = await SELF.fetch("https://example.com/health", { headers: { "cf-connecting-ip": "2001:db8:ed9e:1:ffff::9" } });
      if (sibling.status === 429) {
        const neighbour = await SELF.fetch("https://example.com/health", { headers: { "cf-connecting-ip": "2001:db8:ed9e:2::1" } });
        expect(neighbour.status).toBe(200);
        return;
      }
    }
    throw new Error("sibling address in the same /64 was never rate limited");
  });
});

// The simulated limiter counts within wall-clock epochs, so a fixed-length
// request loop can straddle an epoch boundary and never trip; how many 200s
// precede the 429 is timing-dependent, only the 429 itself is guaranteed.
async function hammerUntilLimited(address: string): Promise<Response> {
  const headers = { "cf-connecting-ip": address };
  for (let attempt = 0; attempt < 1000; attempt += 1) {
    const response = await SELF.fetch("https://example.com/health", { headers });
    if (response.status === 429) return response;
    expect(response.status).toBe(200);
  }
  throw new Error(`rate limiter never returned 429 for ${address} within 1000 requests`);
}
