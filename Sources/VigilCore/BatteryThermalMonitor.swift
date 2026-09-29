import Foundation
import IOKit
import IOKit.ps

/// Reads lid state (AppleClamshellState), power source / battery level and thermal state.
public final class BatteryThermalMonitor: @unchecked Sendable {
    private var timer: DispatchSourceTimer?
    private var observer: NSObjectProtocol?
    private var last: Environment?
    private let queue = DispatchQueue(label: "cz.krystof.vigil.environment")

    public init() {}

    public static func snapshot() -> Environment {
        var env = Environment()
        env.lidClosed = readLidClosed()
        (env.onBattery, env.batteryPercent, env.isCharging) = readBattery()
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: env.thermal = .nominal
        case .fair: env.thermal = .fair
        case .serious: env.thermal = .serious
        case .critical: env.thermal = .critical
        @unknown default: env.thermal = .nominal
        }
        return env
    }

    static func readLidClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? Bool) ?? false
    }

    static func readBattery() -> (onBattery: Bool, percent: Int?, charging: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (false, nil, false) }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let onBattery = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
            let current = desc[kIOPSCurrentCapacityKey] as? Int
            let max = desc[kIOPSMaxCapacityKey] as? Int
            var percent: Int?
            if let current, let max, max > 0 { percent = Int((Double(current) / Double(max) * 100).rounded()) }
            let charging = !onBattery && (desc[kIOPSIsChargingKey] as? Bool ?? false)
            return (onBattery, percent, charging)
        }
        return (false, nil, false)
    }

    /// Calls `onChange` when anything changes (polled every 2 s, plus immediately on thermal notifications).
    public func start(onChange: @escaping @Sendable (Environment) -> Void) {
        let check: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            let now = Self.snapshot()
            if now != self.last { self.last = now; onChange(now) }
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 2)
        t.setEventHandler(handler: check)
        t.resume()
        timer = t
        observer = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                                          object: nil, queue: nil) { [queue] _ in queue.async(execute: check) }
    }

    public func stop() {
        timer?.cancel(); timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}
