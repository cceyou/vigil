import Darwin
import Foundation

/// Parent-process lookup (sysctl KERN_PROC_PID), used to walk from a Claude Code PID up to the app that owns it.
public enum ProcessTree {
    public static func parent(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }

    /// `pid` and its ancestors, nearest first, stopping before launchd (pid 1). At most `limit` entries.
    public static func ancestry(of pid: Int32, limit: Int = 32) -> [Int32] {
        var chain: [Int32] = []
        var current: Int32? = pid
        while let p = current, p > 1, chain.count < limit, !chain.contains(p) {
            chain.append(p)
            current = parent(of: p)
        }
        return chain
    }
}
