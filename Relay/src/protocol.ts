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

export interface PairingOfferRequest {
  challenge: string;
  hostPublicKey: string;
  expiresAt: string;
}

export interface PairingRequest {
  challenge: string;
  deviceID: string;
  deviceName: string;
  devicePublicKey: string;
}

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

export function parsePairingOffer(value: unknown): PairingOfferRequest {
  if (!isRecord(value)) throw new RequestValidationError("Pairing offer must be an object.");
  return {
    challenge: credentialString(value.challenge, "challenge"),
    hostPublicKey: credentialString(value.hostPublicKey, "hostPublicKey"),
    expiresAt: requiredString(value.expiresAt, "expiresAt"),
  };
}

export function parsePairingRequest(value: unknown): PairingRequest {
  if (!isRecord(value)) throw new RequestValidationError("Pairing request must be an object.");
  const deviceID = requiredString(value.deviceID, "deviceID");
  if (!isValidIdentifier(deviceID)) throw new RequestValidationError("Invalid deviceID.");
  return {
    challenge: credentialString(value.challenge, "challenge"),
    deviceID,
    deviceName: requiredString(value.deviceName, "deviceName").slice(0, 100),
    devicePublicKey: credentialString(value.devicePublicKey, "devicePublicKey"),
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
