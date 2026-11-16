import Foundation

/// The process's open-file budget. launchd starts an agent with a soft limit
/// of 256 descriptors; the session watchers hold one per watched file on top
/// of the database, the sockets and the logs.
public enum OpenFileLimit {
    /// Raises the soft limit towards `target` (never past the hard limit)
    /// and returns the soft limit in force afterwards.
    public static func raise(to target: UInt64) -> UInt64 {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return 0 }
        guard limit.rlim_cur < target else { return UInt64(limit.rlim_cur) }
        let previous = limit.rlim_cur
        limit.rlim_cur = min(rlim_t(target), limit.rlim_max)
        guard setrlimit(RLIMIT_NOFILE, &limit) == 0 else { return UInt64(previous) }
        return UInt64(limit.rlim_cur)
    }

    /// How many files each of `watchers` may watch under a soft limit of
    /// `limit`: half of what is left after `reserved` descriptors for the
    /// rest of the daemon, split evenly, and at most `ceiling` each.
    public static func watchBudget(limit: UInt64, watchers: Int, reserved: UInt64 = 128, ceiling: Int = 256) -> Int {
        guard limit > reserved, watchers > 0 else { return 0 }
        return min(ceiling, Int((limit - reserved) / 2) / watchers)
    }
}
