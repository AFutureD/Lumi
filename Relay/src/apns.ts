import { base64URL } from "./crypto";

export type APNSEnvironment = "production" | "development";

export interface APNSCredentials {
  keyID: string;
  teamID: string;
  /** The .p8 auth key, full PEM text (PKCS#8, P-256). */
  privateKeyPEM: string;
}

export interface APNSPush {
  topic: string;
  environment: APNSEnvironment;
  deviceToken: string;
  /** The session's title. */
  title: string;
  /** The session's state word, shown as the small line under the title. */
  subtitle: string;
  hostID: string;
  sessionID?: string;
  collapseID?: string;
}

/**
 * `unregistered` is terminal for the token (APNs 410, or `BadDeviceToken` —
 * the shape an environment mismatch takes); the caller drops it. `failed` is
 * transient: the token stays and the next notification is the retry.
 */
export type APNSOutcome =
  | { status: "sent"; apnsID?: string }
  | { status: "unregistered" }
  | { status: "failed"; httpStatus: number; reason?: string };

/** Apple requires provider tokens between 20 and 60 minutes old. */
const JWT_LIFETIME_MS = 50 * 60_000;

interface CachedJWT {
  token: string;
  issuedAt: number;
}

// Both caches are per-isolate; an isolate restart just re-imports and re-signs.
const jwtCache = new Map<string, CachedJWT>();
const keyCache = new Map<string, CryptoKey>();

export async function sendPush(credentials: APNSCredentials, push: APNSPush): Promise<APNSOutcome> {
  const jwt = await providerJWT(credentials);
  const host = push.environment === "development"
    ? "api.sandbox.push.apple.com"
    : "api.push.apple.com";
  const payload = {
    aps: {
      alert: { title: push.title, subtitle: push.subtitle },
      sound: "default",
      ...(push.sessionID === undefined ? {} : { "thread-id": push.sessionID }),
    },
    lumi: {
      hostID: push.hostID,
      ...(push.sessionID === undefined ? {} : { sessionID: push.sessionID }),
    },
  };
  let response: Response;
  try {
    response = await fetch(`https://${host}/3/device/${push.deviceToken}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${jwt}`,
        "apns-topic": push.topic,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-expiration": String(Math.floor(Date.now() / 1000) + 4 * 3600),
        ...(push.collapseID === undefined ? {} : { "apns-collapse-id": push.collapseID }),
        "content-type": "application/json",
      },
      body: JSON.stringify(payload),
    });
  } catch (error) {
    // A network-level failure (reset, TLS) is transient like a 5xx: report
    // `failed` for this device instead of throwing — a throw would abort the
    // caller's whole per-device loop and 500 the request.
    return {
      status: "failed",
      httpStatus: 0,
      reason: error instanceof Error ? error.message : String(error),
    };
  }

  if (response.ok) {
    const apnsID = response.headers.get("apns-id");
    return { status: "sent", ...(apnsID === null ? {} : { apnsID }) };
  }
  let reason: string | undefined;
  try {
    const body: unknown = await response.json();
    if (typeof body === "object" && body !== null && "reason" in body && typeof body.reason === "string") {
      reason = body.reason;
    }
  } catch {
    // A body that is not JSON leaves the reason unknown.
  }
  // A rejected provider token would fail every push for the next 50 minutes;
  // dropping the cache makes the next call re-sign instead.
  if (reason === "ExpiredProviderToken" || reason === "InvalidProviderToken") {
    jwtCache.delete(credentials.keyID);
  }
  if (response.status === 410 || reason === "Unregistered" || reason === "BadDeviceToken") {
    return { status: "unregistered" };
  }
  return { status: "failed", httpStatus: response.status, ...(reason === undefined ? {} : { reason }) };
}

async function providerJWT(credentials: APNSCredentials): Promise<string> {
  const now = Date.now();
  const cached = jwtCache.get(credentials.keyID);
  if (cached && now - cached.issuedAt < JWT_LIFETIME_MS) return cached.token;

  const key = await privateKey(credentials);
  const header = base64URLJSON({ alg: "ES256", kid: credentials.keyID });
  const claims = base64URLJSON({ iss: credentials.teamID, iat: Math.floor(now / 1000) });
  const signingInput = `${header}.${claims}`;
  // WebCrypto ECDSA signatures are raw r||s — exactly the JOSE form.
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput),
  );
  const token = `${signingInput}.${base64URL(new Uint8Array(signature))}`;
  jwtCache.set(credentials.keyID, { token, issuedAt: now });
  return token;
}

async function privateKey(credentials: APNSCredentials): Promise<CryptoKey> {
  const cached = keyCache.get(credentials.keyID);
  if (cached) return cached;
  const der = pemToDER(credentials.privateKeyPEM);
  const key = await crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  keyCache.set(credentials.keyID, key);
  return key;
}

function pemToDER(pem: string): ArrayBuffer {
  const body = pem
    .replace(/-----BEGIN [A-Z ]+-----/gu, "")
    .replace(/-----END [A-Z ]+-----/gu, "")
    .replace(/\s+/gu, "");
  const binary = atob(body);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return bytes.buffer;
}

function base64URLJSON(value: unknown): string {
  return base64URL(new TextEncoder().encode(JSON.stringify(value)));
}
