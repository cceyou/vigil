import CoreGraphics
import Darwin
import Foundation
import IOKit.pwr_mgt

/// Reads a fresh `PresenceSnapshot` from the system. None of this needs a permission prompt:
/// the lid from IOPMrootDomain's AppleClamshellState, displays from CGGetActiveDisplayList + CGDisplayIsBuiltin,
/// input idle time from CGEventSource (combined session state, any input event), assertions from
/// IOPMCopyAssertionsByProcess.
public enum PresenceReader {
    public static func snapshot() -> PresenceSnapshot {
        PresenceSnapshot(lidClosed: BatteryThermalMonitor.readLidClosed(), externalDisplays: externalDisplayCount(),
                         idleSeconds: inputIdleSeconds(), assertions: assertions(),
                         ownPID: ProcessInfo.processInfo.processIdentifier)
    }

    public static func externalDisplayCount() -> Int {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return 0 }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return 0 }
        return ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }.count
    }

    /// Seconds since the last keyboard, mouse or trackpad event (kCGAnyInputEventType).
    public static func inputIdleSeconds() -> TimeInterval {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    public static func assertions() -> [PowerAssertion] {
        var out: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&out) == kIOReturnSuccess,
              let byProcess = out?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        var list: [PowerAssertion] = []
        for (pidNumber, entries) in byProcess {
            let pid = pidNumber.int32Value
            for e in entries {
                guard let type = e["AssertType"] as? String, SleepGate.blockingTypes.contains(type) else { continue }
                let process = (e["Process Name"] as? String) ?? processName(pid) ?? "pid \(pid)"
                let parent = process == "caffeinate" ? ProcessTree.parent(of: pid).map(parentName) : nil
                list.append(PowerAssertion(pid: pid, process: process, type: type, name: (e["AssertName"] as? String) ?? "",
                                           parentProcess: parent))
            }
        }
        return list.sorted { ($0.pid, $0.name) < ($1.pid, $1.name) }
    }

    /// "claude" for Claude Code (whatever its binary is called), else the process name.
    static func parentName(_ pid: Int32) -> String {
        let name = processName(pid)
        return SleepGate.isClaudeCode(executablePath: executablePath(pid), processName: name) ? "claude" : (name ?? "pid \(pid)")
    }

    static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    static func processName(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
