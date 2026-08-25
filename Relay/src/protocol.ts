export const PROTOCOL_MAJOR = 1;
export const MAX_HTTP_BODY_BYTES = 64 * 1024;
export const MAX_WEBSOCKET_MESSAGE_BYTES = 2 * 1024 * 1024;

export interface RelayRoutingFrame {
  version: { major: number; minor: number };
  hostID: string;
  deviceID?: string;
  sequence: number;
  kind: string;
  nonce?: string;
  ciphertext?: string;
}

export interface PairingSessionCreate {
  /** The host's commitment to its public key and nonce; opaque to the relay. */
  commit: string;
  hostPublicKey: string;
  hostName?: string;
  expiresAt: string;
}

export interface PairingDeviceSubmission {
  deviceID: string;
  deviceName: string;
  devicePublicKey: string;
}

export interface PairingReveal {
  hostNonce: string;
}

export interface PairingDecision {
  approved: boolean;
}

export interface PairingClaim {
  code: string;
}

export interface PushTokenUpdate {
  token: string;
  environment: "production" | "development";
}

export interface NotificationSend {
  /** Omitted means every paired, non-revoked device. */
  deviceIDs?: string[];
  /** The session's title. */
  title: string;
  /** The session's state word (Completed / Failed / Interrupted). */
  subtitle: string;
  sessionID?: string;
  collapseID?: string;
}

export const MAX_NOTIFICATION_TITLE_CHARS = 120;
export const MAX_NOTIFICATION_SUBTITLE_CHARS = 60;
export const MAX_NOTIFICATION_DEVICES = 32;

export class RequestValidationError extends Error {}

export function isValidIdentifier(value: string): boolean {
  return /^[A-Za-z0-9_-]{8,128}$/.test(value);
}

export function parseRelayRoutingFrame(value: unknown): RelayRoutingFrame {
  if (!isRecord(value)) throw new RequestValidationError("Frame must be an object.");
  if (!isRecord(value.version)) throw new RequestValidationError("Missing protocol version.");

  const major = finiteInteger(value.version.major);
  const minor = finiteInteger(value.version.minor);
  const hostID = requiredString(value.hostID, "hostID");
  const deviceID = optionalString(value.deviceID, "deviceID");
  const sequence = finiteInteger(value.sequence);
  const kind = requiredString(value.kind, "kind");
  const nonce = optionalString(value.nonce, "nonce");
  const ciphertext = optionalString(value.ciphertext, "ciphertext");

  if (major !== PROTOCOL_MAJOR) {
    throw new RequestValidationError(`Unsupported protocol major: ${major}.`);
  }
  if (!isValidIdentifier(hostID)) throw new RequestValidationError("Invalid hostID.");
  if (deviceID !== undefined && !isValidIdentifier(deviceID)) {
    throw new RequestValidationError("Invalid deviceID.");
  }
  if (sequence < 0) {
    throw new RequestValidationError("Sequence values must be non-negative.");
  }
  // Both payload-bearing kinds are sealed end to end: `data` (host → device)
  // and `request` (device → host).
  if ((kind === "data" || kind === "request") && (!nonce || !ciphertext)) {
    throw new RequestValidationError("Encrypted frames require nonce and ciphertext.");
  }

  return {
    version: { major, minor },
    hostID,
    ...(deviceID === undefined ? {} : { deviceID }),
    sequence,
    kind,
    ...(nonce === undefined ? {} : { nonce }),
    ...(ciphertext === undefined ? {} : { ciphertext }),
  };
}

export async function readLimitedJSON(request: Request, limit = MAX_HTTP_BODY_BYTES): Promise<unknown> {
  const advertisedLength = Number(request.headers.get("content-length") ?? "0");
  if (Number.isFinite(advertisedLength) && advertisedLength > limit) {
    throw new RequestValidationError("Request body is too large.");
  }
  if (!request.body) throw new RequestValidationError("Missing request body.");

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > limit) {
      await reader.cancel("body limit exceeded");
      throw new RequestValidationError("Request body is too large.");
    }
    chunks.push(value);
  }

  const data = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    data.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return JSON.parse(new TextDecoder().decode(data)) as unknown;
  } catch {
    throw new RequestValidationError("Request body is not valid JSON.");
  }
}

export function parsePairingSessionCreate(value: unknown): PairingSessionCreate {
  if (!isRecord(value)) throw new RequestValidationError("Pairing session must be an object.");
  const hostName = optionalString(value.hostName, "hostName")?.slice(0, 100);
  return {
    commit: credentialString(value.commit, "commit"),
    hostPublicKey: credentialString(value.hostPublicKey, "hostPublicKey"),
    ...(hostName === undefined ? {} : { hostName }),
    expiresAt: requiredString(value.expiresAt, "expiresAt"),
  };
}

export function parsePairingDeviceSubmission(value: unknown): PairingDeviceSubmission {
  if (!isRecord(value)) throw new RequestValidationError("Device submission must be an object.");
  const deviceID = requiredString(value.deviceID, "deviceID");
  if (!isValidIdentifier(deviceID)) throw new RequestValidationError("Invalid deviceID.");
  return {
    deviceID,
    deviceName: requiredString(value.deviceName, "deviceName").slice(0, 100),
    devicePublicKey: credentialString(value.devicePublicKey, "devicePublicKey"),
  };
}

export function parsePairingReveal(value: unknown): PairingReveal {
  if (!isRecord(value)) throw new RequestValidationError("Reveal must be an object.");
  return { hostNonce: credentialString(value.hostNonce, "hostNonce") };
}

export function parsePairingDecision(value: unknown): PairingDecision {
  if (!isRecord(value) || typeof value.approved !== "boolean") {
    throw new RequestValidationError("Decision requires a boolean approved.");
  }
  return { approved: value.approved };
}

export function parsePairingClaim(value: unknown): PairingClaim {
  if (!isRecord(value)) throw new RequestValidationError("Claim must be an object.");
  const code = requiredString(value.code, "code");
  if (code.length > 32) throw new RequestValidationError("Invalid code length.");
  return { code };
}

export function parsePushTokenUpdate(value: unknown): PushTokenUpdate {
  if (!isRecord(value)) throw new RequestValidationError("Push token update must be an object.");
  const token = requiredString(value.token, "token");
  // APNs tokens are hex (32 bytes today); the bound leaves room to grow.
  if (!/^[0-9a-f]{16,200}$/iu.test(token)) throw new RequestValidationError("Invalid token.");
  if (value.environment !== "production" && value.environment !== "development") {
    throw new RequestValidationError("environment must be production or development.");
  }
  return { token, environment: value.environment };
}

export function parseNotificationSend(value: unknown): NotificationSend {
  if (!isRecord(value)) throw new RequestValidationError("Notification must be an object.");
  const title = requiredString(value.title, "title");
  const subtitle = requiredString(value.subtitle, "subtitle");
  if (title.length > MAX_NOTIFICATION_TITLE_CHARS) throw new RequestValidationError("Title is too long.");
  if (subtitle.length > MAX_NOTIFICATION_SUBTITLE_CHARS) throw new RequestValidationError("Subtitle is too long.");
  const sessionID = optionalString(value.sessionID, "sessionID");
  if (sessionID !== undefined && sessionID.length > 200) throw new RequestValidationError("Invalid sessionID.");
  // The collapse ID travels as an APNs header (64-byte cap there); the charset
  // keeps header injection off the table.
  const collapseID = optionalString(value.collapseID, "collapseID");
  if (collapseID !== undefined && !/^[A-Za-z0-9._:-]{1,64}$/u.test(collapseID)) {
    throw new RequestValidationError("Invalid collapseID.");
  }
  let deviceIDs: string[] | undefined;
  if (value.deviceIDs !== undefined && value.deviceIDs !== null) {
    if (!Array.isArray(value.deviceIDs) || value.deviceIDs.length === 0
      || value.deviceIDs.length > MAX_NOTIFICATION_DEVICES) {
      throw new RequestValidationError("Invalid deviceIDs.");
    }
    deviceIDs = value.deviceIDs.map((entry) => {
      if (typeof entry !== "string" || !isValidIdentifier(entry)) {
        throw new RequestValidationError("Invalid deviceIDs entry.");
      }
      return entry;
    });
  }
  return {
    ...(deviceIDs === undefined ? {} : { deviceIDs }),
    title,
    subtitle,
    ...(sessionID === undefined ? {} : { sessionID }),
    ...(collapseID === undefined ? {} : { collapseID }),
  };
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function requiredString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.length === 0) {
    throw new RequestValidationError(`Missing ${field}.`);
  }
  return value;
}

function optionalString(value: unknown, field: string): string | undefined {
  if (value === undefined || value === null) return undefined;
  return requiredString(value, field);
}

function credentialString(value: unknown, field: string): string {
  const result = requiredString(value, field);
  if (result.length < 16 || result.length > 4096) {
    throw new RequestValidationError(`Invalid ${field} length.`);
  }
  return result;
}

function finiteInteger(value: unknown): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value)) {
    throw new RequestValidationError("Expected a safe integer.");
  }
  return value;
}
