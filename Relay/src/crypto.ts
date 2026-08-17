export function randomCredential(byteLength = 32): string {
  const bytes = crypto.getRandomValues(new Uint8Array(byteLength));
  return base64URL(bytes);
}

export async function hashCredential(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return base64URL(new Uint8Array(digest));
}

export function timingSafeStringEqual(lhs: string, rhs: string): boolean {
  const lhsBytes = new TextEncoder().encode(lhs);
  const rhsBytes = new TextEncoder().encode(rhs);
  if (lhsBytes.byteLength !== rhsBytes.byteLength) return false;
  return timingSafeEqual(lhsBytes, rhsBytes);
}

export function bearerToken(request: Request): string | null {
  const header = request.headers.get("authorization");
  if (!header?.startsWith("Bearer ")) return null;
  const token = header.slice("Bearer ".length).trim();
  return token.length > 0 ? token : null;
}

export function base64URL(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/u, "");
}
import { timingSafeEqual } from "node:crypto";
