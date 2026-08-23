/**
 * Structured logging for the Worker and its Durable Objects — the Relay's
 * counterpart of the Swift `AgentStatusLogging` module.
 *
 * One JSON object per line: `{"ts","level","subsystem":"relay","category",
 * "trace"?, "event", ...fields}`, so `wrangler tail` and Workers Logs can
 * filter on any column. The business code chooses a category when it
 * declares its logger (`new Logger("ws")`) and then only supplies the event
 * and its fields; subsystem, level gate, timestamp and trace placement are
 * the logger's. Levels below `LOG_LEVEL` (wrangler var, default `info`) are
 * dropped before the object is built; `error` lines go through
 * `console.error`, warnings through `console.warn`, the rest `console.log`.
 *
 * Fields carry identifiers, counts, sizes, states and durations. They never
 * carry credentials (host secrets, device tokens), pairing codes, nonces,
 * commitments, keys or ciphertext: a full pairing session id is a bearer
 * capability and is shortened with `shortID` before it is logged.
 */

export type LogLevel = "debug" | "info" | "warn" | "error";

export const SUBSYSTEM = "relay";

const LEVEL_RANK: Record<LogLevel, number> = { debug: 0, info: 1, warn: 2, error: 3 };

export type LogFields = Record<string, unknown>;

export class Logger {
  readonly category: string;
  readonly level: LogLevel;
  /** Fields stamped on every line of this logger (`{hostID}`, `{trace}`). */
  readonly fields: Readonly<LogFields>;

  constructor(category: string, level: LogLevel = "info", fields: LogFields = {}) {
    this.category = category;
    this.level = level;
    this.fields = fields;
  }

  /** Same category and level, extra fields on every line. */
  child(fields: LogFields): Logger {
    return new Logger(this.category, this.level, { ...this.fields, ...fields });
  }

  /** Same level and base fields, another category. */
  withCategory(category: string): Logger {
    return new Logger(category, this.level, { ...this.fields });
  }

  enabled(level: LogLevel): boolean {
    return LEVEL_RANK[level] >= LEVEL_RANK[this.level];
  }

  debug(event: string, fields: LogFields = {}): void {
    this.emit("debug", event, fields);
  }

  info(event: string, fields: LogFields = {}): void {
    this.emit("info", event, fields);
  }

  warn(event: string, fields: LogFields = {}): void {
    this.emit("warn", event, fields);
  }

  error(event: string, fields: LogFields = {}): void {
    this.emit("error", event, fields);
  }

  private emit(level: LogLevel, event: string, fields: LogFields): void {
    if (!this.enabled(level)) return;
    const line = formatLogLine(level, this.category, event, { ...this.fields, ...fields });
    if (level === "error") console.error(line);
    else if (level === "warn") console.warn(line);
    else console.log(line);
  }
}

/**
 * `{"ts","level","subsystem","category","trace"?,"event",...fields}`:
 * `trace` (when present in the fields) is hoisted ahead of the event;
 * `undefined` fields are dropped; errors become `{name,message}`.
 */
export function formatLogLine(level: LogLevel, category: string, event: string, fields: LogFields, now = new Date()): string {
  const record: LogFields = { ts: now.toISOString(), level, subsystem: SUBSYSTEM, category };
  if (fields.trace !== undefined && fields.trace !== null && fields.trace !== "") record.trace = fields.trace;
  record.event = event;
  for (const [key, value] of Object.entries(fields)) {
    if (value === undefined || key === "trace") continue;
    record[key] = value instanceof Error ? describeError(value) : value;
  }
  return JSON.stringify(record);
}

export function describeError(error: unknown): { name: string; message: string } {
  if (error instanceof Error) return { name: error.name, message: error.message };
  return { name: "Error", message: String(error) };
}

/** Reads `LOG_LEVEL` from the Worker environment; anything unknown means `info`. */
export function logLevelFromEnv(env: { LOG_LEVEL?: string | undefined }): LogLevel {
  const value = env.LOG_LEVEL?.trim().toLowerCase();
  if (value === "debug" || value === "info" || value === "warn" || value === "error") return value;
  if (value === "warning") return "warn";
  return "info";
}

export function loggerForEnv(env: { LOG_LEVEL?: string | undefined }, category: string, fields: LogFields = {}): Logger {
  return new Logger(category, logLevelFromEnv(env), fields);
}

/** The request's trace id: Cloudflare's `cf-ray`, the one id that also shows in the dashboard. */
export function traceID(request: Request): string | undefined {
  return request.headers.get("cf-ray") ?? undefined;
}

/** First 8 characters of a capability-bearing id (pairing session, token hash). */
export function shortID(value: string | null | undefined): string | undefined {
  if (value === null || value === undefined) return undefined;
  return value.length > 8 ? `${value.slice(0, 8)}…` : value;
}

/** Whole milliseconds since `startedAt` (a `Date.now()` stamp). */
export function elapsedMs(startedAt: number): number {
  return Math.max(0, Date.now() - startedAt);
}
