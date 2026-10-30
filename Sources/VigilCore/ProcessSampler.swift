import Darwin
import Foundation

/// One process, as far as the sampler needs it.
public struct ProcessEntry: Equatable, Sendable {
    public var pid: Int32
    public var ppid: Int32
    /// The full command line (empty when it cannot be read).
    public var args: String
    /// User + system CPU time used so far, in seconds.
    public var cpuTime: TimeInterval

    public init(pid: Int32, ppid: Int32, args: String, cpuTime: TimeInterval) {
        self.pid = pid
        self.ppid = ppid
        self.args = args
        self.cpuTime = cpuTime
    }
}

/// Reads the process table: every pid with its parent, and the command line and CPU time of the descendants of the
/// given roots (reading those for every process would cost too much). Own-user processes only, no permissions.
public enum ProcessTableReader {
    public static func descendants(of roots: Set<Int32>) -> [ProcessEntry] {
        guard !roots.isEmpty else { return [] }
        var parents: [Int32: Int32] = [:]
        for (pid, ppid) in allPIDs() { parents[pid] = ppid }
        var children: [Int32: [Int32]] = [:]
        for (pid, ppid) in parents { children[ppid, default: []].append(pid) }
        var result: [ProcessEntry] = []
        var queue = Array(roots.filter { parents[$0] != nil })
        var seen = Set<Int32>()
        while let pid = queue.popLast() {
            guard seen.insert(pid).inserted else { continue }
            result.append(ProcessEntry(pid: pid, ppid: parents[pid] ?? 0, args: arguments(pid), cpuTime: cpuTime(pid)))
            queue += children[pid] ?? []
        }
        return result
    }

    private static func allPIDs() -> [(Int32, Int32)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        size += size / 8 // processes may appear between the two calls
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride).map { ($0.kp_proc.p_pid, $0.kp_eproc.e_ppid) }
    }

    /// KERN_PROCARGS2: argc, the executable path, then argv. Joined with spaces.
    static func arguments(_ pid: Int32) -> String {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return "" }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return "" }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 } // executable path
        while index < size, buffer[index] == 0 { index += 1 } // padding
        var args: [String] = []
        var start = index
        while index < size, args.count < argc {
            if buffer[index] == 0 {
                args.append(String(decoding: buffer[start..<index], as: UTF8.self))
                start = index + 1
            }
            index += 1
        }
        return args.joined(separator: " ")
    }

    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info.denom == 0 ? 1 : Double(info.numer) / Double(info.denom)
    }()

    /// proc_pidinfo reports CPU time in Mach absolute time units.
    static func cpuTime(_ pid: Int32) -> TimeInterval {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return 0 }
        return Double(info.pti_total_user + info.pti_total_system) * timebase / 1_000_000_000
    }
}

/// Turns process-table samples into `ProcessObservation`s: which background shell is which process, whether it is
/// still running, how much CPU its process tree used, and whether a session's processes changed at all (activity
/// for the silence failsafe). Pure: the table comes in, nothing is read here.
public struct ShellProcessTracker {
    /// What the tracker needs to know about a session.
    public struct SessionInfo: Equatable, Sendable {
        public var id: String
        public var pid: Int32
        public var shells: [(id: String, command: String)]

        public init(id: String, pid: Int32, shells: [(id: String, command: String)]) {
            self.id = id
            self.pid = pid
            self.shells = shells
        }

        public static func == (a: SessionInfo, b: SessionInfo) -> Bool {
            a.id == b.id && a.pid == b.pid && a.shells.map(\.id) == b.shells.map(\.id) && a.shells.map(\.command) == b.shells.map(\.command)
        }
    }

    /// CPU is averaged over this window (the server rule).
    public var window: TimeInterval
    /// CPU used by a session's processes between two samples that counts as activity.
    public var activityCPU: TimeInterval = 0.2

    private struct ShellState {
        var pid: Int32?
        var samples: [(date: Date, cpu: TimeInterval)] = []
    }

    private var shells: [String: ShellState] = [:]
    private var lastPIDs: [String: Set<Int32>] = [:]
    private var lastCPU: [String: TimeInterval] = [:]

    public init(window: TimeInterval = 5 * 60) {
        self.window = window
    }

    /// Processes that are never work: Claude Code's own caffeinate, MCP servers, language servers, Vigil's scripts.
    public static func isHelper(_ args: String) -> Bool {
        let a = args.lowercased()
        if a.hasPrefix("caffeinate") || a.hasPrefix("/usr/bin/caffeinate") { return true }
        return ["mcp", "language-server", "languageserver", "-lsp", "lsp-", "vigil/hook.sh", "vigil/statusline.sh",
                "--chrome-native-host"].contains { a.contains($0) }
    }

    /// Whitespace, quotes and backslashes removed: `eval 'it'\''s'` and `it's` compare equal.
    static func normalized(_ s: String) -> String {
        String(s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != "'" && $0 != "\"" && $0 != "\\" })
    }

    public mutating func observe(_ table: [ProcessEntry], sessions: [SessionInfo], at now: Date) -> [ProcessObservation] {
        let byPID = Dictionary(table.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var children: [Int32: [Int32]] = [:]
        for p in table { children[p.ppid, default: []].append(p.pid) }
        func subtree(_ root: Int32) -> [ProcessEntry] {
            var out: [ProcessEntry] = []
            var queue = [root]
            var seen = Set<Int32>()
            while let pid = queue.popLast() {
                guard seen.insert(pid).inserted, let p = byPID[pid] else { continue }
                out.append(p)
                queue += children[pid] ?? []
            }
            return out
        }

        var observations: [ProcessObservation] = []
        var liveShellKeys = Set<String>()
        var liveSessions = Set<String>()
        for session in sessions {
            liveSessions.insert(session.id)
            let work = subtree(session.pid).filter { $0.pid != session.pid && !Self.isHelper($0.args) }
            let pids = Set(work.map(\.pid))
            let cpu = work.reduce(0) { $0 + $1.cpuTime }
            var activity = false
            if let old = lastPIDs[session.id] {
                activity = old != pids || cpu - (lastCPU[session.id] ?? cpu) >= activityCPU
            }
            lastPIDs[session.id] = pids
            lastCPU[session.id] = cpu

            var seen: [String: ShellObservation] = [:]
            // Two shells with the same command must not both claim one process.
            var claimed = Set(session.shells.compactMap { shells[session.id + "/" + $0.id]?.pid })
            for shell in session.shells {
                let key = session.id + "/" + shell.id
                liveShellKeys.insert(key)
                var state = shells[key] ?? ShellState()
                if let pid = state.pid, byPID[pid] == nil {
                    // It was running and is gone: the shell has ended.
                    seen[shell.id] = ShellObservation(found: false, exited: true)
                    shells[key] = nil
                    continue
                }
                if state.pid == nil {
                    let needle = Self.normalized(shell.command)
                    // The topmost match: Claude Code's wrapper shell, whose subtree holds the command's processes.
                    state.pid = needle.isEmpty ? nil : work.first { p in
                        !claimed.contains(p.pid) && Self.normalized(p.args).contains(needle)
                            && !(byPID[p.ppid].map { Self.normalized($0.args).contains(needle) && $0.pid != session.pid } ?? false)
                    }?.pid
                }
                if let pid = state.pid { claimed.insert(pid) }
                guard let pid = state.pid else {
                    shells[key] = state
                    seen[shell.id] = ShellObservation(found: false)
                    continue
                }
                let total = subtree(pid).reduce(0) { $0 + $1.cpuTime }
                state.samples.append((now, total))
                state.samples.removeAll { now.timeIntervalSince($0.date) > window + 60 }
                var percent: Double?
                if let oldest = state.samples.first, now.timeIntervalSince(oldest.date) >= window {
                    percent = max(0, total - oldest.cpu) / now.timeIntervalSince(oldest.date) * 100
                }
                shells[key] = state
                seen[shell.id] = ShellObservation(found: true, cpuPercent: percent)
            }
            observations.append(ProcessObservation(sessionID: session.id, activity: activity, shells: seen))
        }
        shells = shells.filter { liveShellKeys.contains($0.key) }
        lastPIDs = lastPIDs.filter { liveSessions.contains($0.key) }
        lastCPU = lastCPU.filter { liveSessions.contains($0.key) }
        return observations
    }
}
