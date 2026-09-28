import Foundation

/// Finds sessions whose Claude process is gone (Ctrl+C does not fire Stop/SessionEnd).
public enum PIDLiveness {
    /// `kill(pid, 0)`: 0 = alive, EPERM = alive but not ours, ESRCH = gone.
    public static func systemIsAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Session ids whose recorded PID is dead. Sessions without a PID are never pruned here.
    public static func deadSessions(in sessions: [Session], isAlive: (Int32) -> Bool = systemIsAlive) -> [String] {
        sessions.compactMap { s in
            guard let pid = s.pid else { return nil }
            return isAlive(pid) ? nil : s.id
        }
    }
}
