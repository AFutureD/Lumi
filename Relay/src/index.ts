import { isValidIdentifier } from "./protocol";

export { HostRelay } from "./host-relay";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/health") {
      return Response.json({ status: "ok", protocolMajor: 1 }, {
        headers: { "cache-control": "no-store" },
      });
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
