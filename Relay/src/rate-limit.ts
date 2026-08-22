export class RateLimitError extends Error {}

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
