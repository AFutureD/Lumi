import { describe, expect, it } from "vitest";
import {
  PAIRING_CODE_ALPHABET,
  PAIRING_CODE_LENGTH,
  generatePairingCode,
  normalizePairingCode,
} from "../src/pairing-code";

describe("pairing codes", () => {
  it("generates six symbols from the Crockford alphabet", () => {
    const seen = new Set<string>();
    for (let i = 0; i < 200; i += 1) {
      const code = generatePairingCode();
      expect(code).toHaveLength(PAIRING_CODE_LENGTH);
      for (const symbol of code) expect(PAIRING_CODE_ALPHABET).toContain(symbol);
      seen.add(code);
    }
    expect(seen.size).toBeGreaterThan(190);
  });

  it("normalizes case, separators and look-alike letters", () => {
    expect(normalizePairingCode("7kf 3qp")).toBe("7KF3QP");
    expect(normalizePairingCode("7KF-3QP")).toBe("7KF3QP");
    expect(normalizePairingCode("oil u12")).toBe("011V12");
    expect(normalizePairingCode("  AB CD EF ")).toBe("ABCDEF");
  });

  it("rejects codes of the wrong length or alphabet", () => {
    expect(normalizePairingCode("7KF3Q")).toBeNull();
    expect(normalizePairingCode("7KF3QPA")).toBeNull();
    expect(normalizePairingCode("7KF3Q*")).toBeNull();
    expect(normalizePairingCode("")).toBeNull();
    expect(normalizePairingCode("7KF3Qé")).toBeNull();
  });
});
