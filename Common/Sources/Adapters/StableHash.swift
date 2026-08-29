public enum StableHash {
    /// FNV-1a. Event IDs must be reproducible across processes and daemon
    /// restarts; Swift's `hashValue` is seeded per launch and is not.
    public static func fnv1a(_ value: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return hash
    }
}
