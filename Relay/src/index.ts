import { isValidIdentifier, parsePairingClaim, readLimitedJSON, RequestValidationError } from "./protocol";

export { HostRelay } from "./host-relay";
export { PairingDirectory } from "./pairing-directory";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/health") {
      return Response.json({ status: "ok", protocolMajor: 1 }, {
        headers: { "cache-control": "no-store" },
      });
    }
    if (request.method === "POST" && url.pathname === "/v1/pairing/claim") {
      return claimPairingCode(request, env);
    }

    const segments = url.pathname.split("/").filter(Boolean);
    const hostID = segments[2];
    if (segments[0] !== "v1" || segments[1] !== "hosts" || !hostID || !isValidIdentifier(hostID)) {
      return Response.json({ error: "not_found" }, { status: 404 });
    }

    const stub = env.HOST_RELAY.getByName(hostID);
    return stub.fetch(request);
  },
} satisfies ExportedHandler<Env>;

/**
 * The iPhone's entry point: a pairing code names a Mac and one of its pairing
 * sessions. The directory spends the code; the Mac's relay moves the session
 * to `claimed` and hands back what the device needs to continue.
 */
async function claimPairingCode(request: Request, env: Env): Promise<Response> {
  let code: string;
  try {
    code = parsePairingClaim(await readLimitedJSON(request)).code;
  } catch (error) {
    if (error instanceof RequestValidationError) {
      return json({ error: "invalid_request", message: error.message }, 400);
    }
    throw error;
  }
  const directory = env.PAIRING_DIRECTORY.getByName("directory");
  const hit = await directory.claim(code, request.headers.get("cf-connecting-ip") ?? "local");
  if (hit.outcome === "rate_limited") return json({ error: "rate_limited" }, 429);
  if (hit.outcome === "invalid") return json({ error: "invalid_or_expired_code" }, 404);

  const host = env.HOST_RELAY.getByName(hit.hostID);
  const session = await host.claimPairingSession(hit.sessionID);
  if (session === null) return json({ error: "invalid_or_expired_code" }, 404);
  return json({
    sessionID: hit.sessionID,
    hostID: hit.hostID,
    hostName: session.hostName,
    commit: session.commit,
  });
}

function json(value: unknown, status = 200): Response {
  return Response.json(value, {
    status,
    headers: { "cache-control": "no-store" },
  });
}
