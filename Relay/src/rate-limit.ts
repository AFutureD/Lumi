export class RateLimitError extends Error {}

/**
 * The string a per-source limit counts under. An IPv4 address counts by
 * itself; an IPv6 address counts by its /64, the smallest block one
 * subscriber normally holds — otherwise a single host could rotate through
 * 2^64 addresses and never meet a per-source limit. Anything that does not
 * parse counts as itself.
 */
export function sourceBucket(address: string): string {
  const trimmed = address.trim();
  if (!trimmed.includes(":")) return trimmed;
  const groups = expandIPv6(trimmed);
  if (groups === null) return trimmed;
  const [g0, g1, g2, g3, g4, g5, g6, g7] = groups;
  if (g0 === 0 && g1 === 0 && g2 === 0 && g3 === 0 && g4 === 0 && g5 === 0xffff && g6 !== undefined && g7 !== undefined) {
    // IPv4-mapped: count as the embedded IPv4 address.
    return `${g6 >> 8}.${g6 & 0xff}.${g7 >> 8}.${g7 & 0xff}`;
  }
  return `${[g0, g1, g2, g3].map((group) => (group ?? 0).toString(16)).join(":")}::/64`;
}

/** The eight 16-bit groups of an IPv6 address, or null when it is malformed. */
function expandIPv6(address: string): number[] | null {
  let text = address.replace(/^\[|\]$/gu, "");
  const zone = text.indexOf("%");
  if (zone !== -1) text = text.slice(0, zone);

  // An embedded dotted IPv4 tail (`::ffff:1.2.3.4`) becomes two hex groups.
  const lastColon = text.lastIndexOf(":");
  const tail = text.slice(lastColon + 1);
  if (tail.includes(".")) {
    const octets = tail.split(".").map((part) => (/^\d{1,3}$/u.test(part) ? Number(part) : NaN));
    const [a, b, c, d] = octets;
    if (octets.length !== 4 || a === undefined || b === undefined || c === undefined || d === undefined
      || octets.some((octet) => Number.isNaN(octet) || octet > 255)) {
      return null;
    }
    text = `${text.slice(0, lastColon + 1)}${((a << 8) | b).toString(16)}:${((c << 8) | d).toString(16)}`;
  }

  const halves = text.split("::");
  if (halves.length > 2) return null;
  const head = halves[0] === "" || halves[0] === undefined ? [] : halves[0].split(":");
  const rest = halves.length === 2 && halves[1] !== undefined && halves[1] !== "" ? halves[1].split(":") : [];
  const missing = 8 - head.length - rest.length;
  if (halves.length === 2 ? missing < 1 : missing !== 0) return null;
  const groups = [...head, ...Array<string>(missing).fill("0"), ...rest];
  const values = groups.map((group) => (/^[0-9a-fA-F]{1,4}$/u.test(group) ? Number.parseInt(group, 16) : NaN));
  return values.some(Number.isNaN) ? null : values;
}

export const RATE_LIMITS_TABLE = `
  CREATE TABLE IF NOT EXISTS rate_limits (
    key TEXT PRIMARY KEY NOT NULL,
    window_started_at INTEGER NOT NULL,
    count INTEGER NOT NULL
  );
`;

/**
 * Fixed-window counter in the caller's SQLite `rate_limits` table. Throws
 * `RateLimitError` once `limit` hits land inside the same window.
 */
export function enforceRateLimit(
  sql: SqlStorage,
  key: string,
  limit: number,
  windowMilliseconds: number,
): void {
  const now = Date.now();
  const row = sql.exec<{ window_started_at: number; count: number }>(
    "SELECT window_started_at, count FROM rate_limits WHERE key = ?",
    key,
  ).toArray()[0];
  if (!row || now - row.window_started_at >= windowMilliseconds) {
    sql.exec(
      "INSERT OR REPLACE INTO rate_limits(key, window_started_at, count) VALUES(?, ?, 1)",
      key,
      now,
    );
    // Windows that closed long ago are dead weight: drop them on the way.
    sql.exec("DELETE FROM rate_limits WHERE window_started_at < ?", now - 10 * windowMilliseconds);
    return;
  }
  if (row.count >= limit) throw new RateLimitError("Rate limit exceeded.");
  sql.exec("UPDATE rate_limits SET count = count + 1 WHERE key = ?", key);
}
