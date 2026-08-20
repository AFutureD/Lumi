import { DurableObject } from "cloudflare:workers";
import { bearerToken, hashCredential, randomCredential, timingSafeStringEqual } from "./crypto";
import {
  MAX_WEBSOCKET_MESSAGE_BYTES,
  RequestValidationError,
  isRecord,
  parsePairingOffer,
  parsePairingRequest,
  parseRelayRoutingFrame,
  readLimitedJSON,
} from "./protocol";

interface SocketAttachment {
  role: "host" | "device";
  hostID: string;
  deviceID?: string;
  connectedAt: number;
}

interface DeviceRow {
  [key: string]: SqlStorageValue;
  id: string;
  name: string;
  public_key: string;
  token_hash: string;
  paired_at: number;
  revoked_at: number | null;
}

interface MetadataRow {
  [key: string]: SqlStorageValue;
  value: string;
}

interface PairingOfferRow {
  [key: string]: SqlStorageValue;
  challenge_hash: string;
  host_public_key: string;
  expires_at: number;
  consumed_at: number | null;
}

class RateLimitError extends Error {}

export class HostRelay extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    void this.ctx.blockConcurrencyWhile(() => {
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS metadata (
          key TEXT PRIMARY KEY NOT NULL,
          value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS devices (
          id TEXT PRIMARY KEY NOT NULL,
          name TEXT NOT NULL,
          public_key TEXT NOT NULL,
          token_hash TEXT NOT NULL,
          paired_at INTEGER NOT NULL,
          revoked_at INTEGER
        );
        CREATE TABLE IF NOT EXISTS pairing_offers (
          challenge_hash TEXT PRIMARY KEY NOT NULL,
          host_public_key TEXT NOT NULL,
          expires_at INTEGER NOT NULL,
          consumed_at INTEGER
        );
        CREATE TABLE IF NOT EXISTS rate_limits (
          key TEXT PRIMARY KEY NOT NULL,
          window_started_at INTEGER NOT NULL,
          count INTEGER NOT NULL
        );
      `);
      return Promise.resolve();
    });
  }

  override async fetch(request: Request): Promise<Response> {
    try {
      const url = new URL(request.url);
      const segments = url.pathname.split("/").filter(Boolean);
      const hostID = segments[2];
      if (segments[0] !== "v1" || segments[1] !== "hosts" || !hostID) {
        return json({ error: "not_found" }, 404);
      }

      if (request.method === "PUT" && segments.length === 3) {
        return await this.registerHost(request);
      }
      if (request.method === "POST" && segments[3] === "pairing-offers") {
        return await this.createPairingOffer(request, hostID);
      }
      if (request.method === "POST" && segments[3] === "pair") {
        return await this.pairDevice(request, hostID);
      }
      if (request.method === "GET" && segments[3] === "devices" && segments.length === 4) {
        return await this.listDevices(request);
      }
      if (request.method === "DELETE" && segments[3] === "devices" && segments[4]) {
        return await this.revokeDevice(request, segments[4]);
      }
      if (request.method === "GET" && segments[3] === "ws") {
        return await this.openWebSocket(request, hostID);
      }
      return json({ error: "not_found" }, 404);
    } catch (error) {
      if (error instanceof RequestValidationError) {
        return json({ error: "invalid_request", message: error.message }, 400);
      }
      if (error instanceof RateLimitError) {
        return json({ error: "rate_limited" }, 429);
      }
      console.error(JSON.stringify({ event: "relay_request_failed", error: String(error) }));
      return json({ error: "internal_error" }, 500);
    }
  }

  override webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): void {
    const attachment = this.attachment(ws);
    const byteLength = typeof message === "string"
      ? new TextEncoder().encode(message).byteLength
      : message.byteLength;
    if (byteLength > MAX_WEBSOCKET_MESSAGE_BYTES) {
      ws.close(1009, "message too large");
      return;
    }
    if (typeof message !== "string") {
      ws.close(1003, "routing frames must be JSON text");
      return;
    }

    try {
      const frame = parseRelayRoutingFrame(JSON.parse(message) as unknown);
      if (frame.hostID !== attachment.hostID) {
        ws.close(1008, "host mismatch");
        return;
      }
      if (attachment.role === "host") {
        this.handleHostFrame(frame, message);
      } else {
        this.handleDeviceFrame(attachment, frame, message, ws);
      }
    } catch (error) {
      ws.send(JSON.stringify({ type: "error", code: "invalid_frame" }));
      console.warn(JSON.stringify({ event: "invalid_frame", role: attachment.role, error: String(error) }));
    }
  }

  override webSocketClose(ws: WebSocket): void {
    const attachment = this.attachment(ws);
    const hasAnotherOpenHost = this.hostSockets().some(
      (candidate) => candidate !== ws && candidate.readyState === WebSocket.OPEN,
    );
    if (attachment.role === "host" && !hasAnotherOpenHost) {
      this.broadcastPresence(false);
    }
  }

  override webSocketError(ws: WebSocket): void {
    const attachment = this.attachment(ws);
    console.warn(JSON.stringify({ event: "websocket_error", role: attachment.role }));
  }

  private async registerHost(request: Request): Promise<Response> {
    await this.enforceRateLimit(request, "register", 10, 60_000);
    const input = await readLimitedJSON(request);
    if (!isRecord(input) || typeof input.hostSecret !== "string" || input.hostSecret.length < 32) {
      throw new RequestValidationError("A high-entropy hostSecret is required.");
    }
    const newHash = await hashCredential(input.hostSecret);
    const currentHash = this.metadata("host_token_hash");
    if (currentHash && !timingSafeStringEqual(currentHash, newHash)) {
      return json({ error: "unauthorized" }, 401);
    }
    if (!currentHash) this.setMetadata("host_token_hash", newHash);
    return json({ registered: true });
  }

  private async createPairingOffer(request: Request, hostID: string): Promise<Response> {
    if (!(await this.authorizeHost(request))) return json({ error: "unauthorized" }, 401);
    const offer = parsePairingOffer(await readLimitedJSON(request));
    const expiresAt = Date.parse(offer.expiresAt);
    if (!Number.isFinite(expiresAt) || expiresAt <= Date.now() || expiresAt > Date.now() + 10 * 60_000) {
      throw new RequestValidationError("Pairing offers must expire within ten minutes.");
    }
    const challengeHash = await hashCredential(offer.challenge);
    this.ctx.storage.sql.exec(
      `INSERT OR REPLACE INTO pairing_offers(challenge_hash, host_public_key, expires_at, consumed_at)
       VALUES(?, ?, ?, NULL)`,
      challengeHash,
      offer.hostPublicKey,
      expiresAt,
    );
    this.ctx.storage.sql.exec("DELETE FROM pairing_offers WHERE expires_at < ? OR consumed_at IS NOT NULL", Date.now());
    return json({ hostID, expiresAt: new Date(expiresAt).toISOString() }, 201);
  }

  private async pairDevice(request: Request, hostID: string): Promise<Response> {
    await this.enforceRateLimit(request, "pair", 20, 60_000);
    const pairing = parsePairingRequest(await readLimitedJSON(request));
    const challengeHash = await hashCredential(pairing.challenge);
    const offer = this.ctx.storage.sql.exec<PairingOfferRow>(
      `SELECT challenge_hash, host_public_key, expires_at, consumed_at
       FROM pairing_offers WHERE challenge_hash = ?`,
      challengeHash,
    ).toArray()[0];
    if (!offer || offer.consumed_at !== null || offer.expires_at <= Date.now()) {
      return json({ error: "invalid_or_expired_pairing_offer" }, 401);
    }

    const deviceToken = randomCredential();
    const tokenHash = await hashCredential(deviceToken);
    const pairedAt = Date.now();
    this.ctx.storage.sql.exec(
      `INSERT INTO devices(id, name, public_key, token_hash, paired_at, revoked_at)
       VALUES(?, ?, ?, ?, ?, NULL)
       ON CONFLICT(id) DO UPDATE SET
         name = excluded.name,
         public_key = excluded.public_key,
         token_hash = excluded.token_hash,
         paired_at = excluded.paired_at,
         revoked_at = NULL`,
      pairing.deviceID,
      pairing.deviceName,
      pairing.devicePublicKey,
      tokenHash,
      pairedAt,
    );
    this.ctx.storage.sql.exec(
      "UPDATE pairing_offers SET consumed_at = ? WHERE challenge_hash = ?",
      pairedAt,
      challengeHash,
    );

    return json({
      hostID,
      deviceID: pairing.deviceID,
      deviceToken,
      hostPublicKey: offer.host_public_key,
      pairedAt: new Date(pairedAt).toISOString(),
    }, 201);
  }

  private async listDevices(request: Request): Promise<Response> {
    if (!(await this.authorizeHost(request))) return json({ error: "unauthorized" }, 401);
    const devices = this.ctx.storage.sql.exec<DeviceRow>(
      `SELECT id, name, public_key, token_hash, paired_at, revoked_at
       FROM devices ORDER BY paired_at DESC`,
    ).toArray().map((device) => ({
      id: device.id,
      name: device.name,
      publicKey: device.public_key,
      pairedAt: new Date(device.paired_at).toISOString(),
      revokedAt: device.revoked_at === null ? null : new Date(device.revoked_at).toISOString(),
    }));
    return json({ devices });
  }

  private async revokeDevice(request: Request, deviceID: string): Promise<Response> {
    if (!(await this.authorizeHost(request))) return json({ error: "unauthorized" }, 401);
    this.ctx.storage.sql.exec(
      "UPDATE devices SET revoked_at = ? WHERE id = ?",
      Date.now(),
      deviceID,
    );
    for (const socket of this.ctx.getWebSockets(`device:${deviceID}`)) {
      socket.close(4003, "device revoked");
    }
    return new Response(null, { status: 204 });
  }

  private async openWebSocket(request: Request, hostID: string): Promise<Response> {
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return json({ error: "websocket_upgrade_required" }, 426);
    }
    const url = new URL(request.url);
    const role = url.searchParams.get("role");
    const deviceID = url.searchParams.get("deviceId") ?? undefined;

    if (role === "host") {
      if (!(await this.authorizeHost(request))) return json({ error: "unauthorized" }, 401);
    } else if (role === "device" && deviceID) {
      if (!(await this.authorizeDevice(request, deviceID))) return json({ error: "unauthorized" }, 401);
    } else {
      throw new RequestValidationError("Invalid WebSocket role.");
    }

    const [client, server] = Object.values(new WebSocketPair());
    if (!client || !server) throw new Error("WebSocketPair did not return both endpoints.");
    const attachment: SocketAttachment = {
      role,
      hostID,
      ...(deviceID === undefined ? {} : { deviceID }),
      connectedAt: Date.now(),
    };
    const tags = role === "host" ? ["role:host"] : ["role:device", `device:${deviceID}`];

    if (role === "host") {
      for (const existing of this.hostSockets()) existing.close(4001, "host connection replaced");
    }
    this.ctx.acceptWebSocket(server, tags);
    server.serializeAttachment(attachment);
    if (role === "host") {
      this.broadcastPresence(true);
    } else {
      server.send(JSON.stringify({ type: "presence", online: this.hostSockets().length > 0 }));
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  private handleHostFrame(frame: ReturnType<typeof parseRelayRoutingFrame>, raw: string): void {
    // Sequences belong to a paired Mac/iOS channel. Two devices may both send
    // sequence 1; sessions inside either channel never influence this cursor.
    const channelKey = `last_host_sequence:${frame.deviceID ?? "broadcast"}`;
    const lastSequence = Number(this.metadata(channelKey) ?? "-1");
    if (frame.sequence <= lastSequence) {
      for (const host of this.hostSockets()) {
        host.send(JSON.stringify({ type: "error", code: "non_monotonic_sequence", sequence: frame.sequence }));
      }
      return;
    }
    this.setMetadata(channelKey, String(frame.sequence));

    const targets = frame.deviceID
      ? this.ctx.getWebSockets(`device:${frame.deviceID}`)
      : this.deviceSockets();
    for (const target of targets) target.send(raw);
  }

  private handleDeviceFrame(
    attachment: SocketAttachment,
    frame: ReturnType<typeof parseRelayRoutingFrame>,
    raw: string,
    socket: WebSocket,
  ): void {
    if (frame.deviceID !== attachment.deviceID || (frame.kind !== "ack" && frame.kind !== "hello")) {
      socket.close(1008, "device is read-only");
      return;
    }
    // The relay keeps no replay buffer: hello and ack frames are forwarded
    // to the Mac verbatim, and a hello behind the channel sequence makes the
    // Mac resend every session followed by a fresh index.
    for (const host of this.hostSockets()) host.send(raw);
  }

  private async authorizeHost(request: Request): Promise<boolean> {
    const token = bearerToken(request);
    const expected = this.metadata("host_token_hash");
    if (!token || !expected) return false;
    return timingSafeStringEqual(await hashCredential(token), expected);
  }

  private async authorizeDevice(request: Request, deviceID: string): Promise<boolean> {
    const token = bearerToken(request);
    if (!token) return false;
    const device = this.ctx.storage.sql.exec<DeviceRow>(
      `SELECT id, name, public_key, token_hash, paired_at, revoked_at
       FROM devices WHERE id = ?`,
      deviceID,
    ).toArray()[0];
    if (!device || device.revoked_at !== null) return false;
    return timingSafeStringEqual(await hashCredential(token), device.token_hash);
  }

  private async enforceRateLimit(
    request: Request,
    action: string,
    limit: number,
    windowMilliseconds: number,
  ): Promise<void> {
    const source = request.headers.get("cf-connecting-ip") ?? "local";
    const key = `${action}:${await hashCredential(source)}`;
    const now = Date.now();
    const row = this.ctx.storage.sql.exec<{ window_started_at: number; count: number }>(
      "SELECT window_started_at, count FROM rate_limits WHERE key = ?",
      key,
    ).toArray()[0];
    if (!row || now - row.window_started_at >= windowMilliseconds) {
      this.ctx.storage.sql.exec(
        "INSERT OR REPLACE INTO rate_limits(key, window_started_at, count) VALUES(?, ?, 1)",
        key,
        now,
      );
      return;
    }
    if (row.count >= limit) throw new RateLimitError("Rate limit exceeded.");
    this.ctx.storage.sql.exec("UPDATE rate_limits SET count = count + 1 WHERE key = ?", key);
  }

  private metadata(key: string): string | null {
    return this.ctx.storage.sql.exec<MetadataRow>("SELECT value FROM metadata WHERE key = ?", key).toArray()[0]?.value ?? null;
  }

  private setMetadata(key: string, value: string): void {
    this.ctx.storage.sql.exec("INSERT OR REPLACE INTO metadata(key, value) VALUES(?, ?)", key, value);
  }

  private hostSockets(): WebSocket[] {
    return this.ctx.getWebSockets("role:host");
  }

  private deviceSockets(): WebSocket[] {
    return this.ctx.getWebSockets("role:device");
  }

  private broadcastPresence(online: boolean): void {
    const message = JSON.stringify({ type: "presence", online });
    for (const socket of this.deviceSockets()) socket.send(message);
  }

  private attachment(socket: WebSocket): SocketAttachment {
    const value: unknown = socket.deserializeAttachment();
    if (!isRecord(value) || (value.role !== "host" && value.role !== "device") || typeof value.hostID !== "string") {
      throw new RequestValidationError("Missing WebSocket attachment.");
    }
    return {
      role: value.role,
      hostID: value.hostID,
      deviceID: typeof value.deviceID === "string" ? value.deviceID : undefined,
      connectedAt: typeof value.connectedAt === "number" ? value.connectedAt : 0,
    };
  }
}

function json(value: unknown, status = 200): Response {
  return Response.json(value, {
    status,
    headers: {
      "cache-control": "no-store",
      "content-type": "application/json; charset=utf-8",
    },
  });
}
