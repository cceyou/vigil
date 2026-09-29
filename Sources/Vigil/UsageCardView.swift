import SwiftUI
import VigilCore

/// A Claude Code session as the usage card lists it.
struct UsageCardSession: Identifiable, Equatable {
    var id: String
    var project: String
    var model: String?
    var contextPercent: Double?
    var working: Bool
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
struct UsageCardView: View {
    let model: AppModel
    let state: UsageCardState
    var onClick: () -> Void = {}
    var onClose: () -> Void = {}

    static let width: CGFloat = 300
    static let warning = Color(hex: 0xFF9F0A)
    static let critical = Color(hex: 0xFF453A)

    var body: some View {
        let usage = model.usage
        VStack(alignment: .leading, spacing: 16) {
            header(usage)
            if usage.hasRateLimits {
                if let five = model.usageWindow(.fiveHour) {
                    WindowBlock(title: L("Current session"), window: five, kind: .fiveHour, now: model.now)
                }
                if let week = model.usageWindow(.sevenDay) {
                    WindowBlock(title: L("This week"), window: week, kind: .sevenDay, now: model.now)
                }
            } else {
                emptyState
            }
            let sessions = model.usageSessions
            if !sessions.isEmpty {
                Rectangle().fill(.primary.opacity(0.12)).frame(height: 0.5)
                VStack(spacing: 10) {
                    ForEach(sessions) { SessionLine(session: $0) }
                }
            }
            Rectangle().fill(.primary.opacity(0.12)).frame(height: 0.5)
            footer
        }
        .padding(18)
        .frame(width: Self.width, alignment: .leading)
        .modifier(GlassCard(radius: 26))
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onTapGesture { onClick() }
        .animation(.smooth, value: model.usageSessions)
        .animation(.smooth, value: state.pinned)
    }

    // MARK: header

    private func header(_ usage: UsageState) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Claude usage")).font(.system(size: 15, weight: .semibold))
                if let text = freshness(usage) {
                    Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            if state.pinned {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(.primary.opacity(0.08), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
                .help(L("Close"))
                .accessibilityLabel(L("Close"))
            }
        }
    }

    private func freshness(_ usage: UsageState) -> String? {
        guard let updated = usage.updatedAt ?? usage.lastStatusLineAt else { return nil }
        let age = model.now.timeIntervalSince(updated)
        if age > 15 * 60 {
            return L("Data from %@ — run Claude Code to refresh", updated.formatted(date: age > 20 * 3600 ? .abbreviated : .omitted, time: .shortened))
        }
        if age < 60 { return L("updated just now") }
        return L("updated %@ ago", "\(Int(age / 60)) min")
    }

    // MARK: empty state

    @ViewBuilder private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "chart.bar.xaxis").font(.system(size: 20)).foregroundStyle(.secondary)
            if !model.setup.statusLine {
                Text(L("Usage needs the status line")).font(.system(size: 13, weight: .semibold))
                Text(L("Vigil reads your limits from Claude Code's status line. Installing it keeps your current status line working."))
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(L("Install status line")) { model.installStatusLine() }
                    .buttonStyle(GlassButtonStyle())
                    .disabled(model.busy.contains("statusLine"))
            } else {
                Text(L("No limits yet")).font(.system(size: 13, weight: .semibold))
                Text(L("Limits appear after the next response in Claude Code. Claude Code only sends them when you are logged in with a Claude Pro or Max subscription (version 2.1.80 or newer). With an API key there are no limits to show."))
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: footer

    private var vigilLine: String {
        switch model.island {
        case .working:
            if let r = model.awakeRemaining { return L("Mac awake · %@", Format.clock(r)) }
            return L("Mac awake")
        case .countdown(let r): return L("Mac sleeps in %@", Format.clock(r))
        case .waiting: return L("Claude is waiting for you")
        case .idle: return L("Vigil is ready")
        case .off: return L("Vigil is off")
        case .paused(let reason): return PausedText.title(reason)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(vigilLine)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .contentTransition(.numericText())
            Spacer(minLength: 4)
            Button { model.keepAwake() } label: { Text("+1 h").font(.system(size: 12, weight: .semibold, design: .rounded)) }
                .buttonStyle(GlassButtonStyle())
                .disabled(!model.enabled)
                .help(L("Keep awake for 1 h"))
            Button { model.sleepNow() } label: { Image(systemName: "moon.fill").font(.system(size: 11, weight: .semibold)) }
                .buttonStyle(GlassButtonStyle())
                .help(L("Sleep now"))
        }
    }
}

// MARK: - Pieces

/// One limit window: big percentage, thin bar, when it resets; the weekly one adds a pace line.
private struct WindowBlock: View {
    let title: String
    let window: EffectiveWindow
    let kind: UsageWindowKind
    let now: Date

    var body: some View {
        let used = window.usedPercentage
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(used.rounded())) %")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            UsageBar(fraction: used / 100)
            Text(resetText).font(.system(size: 11, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
            if kind == .sevenDay, !window.isReset {
                Text(paceText).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var resetText: String {
        if window.isReset { return L("Reset") }
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

/// 4 pt bar; orange from 80 %, red from 95 %.
struct UsageBar: View {
    let fraction: Double
    var body: some View {
        let f = min(1, max(0, fraction))
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.14))
                Capsule().fill(UsageBar.color(f)).frame(width: max(f > 0 ? 4 : 0, g.size.width * f))
            }
        }
        .frame(height: 4)
        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: f)
    }

    static func color(_ f: Double) -> Color {
        if f >= 0.95 { return UsageCardView.critical }
        if f >= 0.80 { return UsageCardView.warning }
        return .primary
    }
}

private struct SessionLine: View {
    let session: UsageCardSession
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(session.project).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(session.model ?? "Claude Code").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if let ctx = session.contextPercent {
                VStack(alignment: .trailing, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("\(Int(ctx.rounded())) %").font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
                            .foregroundStyle(.secondary)
                        ContextRing(percent: ctx)
                    }
                    if ctx >= 80 {
                        Text(L("auto-compact soon")).font(.system(size: 10)).foregroundStyle(UsageCardView.warning)
                    }
                }
                .help(L("Context window used"))
            }
        }
    }
}

struct ContextRing: View {
    let percent: Double
    var body: some View {
        let f = min(1, max(0, percent / 100))
        ZStack {
            Circle().stroke(.primary.opacity(0.14), lineWidth: 3)
            Circle().trim(from: 0, to: f)
                .stroke(percent >= 80 ? UsageCardView.warning : Color.primary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 18, height: 18)
        .animation(.smooth, value: f)
    }
}

// MARK: - Glass

/// Liquid Glass on macOS 26+, a thin material with a hairline and a soft shadow before that.
struct GlassCard: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: radius))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        }
    }
}

struct GlassButtonStyle: ButtonStyle {
    @SwiftUI.Environment(\.isEnabled) private var isEnabled: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(minWidth: 30, minHeight: 26)
            .modifier(GlassCapsule())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

private struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content
                .background(.thinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
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
