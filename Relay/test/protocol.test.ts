import fixture from "../../Common/Transport/Sources/Transport/Resources/transport-v1.json";
import { describe, expect, it } from "vitest";
import { RequestValidationError, encodeBinaryFrame, parseBinaryFrame, parseRelayRoutingFrame } from "../src/protocol";

describe("shared transport fixture", () => {
  it("accepts the Swift package routing header", () => {
    const body = Uint8Array.from(atob(fixture.ciphertext), (c) => c.charCodeAt(0));
    const frame = parseRelayRoutingFrame(fixture, body.byteLength);
    expect(frame.version).toEqual({ major: 1, minor: 6 });
    expect(frame.hostID).toBe("host-fixture");
    expect(frame.deviceID).toBe("device-fixture");
    expect(frame.sequence).toBe(42);
    expect(frame.bodyBytes).toBe(4);
  });
});

describe("binary frames", () => {
  const header = {
    version: { major: 1, minor: 6 },
    hostID: "host-fixture",
    deviceID: "device-fixture",
    sequence: 7,
    kind: "data",
    nonce: "AAECAwQFBgcICQoL",
  };

  it("round-trips a header and keeps the body size", () => {
    const frame = parseBinaryFrame(encodeBinaryFrame(header, new Uint8Array(1234)));
    expect(frame).toEqual({ ...header, bodyBytes: 1234 });
  });

  it("rejects a sealed kind without a body, a truncated header and an oversized header", () => {
    expect(() => parseBinaryFrame(encodeBinaryFrame(header, new Uint8Array()))).toThrow(RequestValidationError);
    expect(() => parseBinaryFrame(new Uint8Array([0, 0, 0, 9, 1]).buffer)).toThrow(RequestValidationError);
    const huge = new Uint8Array(8);
    new DataView(huge.buffer).setUint32(0, 1_000_000, false);
    expect(() => parseBinaryFrame(huge.buffer)).toThrow(RequestValidationError);
  });

  it("refuses another protocol major", () => {
    expect(() => parseBinaryFrame(encodeBinaryFrame({ ...header, version: { major: 2, minor: 0 } }, new Uint8Array(1)))).toThrow(RequestValidationError);
  });
});
