import Foundation
import VigilCore

/// A session's work-time estimate, ready for display. Information only.
struct SessionEta: Equatable {
    var estimate: Estimate
    /// "~12 min" when confident, "5–15 min" when not, "brzy" under a minute.
    var remainingText: String
    /// Medium or high confidence; low confidence is shown in the secondary color with the whole range.
    var confident: Bool
    var fromHistory: Bool
    /// When it will likely be done (task list only).
    var finishAt: Date
    /// "±5 min".
    var plusMinus: String
    /// Task list: step being worked on (1-based), total, done.
    var step: Int?
    var total: Int?
    var done: Int?
    /// Progress through the list including the current task's share (0...1).
    var progress: Double?
    /// Subject of the task in progress.
    var subject: String?
    /// The list grew in the last 30 s by this many steps.
    var growth: Int?
    /// History basis: how many comparable turns, and where from.
    var historyCount: Int?
    var historyScope: HistoryScope?
}

extension AppModel {
    func eta(for sessionID: String) -> SessionEta? {
        guard let turn = tracker.turns[sessionID], let e = turn.displayed else { return nil }
        var eta = SessionEta(estimate: e, remainingText: EtaFormat.remaining(e), confident: e.confidence >= .medium,
                             fromHistory: !e.basis.isTasks, finishAt: now.addingTimeInterval(e.likely),
                             plusMinus: EtaFormat.plusMinus(e))
        switch e.basis {
        case .tasks(let done, let total):
            eta.step = turn.currentStep
            eta.total = total
            eta.done = done
            eta.subject = turn.currentTask?.subject
            eta.growth = turn.growth?.count
            if total > 0 {
                // The current task's share: its elapsed time against what is left per remaining task.
                let left = max(1, total - done)
                let elapsed = turn.currentTaskElapsed(at: now)
                let perTask = e.likely / Double(left) + elapsed
                let share = done < total && perTask > 0 ? min(0.9, elapsed / perTask) : 0
                eta.progress = min(1, (Double(done) + share) / Double(total))
            }
        case .history(let count, let scope):
            eta.historyCount = count
            eta.historyScope = scope
        }
        return eta
    }

    /// The estimate the island shows (the most recently active working session), when it is set to.
    var islandEta: SessionEta? {
        guard settings.ui.islandContent == .estimate, let session = workingByActivity.first else { return nil }
        return eta(for: session.id)
    }

    /// Once per turn, only with a medium or high confidence estimate, when it is about five minutes out.
    func etaNotificationsDue() -> [(sessionID: String, project: String, text: String)] {
        guard settings.ui.etaNotification else { return [] }
        return tracker.turns.values.sorted { $0.sessionID < $1.sessionID }.compactMap { turn in
            guard !turn.notified, let e = turn.displayed, e.confidence >= .medium, e.likely <= 5 * 60, e.likely >= 60
            else { return nil }
            return (turn.sessionID, turn.project, EtaFormat.duration(e.likely))
        }
    }
}

extension Format {
    /// "+1 step", "+3 steps" (Czech: +1 krok, +2–4 kroky, +5 kroků).
    static func addedSteps(_ n: Int) -> String {
        switch PluralCategory.czech(n) {
        case .one: return L("+1 step")
        case .few: return L("+%d steps (2-4)", n)
        case .many: return L("+%d steps", n)
        }
    }

    /// "Step 4 of 7" (Czech "Krok 4 ze 7" / "Krok 2 z 5").
    static func stepOf(_ step: Int, _ total: Int) -> String {
        CzechPreposition.usesZe(total) ? L("Step %d of %d (ze)", step, total) : L("Step %d of %d", step, total)
    }

    /// "Odhad podle 13 dřívějších úkolů v projektu" / "…ze všech projektů" (Czech: podle 1 dřívějšího úkolu).
    static func estimateBasis(_ count: Int, _ scope: HistoryScope) -> String {
        if count == 1 {
            return scope == .project ? L("Estimate from 1 earlier task in the project") : L("Estimate from 1 earlier task across projects")
        }
        return scope == .project ? L("Estimate from %d earlier tasks in the project", count)
                                 : L("Estimate from %d earlier tasks across projects", count)
    }
}

extension Format {
    /// Whole minutes, at least 1: "4 min", "1:05 h".
    static func minutes(_ seconds: TimeInterval) -> String {
        let m = max(1, Int((seconds / 60).rounded()))
        return m < 60 ? "\(m) min" : String(format: "%d:%02d h", m / 60, m % 60)
    }

    /// How long a turn took: "<1 min", "51 min", "2:14 h".
    static func took(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "<1 min" : minutes(seconds)
    }

    /// "16 of 20" (Czech "16 z 20", "3 ze 7").
    static func countOf(_ n: Int, _ total: Int) -> String {
        CzechPreposition.usesZe(total) ? L("%d of %d (ze)", n, total) : L("%d of %d", n, total)
    }

    /// "last 20 turns" (Czech: poslední úkol, poslední 3 úkoly, posledních 20 úkolů).
    static func lastTurns(_ n: Int) -> String {
        switch PluralCategory.czech(n) {
        case .one: return L("last turn")
        case .few: return L("last %d turns (2-4)", n)
        case .many: return L("last %d turns", n)
        }
    }
}
