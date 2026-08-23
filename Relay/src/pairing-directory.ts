import { DurableObject } from "cloudflare:workers";
import { hashCredential } from "./crypto";
import { loggerForEnv, shortID, type Logger } from "./log";
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
/**
 * The ceiling on guesses across every source. It trades two risks: lower
 * caps distributed brute force harder, higher makes it harder for a few
 * addresses to lock everyone out of pairing. 600/min against a 30-bit,
 * five-minute code is 3000 guesses per code (≈ 3 × 10⁻⁶) and needs 120
 * distinct /64s or IPv4 addresses to exhaust.
 */
const CLAIMS_PER_MINUTE = 600;

/**
 * Global singleton (`getByName("directory")`) that maps live pairing codes to
 * the Mac that issued them. It stores only SHA-256(code), the host ID and the
 * session ID: no commitment, keys or device details ever reach it.
 */
export class PairingDirectory extends DurableObject<Env> {
  private readonly log: Logger;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.log = loggerForEnv(env, "directory");
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
    const expired = sql.exec("DELETE FROM pairing_codes WHERE expires_at <= ?", Date.now()).rowsWritten;
    let attempts = 0;
    while (true) {
      attempts += 1;
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
      this.log.info("pairing_code_allocated", {
        hostID,
        sessionID: shortID(sessionID),
        expiresAt: new Date(expiresAt).toISOString(),
        attempts,
        expiredPurged: expired,
      });
      return code;
    }
  }

  /**
   * Spends a code: the first caller with an unexpired, unconsumed code learns
   * which host and session it belongs to; everyone else gets `invalid`.
   * Rate limits count every attempt, valid or not, so codes cannot be
   * brute-forced through this entry point. `source` is the caller's
   * per-source bucket (see `sourceBucket`), never logged or stored raw.
   */
  async claim(code: string, source: string): Promise<PairingClaimResult> {
    const sql = this.ctx.storage.sql;
    const sourceHash = await hashCredential(source);
    try {
      enforceRateLimit(sql, `claim-source:${sourceHash}`, CLAIMS_PER_SOURCE_PER_MINUTE, 60_000);
      enforceRateLimit(sql, "claim:global", CLAIMS_PER_MINUTE, 60_000);
    } catch (error) {
      if (error instanceof RateLimitError) {
        this.log.warn("pairing_claim_rate_limited", { source: shortID(sourceHash) });
        return { outcome: "rate_limited" };
      }
      throw error;
    }

    const normalized = normalizePairingCode(code);
    if (normalized === null) {
      this.log.info("pairing_claim_invalid", { reason: "malformed_code", source: shortID(sourceHash) });
      return { outcome: "invalid" };
    }
    const codeHash = await hashCredential(normalized);
    const now = Date.now();
    const row = sql.exec<PairingCodeRow>(
      "SELECT host_id, session_id, expires_at, consumed_at FROM pairing_codes WHERE code_hash = ?",
      codeHash,
    ).toArray()[0];
    if (!row || row.consumed_at !== null || row.expires_at <= now) {
      this.log.info("pairing_claim_invalid", {
        reason: !row ? "unknown_code" : row.consumed_at !== null ? "already_consumed" : "expired",
        source: shortID(sourceHash),
      });
      return { outcome: "invalid" };
    }
    sql.exec(
      "UPDATE pairing_codes SET consumed_at = ? WHERE code_hash = ? AND consumed_at IS NULL",
      now,
      codeHash,
    );
    this.log.info("pairing_code_claimed", { hostID: row.host_id, sessionID: shortID(row.session_id) });
    return { outcome: "claimed", hostID: row.host_id, sessionID: row.session_id };
  }

  /** Forgets the code of a session that ended before anyone claimed it. */
  async release(hostID: string, sessionID: string): Promise<void> {
    const released = this.ctx.storage.sql.exec(
      "DELETE FROM pairing_codes WHERE host_id = ? AND session_id = ?",
      hostID,
      sessionID,
    ).rowsWritten;
    if (released > 0) this.log.info("pairing_code_released", { hostID, sessionID: shortID(sessionID) });
    return Promise.resolve();
  }
}
