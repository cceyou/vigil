import SwiftUI
import VigilCore

/// A Claude Code session as the usage card lists it.
struct UsageCardSession: Identifiable, Equatable {
    var id: String
    /// Display name ("~ (domovská složka)" for the home folder).
    var project: String
    /// Full working directory, for the tooltip.
    var path: String? = nil
    var model: String?
    var contextPercent: Double?
    var working: Bool
    /// "4/7" when Claude keeps a task list.
    var step: String? = nil
    /// Work-time estimate ("~12 min", "5–15 min").
    var eta: String? = nil
    var etaConfident = false
    var subagents = 0
    /// Claude asked a question or a permission and waits for the user.
    var waiting = false
    /// How long the session has been busy (nil when it is not working).
    var elapsed: TimeInterval? = nil

    /// "Opus 5.5 · krok 4/7 · kontext 42 % · + 2 subagenti"; "Čeká na první odpověď" before any status line.
    var subtitle: String {
        var parts: [String] = []
        if let model { parts.append(model) }
        if let step { parts.append(L("step %@", step)) }
        if let ctx = contextPercent {
            parts.append(L("context %@", "\(Int(ctx.rounded())) %"))
            if ctx >= 80 { parts.append(L("auto-compact soon")) }
        }
        if parts.isEmpty { parts.append(L("Waiting for the first response")) }
        if subagents > 0 { parts.append("+\u{00A0}" + Format.subagents(subagents)) }
        return parts.joined(separator: " · ")
    }

    /// The path for the tooltip, with the home folder as "~".
    var pathHelp: String? { path.map { ($0 as NSString).abbreviatingWithTildeInPath } }

    /// "Zbývá asi 15 minut" for VoiceOver.
    var etaAccessibility: String? { eta.map { L("About %@ left", $0.replacingOccurrences(of: "~", with: "")) } }
}

/// Presentation state of the usage card (shared by the notch hover, the card itself and the shortcut).
@MainActor
@Observable
final class UsageCardState {
    /// Drives the slide in/out.
    var shown = false
    /// Clicked: stays open until the notch, the shortcut, the × button or a click outside closes it
    /// (or Esc, once the user has clicked into the card).
    var pinned = false
}

/// The card that slides out of the screen edge: Claude usage limits, active sessions, Vigil state.
/// Monochrome on purpose; the only colour is a warning (orange at 80 %, red at 95 %).
/// Built from the same pieces as the menu bar popover (DesignSystem.swift), so the two always match.
struct UsageCardView: View {
    let model: AppModel
    let state: UsageCardState
    var onClick: () -> Void = {}
    var onClose: () -> Void = {}

    static let width: CGFloat = 300

    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let usage = model.usage
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: L("Claude usage"), caption: freshness(usage)) {
                if state.pinned {
                    Button(action: onClose) { Image(systemName: "xmark") }
                        .controlSize(.small)
                        .vigilButtonStyle()
                        .transition(.opacity)
                        .help(L("Close"))
                        .accessibilityLabel(L("Close"))
                }
            }
            if usage.hasRateLimits {
                let stale = usage.freshness(at: model.now).isStale
                if let five = model.usageWindow(.fiveHour) {
                    WindowBlock(title: L("Current session"), window: five, kind: .fiveHour, now: model.now, stale: stale)
                }
                if let week = model.usageWindow(.sevenDay) {
                    WindowBlock(title: L("This week"), window: week, kind: .sevenDay, now: model.now, stale: stale)
                }
                if stale {
                    // Chat in the Claude app counts against the same limits, but only Claude Code reports them.
                    Label(L("Chat in the Claude app shows up here only with your next work in Claude Code"), systemImage: "bubble.left.and.bubble.right")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            } else {
                emptyState
            }
            let sessions = model.usageSessions
            if !sessions.isEmpty {
                Hairline()
                VStack(spacing: 8) {
                    ForEach(sessions) { s in
                        SessionRow(leading: .ring(s.contextPercent), title: s.project, subtitle: s.subtitle, help: s.pathHelp) {
                            SessionStateValue(session: s)
                        }
                    }
                }
                BackgroundShellsLine(model: model)
            }
            Hairline()
            FooterBar(model: model)
        }
        .padding(18)
        .frame(width: Self.width, alignment: .leading)
        .glassSurface()
        .contentShape(RoundedRectangle(cornerRadius: Metrics.surfaceRadius, style: .continuous))
        .onTapGesture { onClick() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Claude usage"))
        .accessibilityAction(named: L("Keep open")) { onClick() }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth, value: model.usageSessions)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth, value: state.pinned)
    }

    /// By when the numbers were last *new*, not when the status line last re-ran with the same old values.
    private func freshness(_ usage: UsageState) -> String? {
        switch usage.freshness(at: model.now) {
        case .none:
            return nil
        case .fresh(let age):
            if age < 60 { return L("updated just now") }
            return L("updated %@ ago", "\(Int(age / 60)) min")
        case .stale(let since):
            let old = model.now.timeIntervalSince(since) > 20 * 3600
            return L("Data from %@", since.formatted(date: old ? .abbreviated : .omitted, time: .shortened))
        }
    }

    @ViewBuilder private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "chart.bar.xaxis").font(.title3).symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if !model.setup.statusLine {
                Text(L("Usage needs the status line")).font(.subheadline.weight(.semibold))
                Text(L("Vigil reads your limits from Claude Code's status line. Installing it keeps your current status line working."))
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(L("Install status line")) { model.installStatusLine() }
                    .controlSize(.small)
                    .vigilButtonStyle()
                    .disabled(model.busy.contains("statusLine"))
            } else {
                Text(L("No limits yet")).font(.subheadline.weight(.semibold))
                Text(L("Limits appear after the next response in Claude Code. Claude Code only sends them when you are logged in with a Claude Pro or Max subscription (version 2.1.80 or newer). With an API key there are no limits to show."))
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Pieces

/// One limit window as a MetricRow: big percentage, thin bar, when it resets; the weekly one adds a pace line.
private struct WindowBlock: View {
    let title: String
    let window: EffectiveWindow
    let kind: UsageWindowKind
    let now: Date
    /// Old data: the bar and number are dimmed. A window that has reset is known (0 %) and never dimmed.
    var stale = false

    var body: some View {
        let used = window.usedPercentage
        let dimmed = stale && !window.isReset
        MetricRow(title: title, value: "\(Int(used.rounded())) %", valueSecondary: dimmed,
                  valueAccessibility: L("%d percent used", Int(used.rounded())),
                  bar: SegmentedProgressBar(progress: used / 100, tint: SegmentedProgressBar.usageTint(used / 100), dimmed: dimmed)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(resetText).fontDesign(.rounded)
                if kind == .sevenDay, !window.isReset {
                    Text(paceText).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var resetText: String {
        if window.isReset { return L("Reset · 0 %") }
        if kind == .fiveHour {
            return L("Resets in %@ · %@", UsageFormat.duration(window.resetsAt.timeIntervalSince(now)),
                     window.resetsAt.formatted(date: .omitted, time: .shortened))
        }
        return L("Resets %@", UsageFormat.dayAndTime(window.resetsAt, now: now))
    }

    private var paceText: String {
        switch UsagePace.evaluate(usedPercentage: window.usedPercentage, resetsAt: window.resetsAt, length: kind.length, now: now) {
        case .onTrack: return L("Pace is fine")
        case .exhausts(let at):
            return L("At this pace the limit runs out %@ around %@", UsageFormat.dayPhrase(at, now: now),
                     at.formatted(date: .omitted, time: .shortened))
        }
    }
}

// MARK: - Formatting

enum UsageFormat {
    /// 8040 s -> "2 h 14 min", 900 -> "15 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let m = max(0, Int(seconds / 60))
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
    }

    /// "Thu 9:00" (weekday + time), "today 9:00" for today.
    static func dayAndTime(_ date: Date, now: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return L("today %@", time) }
        return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)"
    }

    /// "today", "tomorrow", "on Friday" (Czech: dnes, zítra, v pátek).
    static func dayPhrase(_ date: Date, now: Date) -> String {
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return L("today") }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(date, inSameDayAs: tomorrow) { return L("tomorrow") }
        switch cal.component(.weekday, from: date) {
        case 1: return L("on Sunday")
        case 2: return L("on Monday")
        case 3: return L("on Tuesday")
        case 4: return L("on Wednesday")
        case 5: return L("on Thursday")
        case 6: return L("on Friday")
        default: return L("on Saturday")
        }
    }
}
