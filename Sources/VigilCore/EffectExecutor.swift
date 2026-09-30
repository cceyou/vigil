import Foundation

public enum Job: Sendable {
    case effects([Effect])
    /// Restore `disablesleep 0` if the system reports SleepDisabled=1 while we are not holding it.
    /// Runs in the same queue as effects, so it can never race an in-flight acquire.
    case reconcile
    /// Swap the power backend (dry run on/off). Releases through the old one first.
    case usePower(PowerControlling)
}

/// Executes state-machine effects strictly in order (so "restore, then sleep" can never be reordered).
public actor EffectExecutor {
    private var power: PowerControlling
    private let notifier: Notifier?
    private let history: HistoryStore
    private let onPowerError: @Sendable (String?) -> Void
    private let onHistory: @Sendable ([SessionRecord]) -> Void
    private let decisions: SleepDecisionStore?
    private let onDecisions: @Sendable ([SleepDecisionRecord]) -> Void
    private var graceSeconds: Int = 30
    private var held = false

    public init(power: PowerControlling, notifier: Notifier?, history: HistoryStore,
                onPowerError: @escaping @Sendable (String?) -> Void,
                onHistory: @escaping @Sendable ([SessionRecord]) -> Void,
                decisions: SleepDecisionStore? = nil,
                onDecisions: @escaping @Sendable ([SleepDecisionRecord]) -> Void = { _ in }) {
        self.power = power
        self.notifier = notifier
        self.history = history
        self.onPowerError = onPowerError
        self.onHistory = onHistory
        self.decisions = decisions
        self.onDecisions = onDecisions
    }

    public func setGrace(_ seconds: Int) { graceSeconds = seconds }

    public func run(_ job: Job) async {
        switch job {
        case .effects(let effects): await run(effects)
        case .reconcile: await reconcile()
        case .usePower(let new):
            if held { _ = await power.releaseAwake(); held = false }
            power = new
        }
    }

    private func reconcile() async {
        guard !held, power.sleepDisabled() == true else { return }
        Log.shared.warning("SleepDisabled=1 without an active hold; restoring")
        _ = await power.releaseAwake()
    }

    private func run(_ effects: [Effect]) async {
        for effect in effects {
            switch effect {
            case .acquireAwake:
                held = true
                do { try await power.acquireAwake(); onPowerError(nil) } catch { onPowerError("\(error)") }
            case .releaseAwake:
                _ = await power.releaseAwake()
                held = false
            case .sleepNow:
                await power.sleepNow()
            case .showCountdown:
                notifier?.postCountdown(deadline: Date(), seconds: graceSeconds)
            case .dismissCountdown:
                notifier?.removeCountdown()
            case .notifyGuard(let reason):
                Log.shared.warning("guard tripped: \(reason.rawValue)")
                notifier?.postGuard(reason)
            case .record(let record):
                onHistory(history.append(record))
            case .droppedStuckSubagent(let project, let agentID, let agentType, let age):
                Log.shared.warning("dropped stuck subagent \(agentType) (\(agentID.prefix(8))) in \(project): "
                                   + "no SubagentStop after \(Int(age / 60)) min")
            case .waitTimedOut(let project, let waited):
                Log.shared.warning("\(project) waited \(Int(waited / 60)) min for an answer; starting the sleep countdown")
                notifier?.postWaitTimeout(project: project, waited: waited)
            case .sleepDecision(let record):
                // Every sleep and every skip, with its reason: "sleep: lid closed, no external display",
                // "skip: user active 12 s ago", "skip: assertion held by zoom.us".
                Log.shared.info(record.logLine)
                if let decisions { onDecisions(decisions.append(record)) }
            case .ignoredNotification(let type):
                Log.shared.info("ignored Notification hook with unknown notification_type \(type ?? "(none)")")
            }
        }
    }
}
