import { elapsedMs, loggerForEnv, traceID, type Logger } from "./log";
import { isValidIdentifier, parsePairingClaim, readLimitedJSON, RequestValidationError } from "./protocol";
import { sourceBucket } from "./rate-limit";

export { HostRelay } from "./host-relay";
export { PairingDirectory } from "./pairing-directory";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const log = loggerForEnv(env, "http", { trace: traceID(request) });
    const startedAt = Date.now();
    const url = new URL(request.url);
    const route = routeName(request.method, url.pathname);
    try {
      const response = await dispatch(request, env, url, log);
      // One line per request at the edge: route, status, duration — the
      // Durable Object logs what it did with the request.
      log.info("http_request", { method: request.method, route, status: response.status, ms: elapsedMs(startedAt) });
      return response;
    } catch (error) {
      log.error("http_request_failed", { method: request.method, route, ms: elapsedMs(startedAt), error });
      throw error;
    }
  },
} satisfies ExportedHandler<Env>;

async function dispatch(request: Request, env: Env, url: URL, log: Logger): Promise<Response> {
  // Every credential on this API is a bearer token: plain HTTP would put it
  // on the wire in clear. the edge answers http:// too, so refuse it here;
  // only loopback (wrangler dev) is exempt.
  if (url.protocol !== "https:" && !isLoopbackHost(url.hostname)) {
    log.warn("https_required", { protocol: url.protocol });
    return json({ error: "https_required" }, 403);
  }
  // Edge rate limit per client address (IPv6 per /64), before any Durable
  // Object is touched: the object-level limits only start counting once a
  // request has already cost an object invocation — and, for a random host
  // ID, an object creation. Cloudflare sets `cf-connecting-ip` on every
  // request that crosses the edge; its absence means a local/internal caller.
  const client = request.headers.get("cf-connecting-ip");
  if (client !== null) {
    const { success } = await env.RATE_LIMITER.limit({ key: sourceBucket(client) });
    if (!success) {
      log.warn("edge_rate_limited", { route: routeName(request.method, url.pathname) });
      return json({ error: "rate_limited" }, 429);
    }
  }

  if (request.method === "GET" && url.pathname === "/health") {
    return Response.json({ status: "ok", protocolMajor: 1 }, {
      headers: { "cache-control": "no-store" },
    });
  }
  if (request.method === "POST" && url.pathname === "/v1/pairing/claim") {
    return claimPairingCode(request, env, log);
  }

  const segments = url.pathname.split("/").filter(Boolean);
  const hostID = segments[2];
  if (segments[0] !== "v1" || segments[1] !== "hosts" || !hostID || !isValidIdentifier(hostID)) {
    return Response.json({ error: "not_found" }, { status: 404 });
  }

  const stub = env.HOST_RELAY.getByName(hostID);
  return stub.fetch(request);
}

/**
 * The path with its variable segments replaced, so a log line names the
 * endpoint without naming a host, device or (capability-bearing) session id.
 */
export function routeName(method: string, pathname: string): string {
  const segments = pathname.split("/").filter(Boolean);
  if (segments[0] === "v1" && segments[1] === "hosts" && segments[2]) {
    const rest = segments.slice(3);
    const named = [
      "v1", "hosts", ":host",
      ...rest.map((segment, index) => {
        const previous = rest[index - 1];
        if (previous === "pairing-sessions" || previous === "devices") return ":id";
        return segment;
      }),
    ];
    return `${method} /${named.join("/")}`;
  }
  return `${method} ${pathname}`;
}

/**
 * The iPhone's entry point: a pairing code names a Mac and one of its pairing
 * sessions. The directory spends the code; the Mac's relay moves the session
 * to `claimed` and hands back what the device needs to continue.
 */
async function claimPairingCode(request: Request, env: Env, http: Logger): Promise<Response> {
  const log = http.withCategory("pairing");
  let code: string;
  try {
    code = parsePairingClaim(await readLimitedJSON(request)).code;
  } catch (error) {
    if (error instanceof RequestValidationError) {
      log.warn("pairing_claim_invalid_request", { error });
      return json({ error: "invalid_request", message: error.message }, 400);
    }
    throw error;
  }
  const directory = env.PAIRING_DIRECTORY.getByName("directory");
  const hit = await directory.claim(code, sourceBucket(request.headers.get("cf-connecting-ip") ?? "local"));
  // The code is never logged; the outcome is what a brute-force attempt
  // shows up as (`rate_limited` / `invalid` runs from one source).
  if (hit.outcome === "rate_limited") {
    log.warn("pairing_claim_rate_limited");
    return json({ error: "rate_limited" }, 429);
  }
  if (hit.outcome === "invalid") {
    log.info("pairing_claim_rejected", { reason: "invalid_or_expired_code" });
    return json({ error: "invalid_or_expired_code" }, 404);
  }

  const host = env.HOST_RELAY.getByName(hit.hostID);
  const session = await host.claimPairingSession(hit.sessionID);
  if (session === null) {
    log.info("pairing_claim_rejected", { reason: "session_not_offered", hostID: hit.hostID });
    return json({ error: "invalid_or_expired_code" }, 404);
  }
  log.info("pairing_claimed", { hostID: hit.hostID });
  return json({
    sessionID: hit.sessionID,
    hostID: hit.hostID,
    hostName: session.hostName,
    commit: session.commit,
  });
}

/** `wrangler dev` serves plain HTTP on loopback; nothing else may. */
function isLoopbackHost(hostname: string): boolean {
  return hostname === "localhost" || hostname === "127.0.0.1" || hostname === "[::1]";
}

function json(value: unknown, status = 200): Response {
  return Response.json(value, {
    status,
    headers: { "cache-control": "no-store" },
  });
}
