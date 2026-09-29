import Foundation
import UserNotifications

public enum NotificationAction: Sendable { case cancel, keepAwake }

/// Countdown / guard notifications. Needs a real .app bundle (UserNotifications crashes otherwise), so it
/// silently does nothing when run from `swift run` or tests.
public final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    public static let countdownID = "vigil.countdown"
    private static let category = "vigil.countdown.category"

    public var onAction: (@Sendable (NotificationAction) -> Void)?

    public static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    private var center: UNUserNotificationCenter? { Self.isAvailable ? UNUserNotificationCenter.current() : nil }

    public override init() { super.init() }

    public func setUp() {
        guard let center else { return }
        center.delegate = self
        let cancel = UNNotificationAction(identifier: "cancel", title: L("Cancel"), options: [])
        let keep = UNNotificationAction(identifier: "keepAwake", title: L("Keep awake"), options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [cancel, keep],
                                                                 intentIdentifiers: [], options: [])])
    }

    public func requestAuthorization() async -> Bool {
        guard let center else {
            Log.shared.warning("notifications: not running from an .app bundle, cannot request authorization")
            return false
        }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            Log.shared.info("notifications: authorization request finished, granted=\(granted)")
            return granted
        } catch {
            Log.shared.error("notifications: authorization request failed: \(error)")
            return false
        }
    }

    /// Raw macOS authorization state as a readable word (nil outside an .app bundle).
    public func authorizationState() async -> String? {
        guard let center else { return nil }
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }

    public func isAuthorized() async -> Bool {
        guard let center else { return false }
        let s = await center.notificationSettings().authorizationStatus
        return s == .authorized || s == .provisional
    }

    public func postCountdown(deadline: Date, seconds: Int) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = L("Claude Code has finished")
        content.body = L("Your Mac goes to sleep in %d seconds.", seconds)
        content.categoryIdentifier = Self.category
        content.sound = .default
        center.add(UNNotificationRequest(identifier: Self.countdownID, content: content, trigger: nil))
    }

    public func removeCountdown() {
        guard let center else { return }
        center.removeDeliveredNotifications(withIdentifiers: [Self.countdownID])
        center.removePendingNotificationRequests(withIdentifiers: [Self.countdownID])
    }

    public func postGuard(_ reason: GuardReason) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        switch reason {
        case .lowBattery:
            content.title = L("Battery is low")
            content.body = L("Vigil restored normal sleep and is putting your Mac to sleep.")
        case .thermal:
            content.title = L("Your Mac is running hot")
            content.body = L("Vigil restored normal sleep and is putting your Mac to sleep.")
        case .maxDuration:
            content.title = L("Maximum keep-awake time reached")
            content.body = L("Vigil restored normal sleep and is putting your Mac to sleep.")
        case .manualSleep:
            return
        }
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "vigil.guard.\(reason.rawValue)", content: content, trigger: nil))
    }

    /// Claude waited longer than the maximum wait for an answer; the normal sleep countdown follows.
    public func postWaitTimeout(project: String, waited: TimeInterval) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = L("Claude is still waiting for your answer")
        content.body = L("%@ has waited %@. Your Mac will go to sleep after the grace period.", project,
                         Durations.short(waited))
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "vigil.waitTimeout", content: content, trigger: nil))
    }

    /// The work-time estimate says Claude is almost done ("rasinova-residence: hotovo asi za 5 min").
    public func postEta(project: String, remaining: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = L("%@: done in about %@", project, remaining)
        content.body = L("An estimate, not a promise. It never affects sleep.")
        center.add(UNNotificationRequest(identifier: "vigil.eta.\(project)", content: content, trigger: nil))
    }

    /// Claude usage crossed a threshold or a window reset.
    public func postUsage(_ alert: UsageAlert, resetsAt: Date?) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        let id: String
        switch alert {
        case .threshold(let kind, let percent):
            content.title = kind == .fiveHour ? L("Claude usage: %@ of the session limit", "\(percent) %")
                                              : L("Claude usage: %@ of the weekly limit", "\(percent) %")
            if let resetsAt {
                content.body = L("Resets at %@.", resetsAt.formatted(date: kind == .fiveHour ? .omitted : .abbreviated, time: .shortened))
            }
            id = "vigil.usage.\(kind.rawValue).\(percent)"
        case .reset(let kind):
            content.title = L("Limit reset — you can continue")
            content.body = kind == .fiveHour ? L("The 5-hour session window has reset.") : L("The weekly window has reset.")
            id = "vigil.usage.\(kind.rawValue).reset"
        }
        content.sound = .default
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // MARK: UNUserNotificationCenterDelegate

    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound] }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        switch response.actionIdentifier {
        case "cancel": onAction?(.cancel)
        case "keepAwake": onAction?(.keepAwake)
        default: break
        }
    }
}
