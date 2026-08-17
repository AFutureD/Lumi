import fixture from "../../Common/AgentStatusTransport/Sources/AgentStatusTransport/Resources/transport-v1.json";
import { describe, expect, it } from "vitest";
import { parseRelayRoutingFrame } from "../src/protocol";

describe("shared transport fixture", () => {
  it("accepts the Swift package routing frame", () => {
    const frame = parseRelayRoutingFrame(fixture);
    expect(frame.version).toEqual({ major: 1, minor: 0 });
    expect(frame.hostID).toBe("host-fixture");
    expect(frame.deviceID).toBe("device-fixture");
    expect(frame.sequence).toBe(42);
  });
});
