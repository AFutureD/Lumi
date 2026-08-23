import { describe, expect, it } from "vitest";
import { sourceBucket } from "../src/rate-limit";

describe("sourceBucket", () => {
  it("counts IPv4 addresses individually", () => {
    expect(sourceBucket("203.0.113.9")).toBe("203.0.113.9");
    expect(sourceBucket(" 203.0.113.9 ")).toBe("203.0.113.9");
    expect(sourceBucket("local")).toBe("local");
  });

  it("folds IPv6 addresses onto their /64", () => {
    expect(sourceBucket("2001:db8:1:2::1")).toBe("2001:db8:1:2::/64");
    expect(sourceBucket("2001:0db8:0001:0002:ffff:ffff:ffff:ffff")).toBe("2001:db8:1:2::/64");
    expect(sourceBucket("2001:db8:1:2:abcd:ef01:2345:6789")).toBe(sourceBucket("2001:db8:1:2::1"));
    expect(sourceBucket("2001:db8:1:3::1")).not.toBe(sourceBucket("2001:db8:1:2::1"));
    expect(sourceBucket("::1")).toBe("0:0:0:0::/64");
    expect(sourceBucket("[2001:db8::5]")).toBe("2001:db8:0:0::/64");
    expect(sourceBucket("fe80::1%en0")).toBe("fe80:0:0:0::/64");
    expect(sourceBucket("1:2:3:4:5:6:7::")).toBe("1:2:3:4::/64");
  });

  it("counts an IPv4-mapped address as the embedded IPv4", () => {
    expect(sourceBucket("::ffff:203.0.113.9")).toBe("203.0.113.9");
    expect(sourceBucket("::ffff:cb00:7109")).toBe("203.0.113.9");
  });

  it("counts malformed IPv6 as itself", () => {
    expect(sourceBucket("1::2::3")).toBe("1::2::3");
    expect(sourceBucket("2001:db8:1:2:3:4:5:6:7")).toBe("2001:db8:1:2:3:4:5:6:7");
    expect(sourceBucket("::ffff:300.1.1.1")).toBe("::ffff:300.1.1.1");
    expect(sourceBucket("gggg::1")).toBe("gggg::1");
  });
});
