import { DurableObject } from "cloudflare:workers";
import { bearerToken, hashCredential, randomCredential, timingSafeStringEqual } from "./crypto";
import type { PairingDirectory } from "./pairing-directory";
import {
  MAX_WEBSOCKET_MESSAGE_BYTES,
  RequestValidationError,
  isRecord,
  parsePairingDecision,
  parsePairingDeviceSubmission,
  parsePairingReveal,
  parsePairingSessionCreate,
  parseRelayRoutingFrame,
  readLimitedJSON,
} from "./protocol";
import { RATE_LIMITS_TABLE, RateLimitError, enforceRateLimit } from "./rate-limit";

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

type PairingState =
  | "offered"
  | "claimed"
  | "submitted"
  | "revealed"
  | "approved"
  | "rejected"
  | "cancelled"
  | "expired";

const TERMINAL_PAIRING_STATES: ReadonlySet<PairingState> = new Set<PairingState>([
  "approved",
  "rejected",
  "cancelled",
  "expired",
]);

interface PairingSessionRow {
  [key: string]: SqlStorageValue;
  id: string;
  host_id: string;
  state: PairingState;
  commit_hash: string;
  host_public_key: string;
  host_name: string | null;
  host_nonce: string | null;
  device_id: string | null;
  device_name: string | null;
  device_public_key: string | null;
  device_token_hash: string | null;
  device_token: string | null;
  created_at: number;
  expires_at: number;
  updated_at: number;
}

const PAIRING_SESSION_COLUMNS = `id, host_id, state, commit_hash, host_public_key, host_name, host_nonce,
  device_id, device_name, device_public_key, device_token_hash, device_token,
  created_at, expires_at, updated_at`;

const MAX_PAIRING_SESSION_LIFETIME_MS = 10 * 60_000;

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
        CREATE TABLE IF NOT EXISTS pairing_sessions (
          id TEXT PRIMARY KEY NOT NULL,
          host_id TEXT NOT NULL,
          state TEXT NOT NULL,
          commit_hash TEXT NOT NULL,
          host_public_key TEXT NOT NULL,
          host_name TEXT,
          host_nonce TEXT,
          device_id TEXT,
          device_name TEXT,
          device_public_key TEXT,
          device_token_hash TEXT,
          device_token TEXT,
          created_at INTEGER NOT NULL,
          expires_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        );
        ${RATE_LIMITS_TABLE}
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
      if (segments[3] === "pairing-sessions") {
        return await this.routePairingSession(request, hostID, segments[4], segments[5], segments.length);
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

    let frame: ReturnType<typeof parseRelayRoutingFrame>;
    try {
      frame = parseRelayRoutingFrame(JSON.parse(message) as unknown);
    } catch (error) {
      ws.send(JSON.stringify({ type: "error", code: "invalid_frame" }));
      console.warn(JSON.stringify({ event: "invalid_frame", role: attachment.role, error: String(error) }));
      return;
    }
    if (frame.hostID !== attachment.hostID) {
      ws.close(1008, "host mismatch");
      return;
    }
    // Forwarding failures are the peer socket's problem, not the sender's:
    // the frame was valid, its sequence stands, and `invalid_frame` would
    // only mislead the host.
    if (attachment.role === "host") {
      this.handleHostFrame(frame, message);
    } else {
      this.handleDeviceFrame(attachment, frame, message, ws);
    }
  }

  /** Sends to one peer socket; a closed or failing socket is logged, not thrown. */
  private forward(target: WebSocket, raw: string, role: "host" | "device"): void {
    try {
      target.send(raw);
    } catch (error) {
      console.warn(JSON.stringify({ event: "forward_failed", to: role, error: String(error) }));
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

  // MARK: - Pairing sessions

  /**
   * Called by the Worker entry after the directory spent a code: the session
   * moves from `offered` to `claimed` and the device learns the host's
   * commitment, which it checks against the nonce revealed later.
   */
  async claimPairingSession(sessionID: string): Promise<{ hostName: string | null; commit: string } | null> {
    const session = await this.loadPairingSession(sessionID);
    if (!session || session.state !== "offered") return null;
    this.updatePairingSession(sessionID, "claimed");
    return { hostName: session.host_name, commit: session.commit_hash };
  }

  private async routePairingSession(
    request: Request,
    hostID: string,
    sessionID: string | undefined,
    action: string | undefined,
    segmentCount: number,
  ): Promise<Response> {
    if (request.method === "POST" && segmentCount === 4) {
      return this.createPairingSession(request, hostID);
    }
    if (!sessionID) return json({ error: "not_found" }, 404);
    if (segmentCount === 5 && request.method === "GET") {
      return this.readPairingSession(request, sessionID);
    }
    if (segmentCount === 5 && request.method === "DELETE") {
      return this.cancelPairingSession(request, sessionID);
    }
    if (segmentCount === 6 && request.method === "POST") {
      switch (action) {
        case "device": return this.submitPairingDevice(request, sessionID);
        case "reveal": return this.revealPairingNonce(request, sessionID);
        case "decision": return this.decidePairingSession(request, sessionID);
        default: break;
      }
    }
    return json({ error: "not_found" }, 404);
  }

  private async createPairingSession(request: Request, hostID: string): Promise<Response> {
    if (!(await this.authorizeHost(request))) return json({ error: "unauthorized" }, 401);
    enforceRateLimit(this.ctx.storage.sql, "pairing-session:create", 10, 60_000);
    const input = parsePairingSessionCreate(await readLimitedJSON(request));
    const now = Date.now();
    const expiresAt = Date.parse(input.expiresAt);
    if (!Number.isFinite(expiresAt) || expiresAt <= now || expiresAt > now + MAX_PAIRING_SESSION_LIFETIME_MS) {
      throw new RequestValidationError("Pairing sessions must expire within ten minutes.");
    }

    // One live session per Mac: a new code retires whatever was on screen.
    for (const live of this.livePairingSessions()) {
      await this.closePairingSession(live, "cancelled");
    }
    // Finished sessions are dead weight once past their expiry — and an
    // approved row still holds the Device token the iPhone collected.
    this.ctx.storage.sql.exec("DELETE FROM pairing_sessions WHERE expires_at < ?", now);

    const sessionID = randomCredential();
    this.ctx.storage.sql.exec(
      `INSERT INTO pairing_sessions(
         id, host_id, state, commit_hash, host_public_key, host_name, host_nonce,
         device_id, device_name, device_public_key, device_token_hash, device_token,
         created_at, expires_at, updated_at
       ) VALUES(?, ?, 'offered', ?, ?, ?, NULL, NULL, NULL, NULL, NULL, NULL, ?, ?, ?)`,
      sessionID,
      hostID,
      input.commit,
      input.hostPublicKey,
      input.hostName ?? null,
      now,
      expiresAt,
      now,
    );
    const code = await this.directory().allocate(hostID, sessionID, expiresAt);
    return json({ sessionID, code, expiresAt: new Date(expiresAt).toISOString() }, 201);
  }

  private async submitPairingDevice(request: Request, sessionID: string): Promise<Response> {
    const session = await this.loadPairingSession(sessionID);
    if (!session) return json({ error: "not_found" }, 404);
    if (!this.authorizePairingSession(request, session)) return json({ error: "unauthorized" }, 401);
    const submission = parsePairingDeviceSubmission(await readLimitedJSON(request));
    if (session.state !== "claimed") return invalidState(session.state);
    if (!this.hostIsOnline()) return json({ error: "host_offline" }, 409);

    this.updatePairingSession(sessionID, "submitted", {
      device_id: submission.deviceID,
      device_name: submission.deviceName,
      device_public_key: submission.devicePublicKey,
    });
    this.sendToHost({
      type: "pairing_device",
      sessionID,
      deviceID: submission.deviceID,
      deviceName: submission.deviceName,
      devicePublicKey: submission.devicePublicKey,
    });
    return json({ state: "submitted" });
  }

  private async readPairingSession(request: Request, sessionID: string): Promise<Response> {
    const session = await this.loadPairingSession(sessionID);
    if (!session) return json({ error: "not_found" }, 404);
    if (!this.authorizePairingSession(request, session)) return json({ error: "unauthorized" }, 401);

    const revealed = session.state === "revealed" || session.state === "approved";
    const approved = session.state === "approved";
    return json({
      state: session.state,
      hostName: session.host_name,
      ...(revealed ? { hostPublicKey: session.host_public_key, hostNonce: session.host_nonce } : {}),
      ...(approved && session.device_token !== null
        ? { deviceToken: session.device_token, pairedAt: new Date(session.updated_at).toISOString() }
        : {}),
    });
  }

  private async revealPairingNonce(request: Request, sessionID: string): Promise<Response> {
    if (!(await this.authorizeHost(request))) return json({ error: "unauthorized" }, 401);
    const reveal = parsePairingReveal(await readLimitedJSON(request));
    const session = await this.loadPairingSession(sessionID);
    if (!session) return json({ error: "not_found" }, 404);
    if (session.state !== "submitted") return invalidState(session.state);
    this.updatePairingSession(sessionID, "revealed", { host_nonce: reveal.hostNonce });
    return json({ state: "revealed" });
  }

  private async decidePairingSession(request: Request, sessionID: string): Promise<Response> {
    if (!(await this.authorizeHost(request))) return json({ error: "unauthorized" }, 401);
    const decision = parsePairingDecision(await readLimitedJSON(request));
    const session = await this.loadPairingSession(sessionID);
    if (!session) return json({ error: "not_found" }, 404);

    if (!decision.approved) {
      if (session.state !== "submitted" && session.state !== "revealed") return invalidState(session.state);
      this.updatePairingSession(sessionID, "rejected");
      return json({ state: "rejected" });
    }

    if (session.state !== "revealed") return invalidState(session.state);
    if (session.device_id === null || session.device_name === null || session.device_public_key === null) {
      throw new Error("Revealed pairing session has no device.");
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
      session.device_id,
      session.device_name,
      session.device_public_key,
      tokenHash,
      pairedAt,
    );
    // The plaintext token stays in the session row so the device's next poll
    // can collect it; the row is only readable with the session capability and
    // dies with the session.
    this.updatePairingSession(sessionID, "approved", {
      device_token_hash: tokenHash,
      device_token: deviceToken,
    }, pairedAt);
    return json({ state: "approved", deviceID: session.device_id });
  }

  private async cancelPairingSession(request: Request, sessionID: string): Promise<Response> {
    const session = await this.loadPairingSession(sessionID);
    if (!session) return json({ error: "not_found" }, 404);
    const byHost = await this.authorizeHost(request);
    if (!byHost && !this.authorizePairingSession(request, session)) return json({ error: "unauthorized" }, 401);
    if (!TERMINAL_PAIRING_STATES.has(session.state)) {
      await this.closePairingSession(session, "cancelled", !byHost);
    }
    return new Response(null, { status: 204 });
  }

  /** Reads a session, retiring it first if its deadline has passed. */
  private async loadPairingSession(sessionID: string): Promise<PairingSessionRow | null> {
    const session = this.ctx.storage.sql.exec<PairingSessionRow>(
      `SELECT ${PAIRING_SESSION_COLUMNS} FROM pairing_sessions WHERE id = ?`,
      sessionID,
    ).toArray()[0];
    if (!session) return null;
    if (!TERMINAL_PAIRING_STATES.has(session.state) && Date.now() > session.expires_at) {
      await this.closePairingSession(session, "expired", true);
      return { ...session, state: "expired" };
    }
    return session;
  }

  private livePairingSessions(): PairingSessionRow[] {
    return this.ctx.storage.sql.exec<PairingSessionRow>(
      `SELECT ${PAIRING_SESSION_COLUMNS} FROM pairing_sessions
       WHERE state IN ('offered', 'claimed', 'submitted', 'revealed')`,
    ).toArray();
  }

  /**
   * Ends a non-terminal session: the directory forgets its code and, when the
   * Mac was already looking at this device, its sockets hear why it vanished.
   */
  private async closePairingSession(
    session: PairingSessionRow,
    state: "cancelled" | "expired",
    notifyHost = false,
  ): Promise<void> {
    this.updatePairingSession(session.id, state);
    await this.directory().release(session.host_id, session.id);
    if (notifyHost && (session.state === "submitted" || session.state === "revealed")) {
      this.sendToHost({ type: "pairing_closed", sessionID: session.id, reason: state });
    }
  }

  private updatePairingSession(
    sessionID: string,
    state: PairingState,
    fields: Record<string, string> = {},
    updatedAt = Date.now(),
  ): void {
    const names = Object.keys(fields);
    const assignments = ["state = ?", "updated_at = ?", ...names.map((name) => `${name} = ?`)].join(", ");
    this.ctx.storage.sql.exec(
      `UPDATE pairing_sessions SET ${assignments} WHERE id = ?`,
      state,
      updatedAt,
      ...names.map((name) => fields[name] ?? null),
      sessionID,
    );
  }

  /** The session ID doubles as the device's bearer capability for the session. */
  private authorizePairingSession(request: Request, session: PairingSessionRow): boolean {
    const token = bearerToken(request);
    if (!token) return false;
    return timingSafeStringEqual(token, session.id);
  }

  private directory(): DurableObjectStub<PairingDirectory> {
    return this.env.PAIRING_DIRECTORY.getByName("directory");
  }

  private hostIsOnline(): boolean {
    return this.hostSockets().some((socket) => socket.readyState === WebSocket.OPEN);
  }

  private sendToHost(message: Record<string, unknown>): void {
    const raw = JSON.stringify(message);
    for (const socket of this.hostSockets()) this.forward(socket, raw, "host");
  }

  // MARK: - Host, devices, sockets

  private async registerHost(request: Request): Promise<Response> {
    await this.enforceSourceRateLimit(request, "register", 10, 60_000);
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

  /// `DELETE …/devices/:id` revokes (the row stays, listed as Revoked so the
  /// Mac can show it); `?purge=1` removes the record altogether — the Mac's
  /// `Remove` on a revoked row. Either way every socket of the device closes.
  private async revokeDevice(request: Request, deviceID: string): Promise<Response> {
    if (!(await this.authorizeHost(request))) return json({ error: "unauthorized" }, 401);
    const purge = new URL(request.url).searchParams.get("purge") === "1";
    if (purge) {
      this.ctx.storage.sql.exec("DELETE FROM devices WHERE id = ?", deviceID);
    } else {
      this.ctx.storage.sql.exec(
        "UPDATE devices SET revoked_at = ? WHERE id = ?",
        Date.now(),
        deviceID,
      );
    }
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
      // Tell the host where the channel actually is so it can move its own
      // cursor past the reused value instead of looping on the error.
      for (const host of this.hostSockets()) {
        host.send(JSON.stringify({
          type: "error",
          code: "non_monotonic_sequence",
          sequence: frame.sequence,
          lastSequence,
          ...(frame.deviceID === undefined ? {} : { deviceID: frame.deviceID }),
        }));
      }
      return;
    }
    this.setMetadata(channelKey, String(frame.sequence));

    const targets = frame.deviceID
      ? this.ctx.getWebSockets(`device:${frame.deviceID}`)
      : this.deviceSockets();
    for (const target of targets) this.forward(target, raw, "device");
  }

  private handleDeviceFrame(
    attachment: SocketAttachment,
    frame: ReturnType<typeof parseRelayRoutingFrame>,
    raw: string,
    socket: WebSocket,
  ): void {
    if (frame.deviceID !== attachment.deviceID || frame.kind !== "request") {
      socket.close(1008, "device is read-only");
      return;
    }
    // The relay keeps no replay buffer and cannot read the body: a device's
    // sealed `request` (sync index, fetch session, session reviewed, …) is
    // forwarded to the host verbatim and answered by the host in `data` frames.
    for (const host of this.hostSockets()) this.forward(host, raw, "host");
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

  private async enforceSourceRateLimit(
    request: Request,
    action: string,
    limit: number,
    windowMilliseconds: number,
  ): Promise<void> {
    const source = request.headers.get("cf-connecting-ip") ?? "local";
    enforceRateLimit(this.ctx.storage.sql, `${action}:${await hashCredential(source)}`, limit, windowMilliseconds);
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

function invalidState(state: PairingState): Response {
  return json({ error: "invalid_state", state }, 409);
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
