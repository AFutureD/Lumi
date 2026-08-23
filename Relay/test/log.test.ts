import { describe, expect, it } from "vitest";
import { Logger, formatLogLine, logLevelFromEnv, shortID } from "../src/log";
import { routeName } from "../src/index";

describe("structured logging", () => {
  it("renders one JSON object per line: ts, level, subsystem, category, then event and fields", () => {
    const line = formatLogLine("info", "ws", "ws_opened", { role: "host", deviceID: undefined, count: 2 }, new Date(0));
    expect(line).toBe('{"ts":"1970-01-01T00:00:00.000Z","level":"info","subsystem":"relay","category":"ws","event":"ws_opened","role":"host","count":2}');
  });

  it("hoists the trace ahead of the event", () => {
    const line = formatLogLine("info", "http", "http_request", { status: 200, trace: "8f3a-ray" }, new Date(0));
    expect(line).toBe('{"ts":"1970-01-01T00:00:00.000Z","level":"info","subsystem":"relay","category":"http","trace":"8f3a-ray","event":"http_request","status":200}');
    expect(formatLogLine("info", "http", "x", { trace: undefined }, new Date(0))).not.toContain("trace");
  });

  it("describes errors by name and message only", () => {
    const line = formatLogLine("error", "http", "request_failed", { error: new TypeError("boom") }, new Date(0));
    expect(JSON.parse(line)).toMatchObject({ level: "error", error: { name: "TypeError", message: "boom" } });
  });

  it("drops lines below the configured level and keeps base fields on children", () => {
    const seen: string[] = [];
    const original = console.log;
    console.log = (line: string) => { seen.push(line); };
    try {
      const log = new Logger("http", "info").child({ hostID: "host-1" });
      log.debug("hidden");
      log.info("shown", { n: 1 });
      expect(log.fields).toEqual({ hostID: "host-1" });
      expect(log.withCategory("ws").category).toBe("ws");
    } finally {
      console.log = original;
    }
    expect(seen).toHaveLength(1);
    expect(JSON.parse(seen[0] ?? "{}")).toMatchObject({ event: "shown", category: "http", hostID: "host-1", n: 1 });
  });

  it("reads LOG_LEVEL leniently", () => {
    expect(logLevelFromEnv({ LOG_LEVEL: "DEBUG" })).toBe("debug");
    expect(logLevelFromEnv({ LOG_LEVEL: "warning" })).toBe("warn");
    expect(logLevelFromEnv({ LOG_LEVEL: "loud" })).toBe("info");
    expect(logLevelFromEnv({})).toBe("info");
  });

  it("shortens capability-bearing ids", () => {
    expect(shortID("abcdefghijklmnop")).toBe("abcdefgh…");
    expect(shortID("short")).toBe("short");
    expect(shortID(null)).toBeUndefined();
  });

  it("names routes without host, device or session ids", () => {
    expect(routeName("GET", "/health")).toBe("GET /health");
    expect(routeName("POST", "/v1/pairing/claim")).toBe("POST /v1/pairing/claim");
    expect(routeName("PUT", "/v1/hosts/host-abc")).toBe("PUT /v1/hosts/:host");
    expect(routeName("POST", "/v1/hosts/host-abc/pairing-sessions/SESSIONSECRET/device"))
      .toBe("POST /v1/hosts/:host/pairing-sessions/:id/device");
    expect(routeName("DELETE", "/v1/hosts/host-abc/devices/device-1")).toBe("DELETE /v1/hosts/:host/devices/:id");
    expect(routeName("GET", "/v1/hosts/host-abc/ws")).toBe("GET /v1/hosts/:host/ws");
  });
});
