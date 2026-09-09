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
    // otherwise instantiate a Durable Object per request. Which address maps
    // to which bucket (IPv6 by /64) is covered in rate-limit.test.ts — going
    // through the limiter for that costs a second trip of 300+ requests.
    const limited = await hammerUntilLimited("198.51.100.250");
    expect(await limited.json()).toEqual({ error: "rate_limited" });

    // A different address is unaffected.
    const other = await SELF.fetch("https://example.com/health", { headers: { "cf-connecting-ip": "198.51.100.251" } });
    expect(other.status).toBe(200);
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
