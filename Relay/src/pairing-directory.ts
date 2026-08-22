import { DurableObject } from "cloudflare:workers";
import { hashCredential } from "./crypto";
import { generatePairingCode, normalizePairingCode } from "./pairing-code";
import { RATE_LIMITS_TABLE, RateLimitError, enforceRateLimit } from "./rate-limit";

interface PairingCodeRow {
  [key: string]: SqlStorageValue;
  host_id: string;
  session_id: string;
  expires_at: number;
  consumed_at: number | null;
}

export type PairingClaimResult =
  | { outcome: "claimed"; hostID: string; sessionID: string }
  | { outcome: "invalid" }
  | { outcome: "rate_limited" };

const CLAIMS_PER_SOURCE_PER_MINUTE = 5;
const CLAIMS_PER_MINUTE = 60;

/**
 * Global singleton (`getByName("directory")`) that maps live pairing codes to
 * the Mac that issued them. It stores only SHA-256(code), the host ID and the
 * session ID: no commitment, keys or device details ever reach it.
 */
export class PairingDirectory extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    void this.ctx.blockConcurrencyWhile(() => {
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS pairing_codes (
          code_hash TEXT PRIMARY KEY NOT NULL,
          host_id TEXT NOT NULL,
          session_id TEXT NOT NULL,
          expires_at INTEGER NOT NULL,
          consumed_at INTEGER
        );
        ${RATE_LIMITS_TABLE}
      `);
      return Promise.resolve();
    });
  }

  /** Issues a code that no live row currently uses and binds it to the session. */
  async allocate(hostID: string, sessionID: string, expiresAt: number): Promise<string> {
    const sql = this.ctx.storage.sql;
    sql.exec("DELETE FROM pairing_codes WHERE expires_at <= ?", Date.now());
    while (true) {
      const code = generatePairingCode();
      const codeHash = await hashCredential(code);
      const taken = sql.exec("SELECT 1 FROM pairing_codes WHERE code_hash = ?", codeHash).toArray().length > 0;
      if (taken) continue;
      sql.exec(
        `INSERT INTO pairing_codes(code_hash, host_id, session_id, expires_at, consumed_at)
         VALUES(?, ?, ?, ?, NULL)`,
        codeHash,
        hostID,
        sessionID,
        expiresAt,
      );
      return code;
    }
  }

  /**
   * Spends a code: the first caller with an unexpired, unconsumed code learns
   * which host and session it belongs to; everyone else gets `invalid`.
   * Rate limits count every attempt, valid or not, so codes cannot be
   * brute-forced through this entry point.
   */
  async claim(code: string, sourceIP: string): Promise<PairingClaimResult> {
    const sql = this.ctx.storage.sql;
    try {
      enforceRateLimit(sql, `claim-source:${await hashCredential(sourceIP)}`, CLAIMS_PER_SOURCE_PER_MINUTE, 60_000);
      enforceRateLimit(sql, "claim:global", CLAIMS_PER_MINUTE, 60_000);
    } catch (error) {
      if (error instanceof RateLimitError) return { outcome: "rate_limited" };
      throw error;
    }

    const normalized = normalizePairingCode(code);
    if (normalized === null) return { outcome: "invalid" };
    const codeHash = await hashCredential(normalized);
    const now = Date.now();
    const row = sql.exec<PairingCodeRow>(
      "SELECT host_id, session_id, expires_at, consumed_at FROM pairing_codes WHERE code_hash = ?",
      codeHash,
    ).toArray()[0];
    if (!row || row.consumed_at !== null || row.expires_at <= now) return { outcome: "invalid" };
    sql.exec(
      "UPDATE pairing_codes SET consumed_at = ? WHERE code_hash = ? AND consumed_at IS NULL",
      now,
      codeHash,
    );
    return { outcome: "claimed", hostID: row.host_id, sessionID: row.session_id };
  }

  /** Forgets the code of a session that ended before anyone claimed it. */
  async release(hostID: string, sessionID: string): Promise<void> {
    this.ctx.storage.sql.exec(
      "DELETE FROM pairing_codes WHERE host_id = ? AND session_id = ?",
      hostID,
      sessionID,
    );
    return Promise.resolve();
  }
}
