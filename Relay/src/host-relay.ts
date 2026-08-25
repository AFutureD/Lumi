import { DurableObject } from "cloudflare:workers";
import { bearerToken, hashCredential, randomCredential, timingSafeStringEqual } from "./crypto";
import { elapsedMs, loggerForEnv, shortID, traceID, type Logger } from "./log";
import type { PairingDirectory } from "./pairing-directory";
import { sendPush, type APNSEnvironment } from "./apns";
import {
  MAX_WEBSOCKET_MESSAGE_BYTES,
  RequestValidationError,
  isRecord,
  parseNotificationSend,
  parsePairingDecision,
  parsePairingDeviceSubmission,
  parsePairingReveal,
  parsePairingSessionCreate,
  parsePushTokenUpdate,
  parseRelayRoutingFrame,
  readLimitedJSON,
} from "./protocol";
import { RATE_LIMITS_TABLE, RateLimitError, enforceRateLimit, sourceBucket } from "./rate-limit";

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
  apns_token: string | null;
  apns_environment: string | null;
  apns_updated_at: number | null;
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
/** How long after a session's deadline the purge alarm fires. */
const PAIRING_PURGE_GRACE_MS = 1_000;

export class HostRelay extends DurableObject<Env> {
  /** `http`: requests into this object; `ws`: sockets and frames; `pairing`: the session state machine. */
  private log: Logger;
  private wsLog: Logger;
  private pairingLog: Logger;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.log = loggerForEnv(env, "http");
    this.wsLog = this.log.withCategory("ws");
    this.pairingLog = this.log.withCategory("pairing");
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
      this.migrate();
      return Promise.resolve();
    });
  }

  /**
   * `CREATE TABLE IF NOT EXISTS` never touches an existing table, so column
   * additions go through here: bump the version in metadata, run the `ALTER`s
   * for every step the stored version has not seen. A fresh object walks the
   * same path — the base tables above are version 1.
   */
  private migrate(): void {
    const version = Number(this.metadata("schema_version") ?? "1");
    if (version < 2) {
      this.ctx.storage.sql.exec(`
        ALTER TABLE devices ADD COLUMN apns_token TEXT;
        ALTER TABLE devices ADD COLUMN apns_environment TEXT;
        ALTER TABLE devices ADD COLUMN apns_updated_at INTEGER;
      `);
    }
    if (version < 2) this.setMetadata("schema_version", "2");
  }

  override async fetch(request: Request): Promise<Response> {
    const startedAt = Date.now();
    const url = new URL(request.url);
    const segments = url.pathname.split("/").filter(Boolean);
    const hostID = segments[2];
    // Every line of this object names its host; the first request binds it.
    if (hostID && this.log.fields.hostID === undefined) {
      this.log = this.log.child({ hostID });
      this.wsLog = this.wsLog.child({ hostID });
      this.pairingLog = this.pairingLog.child({ hostID });
    }
    // This request's lines carry its trace (cf-ray); the object's loggers
    // are shared, so the request scope is a local child.
    const log = this.log.child({ trace: traceID(request) });
    try {
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
      if (segments[3] === "devices" && segments[4] && segments[5] === "push-token" && segments.length === 6) {
        if (request.method === "PUT") return await this.updatePushToken(request, segments[4]);
        if (request.method === "DELETE") return await this.clearPushToken(request, segments[4]);
        return json({ error: "not_found" }, 404);
      }
      if (request.method === "DELETE" && segments[3] === "devices" && segments[4]) {
        return await this.revokeDevice(request, segments[4]);
      }
      if (request.method === "POST" && segments[3] === "notifications" && segments.length === 4) {
        return await this.sendNotifications(request, hostID);
      }
      if (request.method === "GET" && segments[3] === "ws") {
        return await this.openWebSocket(request, hostID);
      }
      return json({ error: "not_found" }, 404);
    } catch (error) {
      if (error instanceof RequestValidationError) {
        log.warn("request_invalid", { method: request.method, path: segments.slice(3).join("/"), error });
        return json({ error: "invalid_request", message: error.message }, 400);
      }
      if (error instanceof RateLimitError) {
        log.warn("request_rate_limited", { method: request.method, path: segments.slice(3).join("/") });
        return json({ error: "rate_limited" }, 429);
      }
      log.error("request_failed", {
        method: request.method,
        path: segments.slice(3, 4).join("/"),
        ms: elapsedMs(startedAt),
        error,
        stack: error instanceof Error ? error.stack : undefined,
      });
      return json({ error: "internal_error" }, 500);
    }
  }

  override webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): void {
    const attachment = this.attachment(ws);
    const byteLength = typeof message === "string"
      ? new TextEncoder().encode(message).byteLength
      : message.byteLength;
    if (byteLength > MAX_WEBSOCKET_MESSAGE_BYTES) {
      this.wsLog.warn("ws_message_too_large", { role: attachment.role, deviceID: attachment.deviceID, bytes: byteLength });
      ws.close(1009, "message too large");
      return;
    }
    if (typeof message !== "string") {
      this.wsLog.warn("ws_message_not_text", { role: attachment.role, deviceID: attachment.deviceID, bytes: byteLength });
      ws.close(1003, "routing frames must be JSON text");
      return;
    }

    let frame: ReturnType<typeof parseRelayRoutingFrame>;
    try {
      frame = parseRelayRoutingFrame(JSON.parse(message) as unknown);
    } catch (error) {
      ws.send(JSON.stringify({ type: "error", code: "invalid_frame" }));
      this.wsLog.warn("ws_frame_invalid", { role: attachment.role, deviceID: attachment.deviceID, bytes: byteLength, error });
      return;
    }
    if (frame.hostID !== attachment.hostID) {
      this.wsLog.warn("ws_host_mismatch", { role: attachment.role, deviceID: attachment.deviceID, frameHostID: frame.hostID });
      ws.close(1008, "host mismatch");
      return;
    }
    // Forwarding failures are the peer socket's problem, not the sender's:
    // the frame was valid, its sequence stands, and `invalid_frame` would
    // only mislead the host.
    if (attachment.role === "host") {
      this.handleHostFrame(frame, message, byteLength);
    } else {
      this.handleDeviceFrame(attachment, frame, message, ws, byteLength);
    }
  }

  /** Sends to one peer socket; a closed or failing socket is logged, not thrown. */
  private forward(target: WebSocket, raw: string, role: "host" | "device"): boolean {
    try {
      target.send(raw);
      return true;
    } catch (error) {
      this.wsLog.warn("ws_forward_failed", { to: role, error });
      return false;
    }
  }

  override webSocketClose(ws: WebSocket, code: number, reason: string, wasClean: boolean): void {
    const attachment = this.attachment(ws);
    const hasAnotherOpenHost = this.hostSockets().some(
      (candidate) => candidate !== ws && candidate.readyState === WebSocket.OPEN,
    );
    this.wsLog.info("ws_closed", {
      role: attachment.role,
      deviceID: attachment.deviceID,
      code,
      reason,
      wasClean,
      connectedMs: attachment.connectedAt > 0 ? elapsedMs(attachment.connectedAt) : undefined,
      hostOnline: attachment.role === "host" ? hasAnotherOpenHost : this.hostIsOnline(),
    });
    if (attachment.role === "host" && !hasAnotherOpenHost) {
      this.broadcastPresence(false);
    }
  }

  override webSocketError(ws: WebSocket, error: unknown): void {
    const attachment = this.attachment(ws);
    this.wsLog.warn("ws_error", { role: attachment.role, deviceID: attachment.deviceID, error });
  }

  /**
   * Fires just after the latest pairing deadline: live sessions past it are
   * closed the normal way (code released, host told), then every expired row
   * is dropped — an approved row still holds the plaintext Device token the
   * iPhone collected, and nothing needs it after the session window.
   */
  override async alarm(): Promise<void> {
    const now = Date.now();
    for (const session of this.livePairingSessions()) {
      if (session.expires_at <= now) await this.closePairingSession(session, "expired", true);
    }
    const purged = this.ctx.storage.sql.exec("DELETE FROM pairing_sessions WHERE expires_at <= ?", now).rowsWritten;
    const next = this.ctx.storage.sql.exec<{ [key: string]: SqlStorageValue; next: number | null }>(
      "SELECT MIN(expires_at) AS next FROM pairing_sessions",
    ).toArray()[0]?.next ?? null;
    if (next !== null) await this.ctx.storage.setAlarm(next + PAIRING_PURGE_GRACE_MS);
    this.pairingLog.info("pairing_sessions_purged", {
      purged,
      nextAlarm: next === null ? undefined : new Date(next + PAIRING_PURGE_GRACE_MS).toISOString(),
    });
  }

  /** Makes sure the purge alarm fires no later than just after `expiresAt`. */
  private async schedulePairingPurge(expiresAt: number): Promise<void> {
    const target = expiresAt + PAIRING_PURGE_GRACE_MS;
    const current = await this.ctx.storage.getAlarm();
    if (current === null || current > target) await this.ctx.storage.setAlarm(target);
  }

  // MARK: - Pairing sessions

  /**
   * Called by the Worker entry after the directory spent a code: the session
   * moves from `offered` to `claimed` and the device learns the host's
   * commitment, which it checks against the nonce revealed later.
   */
  async claimPairingSession(sessionID: string): Promise<{ hostName: string | null; commit: string } | null> {
    const session = await this.loadPairingSession(sessionID);
    if (!session || session.state !== "offered") {
      this.pairingLog.info("pairing_claim_refused", { sessionID: shortID(sessionID), state: session?.state ?? "missing" });
      return null;
    }
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
    const live = this.livePairingSessions();
    for (const session of live) {
      await this.closePairingSession(session, "cancelled");
    }
    // Finished sessions are dead weight once past their expiry — and an
    // approved row still holds the Device token the iPhone collected.
    const purged = this.ctx.storage.sql.exec("DELETE FROM pairing_sessions WHERE expires_at < ?", now).rowsWritten;

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
    await this.schedulePairingPurge(expiresAt);
    this.pairingLog.info("pairing_session_created", {
      sessionID: shortID(sessionID),
      expiresAt: new Date(expiresAt).toISOString(),
      supersededLive: live.length,
      purgedExpired: purged,
    });
    return json({ sessionID, code, expiresAt: new Date(expiresAt).toISOString() }, 201);
  }

  private async submitPairingDevice(request: Request, sessionID: string): Promise<Response> {
    const session = await this.loadPairingSession(sessionID);
    if (!session) return json({ error: "not_found" }, 404);
    if (!this.authorizePairingSession(request, session)) return json({ error: "unauthorized" }, 401);
    const submission = parsePairingDeviceSubmission(await readLimitedJSON(request));
    if (session.state !== "claimed") return this.invalidState("device", session);
    if (!this.hostIsOnline()) {
      this.pairingLog.info("pairing_device_host_offline", { sessionID: shortID(sessionID), deviceID: submission.deviceID });
      return json({ error: "host_offline" }, 409);
    }

    this.pairingLog.info("pairing_device_submitted", { sessionID: shortID(sessionID), deviceID: submission.deviceID });
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
    if (session.state !== "submitted") return this.invalidState("reveal", session);
    this.updatePairingSession(sessionID, "revealed", { host_nonce: reveal.hostNonce });
    this.pairingLog.info("pairing_revealed", { sessionID: shortID(sessionID), deviceID: session.device_id });
    return json({ state: "revealed" });
  }

  private async decidePairingSession(request: Request, sessionID: string): Promise<Response> {
    if (!(await this.authorizeHost(request))) return json({ error: "unauthorized" }, 401);
    const decision = parsePairingDecision(await readLimitedJSON(request));
    const session = await this.loadPairingSession(sessionID);
    if (!session) return json({ error: "not_found" }, 404);

    if (!decision.approved) {
      if (session.state !== "submitted" && session.state !== "revealed") return this.invalidState("decision", session);
      this.updatePairingSession(sessionID, "rejected");
      this.pairingLog.info("pairing_rejected", { sessionID: shortID(sessionID), deviceID: session.device_id, from: session.state });
      return json({ state: "rejected" });
    }

    if (session.state !== "revealed") return this.invalidState("decision", session);
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
    this.pairingLog.info("pairing_approved", { sessionID: shortID(sessionID), deviceID: session.device_id });
    return json({ state: "approved", deviceID: session.device_id });
  }

  private async cancelPairingSession(request: Request, sessionID: string): Promise<Response> {
    const session = await this.loadPairingSession(sessionID);
    if (!session) return json({ error: "not_found" }, 404);
    const byHost = await this.authorizeHost(request);
    if (!byHost && !this.authorizePairingSession(request, session)) return json({ error: "unauthorized" }, 401);
    if (!TERMINAL_PAIRING_STATES.has(session.state)) {
      this.pairingLog.info("pairing_cancel_requested", { sessionID: shortID(sessionID), by: byHost ? "host" : "device", from: session.state });
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
    const notified = notifyHost && (session.state === "submitted" || session.state === "revealed");
    if (notified) {
      this.sendToHost({ type: "pairing_closed", sessionID: session.id, reason: state });
    }
    this.pairingLog.info("pairing_session_closed", { sessionID: shortID(session.id), from: session.state, to: state, hostNotified: notified });
  }

  /** 409 for an action the session's state does not allow; logged, since a stuck client repeats it. */
  private invalidState(action: string, session: PairingSessionRow): Response {
    this.pairingLog.info("pairing_invalid_state", { sessionID: shortID(session.id), action, state: session.state });
    return invalidState(session.state);
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
      this.log.warn("host_register_rejected", { reason: "secret_mismatch" });
      return json({ error: "unauthorized" }, 401);
    }
    if (!currentHash) this.setMetadata("host_token_hash", newHash);
    this.log.info("host_registered", { fresh: !currentHash });
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
    let rows: number;
    if (purge) {
      rows = this.ctx.storage.sql.exec("DELETE FROM devices WHERE id = ?", deviceID).rowsWritten;
    } else {
      // A revoked device keeps its row but loses its push token with its
      // sockets — revocation means no channel of any kind.
      rows = this.ctx.storage.sql.exec(
        "UPDATE devices SET revoked_at = ?, apns_token = NULL, apns_environment = NULL, apns_updated_at = NULL WHERE id = ?",
        Date.now(),
        deviceID,
      ).rowsWritten;
    }
    const sockets = this.ctx.getWebSockets(`device:${deviceID}`);
    for (const socket of sockets) {
      socket.close(4003, "device revoked");
    }
    this.log.info(purge ? "device_purged" : "device_revoked", { deviceID, rows, socketsClosed: sockets.length });
    return new Response(null, { status: 204 });
  }

  /** `PUT …/devices/:id/push-token` — the iPhone registers its APNs token. */
  private async updatePushToken(request: Request, deviceID: string): Promise<Response> {
    if (!(await this.authorizeDevice(request, deviceID))) return json({ error: "unauthorized" }, 401);
    const input = parsePushTokenUpdate(await readLimitedJSON(request));
    this.ctx.storage.sql.exec(
      "UPDATE devices SET apns_token = ?, apns_environment = ?, apns_updated_at = ? WHERE id = ?",
      input.token,
      input.environment,
      Date.now(),
      deviceID,
    );
    this.log.info("device_push_token_updated", { deviceID, environment: input.environment });
    return new Response(null, { status: 204 });
  }

  /** `DELETE …/devices/:id/push-token` — best-effort cleanup when the iPhone unpairs. */
  private async clearPushToken(request: Request, deviceID: string): Promise<Response> {
    if (!(await this.authorizeDevice(request, deviceID))) return json({ error: "unauthorized" }, 401);
    this.ctx.storage.sql.exec(
      "UPDATE devices SET apns_token = NULL, apns_environment = NULL, apns_updated_at = NULL WHERE id = ?",
      deviceID,
    );
    this.log.info("device_push_token_cleared", { deviceID });
    return new Response(null, { status: 204 });
  }

  /**
   * `POST …/notifications` — the daemon hands over a short plaintext alert and
   * the relay forwards it to APNs. The text exists only in this request's
   * memory: it is never stored and never logged. An `unregistered` outcome
   * (APNs 410, or the `BadDeviceToken` an environment mismatch produces)
   * drops the token; the device re-registers on its next launch.
   */
  private async sendNotifications(request: Request, hostID: string): Promise<Response> {
    if (!(await this.authorizeHost(request))) return json({ error: "unauthorized" }, 401);
    enforceRateLimit(this.ctx.storage.sql, "notifications:send", 120, 60_000);
    const input = parseNotificationSend(await readLimitedJSON(request));
    const { APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY, APNS_TOPIC } = this.env;
    if (!APNS_KEY_ID || !APNS_TEAM_ID || !APNS_PRIVATE_KEY || !APNS_TOPIC) {
      this.log.error("notifications_unconfigured", {});
      return json({ error: "apns_not_configured" }, 503);
    }
    const credentials = { keyID: APNS_KEY_ID, teamID: APNS_TEAM_ID, privateKeyPEM: APNS_PRIVATE_KEY };

    const startedAt = Date.now();
    const targets = input.deviceIDs
      ? input.deviceIDs.map((id) => this.deviceRow(id) ?? id)
      : this.ctx.storage.sql.exec<DeviceRow>(
        "SELECT * FROM devices WHERE revoked_at IS NULL ORDER BY paired_at DESC",
      ).toArray();

    const results: Array<{ deviceID: string; status: string }> = [];
    for (const target of targets) {
      if (typeof target === "string" || target.revoked_at !== null) {
        results.push({ deviceID: typeof target === "string" ? target : target.id, status: "revoked" });
        continue;
      }
      if (target.apns_token === null || target.apns_environment === null) {
        results.push({ deviceID: target.id, status: "no_token" });
        continue;
      }
      const outcome = await sendPush(credentials, {
        topic: APNS_TOPIC,
        environment: target.apns_environment as APNSEnvironment,
        deviceToken: target.apns_token,
        title: input.title,
        subtitle: input.subtitle,
        hostID,
        ...(input.sessionID === undefined ? {} : { sessionID: input.sessionID }),
        ...(input.collapseID === undefined ? {} : { collapseID: input.collapseID }),
      });
      if (outcome.status === "unregistered") {
        this.ctx.storage.sql.exec(
          "UPDATE devices SET apns_token = NULL, apns_environment = NULL, apns_updated_at = NULL WHERE id = ?",
          target.id,
        );
      }
      this.log.info("notification_result", {
        deviceID: target.id,
        status: outcome.status,
        environment: target.apns_environment,
        apnsID: outcome.status === "sent" ? outcome.apnsID : undefined,
        httpStatus: outcome.status === "failed" ? outcome.httpStatus : undefined,
        reason: outcome.status === "failed" ? outcome.reason : undefined,
        titleChars: input.title.length,
        subtitleChars: input.subtitle.length,
        ms: elapsedMs(startedAt),
      });
      results.push({ deviceID: target.id, status: outcome.status });
    }
    return json({ results });
  }

  private deviceRow(deviceID: string): DeviceRow | null {
    return this.ctx.storage.sql.exec<DeviceRow>(
      "SELECT * FROM devices WHERE id = ?",
      deviceID,
    ).toArray()[0] ?? null;
  }

  private async openWebSocket(request: Request, hostID: string): Promise<Response> {
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return json({ error: "websocket_upgrade_required" }, 426);
    }
    const url = new URL(request.url);
    const role = url.searchParams.get("role");
    const deviceID = url.searchParams.get("deviceId") ?? undefined;

    if (role === "host") {
      if (!(await this.authorizeHost(request))) {
        this.wsLog.warn("ws_unauthorized", { role });
        return json({ error: "unauthorized" }, 401);
      }
    } else if (role === "device" && deviceID) {
      if (!(await this.authorizeDevice(request, deviceID))) {
        this.wsLog.warn("ws_unauthorized", { role, deviceID });
        return json({ error: "unauthorized" }, 401);
      }
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

    let replaced = 0;
    if (role === "host") {
      for (const existing of this.hostSockets()) {
        existing.close(4001, "host connection replaced");
        replaced += 1;
      }
    }
    this.ctx.acceptWebSocket(server, tags);
    server.serializeAttachment(attachment);
    const hostOnline = this.hostSockets().length > 0;
    if (role === "host") {
      this.broadcastPresence(true);
    } else {
      server.send(JSON.stringify({ type: "presence", online: hostOnline }));
    }
    this.wsLog.info("ws_opened", {
      role,
      deviceID,
      replacedHostSockets: role === "host" ? replaced : undefined,
      deviceSockets: this.deviceSockets().length,
      hostOnline,
    });
    return new Response(null, { status: 101, webSocket: client });
  }

  private handleHostFrame(frame: ReturnType<typeof parseRelayRoutingFrame>, raw: string, bytes: number): void {
    // Sequences belong to a paired Mac/iOS channel. Two devices may both send
    // sequence 1; sessions inside either channel never influence this cursor.
    const channelKey = `last_host_sequence:${frame.deviceID ?? "broadcast"}`;
    const lastSequence = Number(this.metadata(channelKey) ?? "-1");
    if (frame.sequence <= lastSequence) {
      this.wsLog.warn("ws_sequence_rejected", {
        deviceID: frame.deviceID,
        kind: frame.kind,
        sequence: frame.sequence,
        lastSequence,
      });
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
    let delivered = 0;
    for (const target of targets) {
      if (this.forward(target, raw, "device")) delivered += 1;
    }
    // A frame per line is only worth it while debugging a channel; the
    // sequence on every line makes gaps visible without a decoder.
    this.wsLog.debug("ws_host_frame_forwarded", {
      deviceID: frame.deviceID,
      kind: frame.kind,
      sequence: frame.sequence,
      bytes,
      targets: targets.length,
      delivered,
    });
    if (targets.length === 0) {
      this.wsLog.info("ws_host_frame_undeliverable", { deviceID: frame.deviceID, kind: frame.kind, sequence: frame.sequence, bytes });
    }
  }

  private handleDeviceFrame(
    attachment: SocketAttachment,
    frame: ReturnType<typeof parseRelayRoutingFrame>,
    raw: string,
    socket: WebSocket,
    bytes: number,
  ): void {
    if (frame.deviceID !== attachment.deviceID || frame.kind !== "request") {
      this.wsLog.warn("ws_device_frame_rejected", {
        deviceID: attachment.deviceID,
        frameDeviceID: frame.deviceID,
        kind: frame.kind,
        sequence: frame.sequence,
      });
      socket.close(1008, "device is read-only");
      return;
    }
    // The relay keeps no replay buffer and cannot read the body: a device's
    // sealed `request` (sync index, fetch session, session reviewed, …) is
    // forwarded to the host verbatim and answered by the host in `data` frames.
    const hosts = this.hostSockets();
    let delivered = 0;
    for (const host of hosts) {
      if (this.forward(host, raw, "host")) delivered += 1;
    }
    this.wsLog.debug("ws_device_frame_forwarded", {
      deviceID: attachment.deviceID,
      sequence: frame.sequence,
      bytes,
      hosts: hosts.length,
      delivered,
    });
    if (hosts.length === 0) {
      this.wsLog.info("ws_device_frame_undeliverable", { deviceID: attachment.deviceID, sequence: frame.sequence, bytes });
    }
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
    const source = sourceBucket(request.headers.get("cf-connecting-ip") ?? "local");
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
