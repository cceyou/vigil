import SwiftUI
import VigilCore

// MARK: - Look

/// What the hero shows. `Phase` from the state machine plus "paused": Claude is working but a guard
/// (battery, heat, time limit, manual sleep) stops Vigil from holding the Mac awake.
enum Mood: Equatable {
    case off, armed, working, countdown, paused

    var tint: Color {
        switch self {
        case .off: return Color(red: 0.56, green: 0.58, blue: 0.64)
        case .armed: return Color(red: 0.40, green: 0.52, blue: 1.00)
        case .working: return Color(red: 0.20, green: 0.84, blue: 0.62)
        case .countdown: return Color(red: 1.00, green: 0.62, blue: 0.22)
        case .paused: return Color(red: 1.00, green: 0.36, blue: 0.40)
        }
    }

    /// Second stop for gradients, so rings read as light rather than flat colour.
    var glow: Color {
        switch self {
        case .off: return Color(red: 0.40, green: 0.42, blue: 0.48)
        case .armed: return Color(red: 0.62, green: 0.40, blue: 1.00)
        case .working: return Color(red: 0.24, green: 0.66, blue: 1.00)
        case .countdown: return Color(red: 1.00, green: 0.36, blue: 0.46)
        case .paused: return Color(red: 1.00, green: 0.66, blue: 0.24)
        }
    }

    var symbol: String {
        switch self {
        case .off: return "moon.zzz.fill"
        case .armed: return "eye.fill"
        case .working: return "bolt.fill"
        case .countdown: return "moon.fill"
        case .paused: return "pause.fill"
        }
    }
}

extension Phase {
    var tint: Color {
        switch self {
        case .off: return Mood.off.tint
        case .armed: return Mood.armed.tint
        case .working: return Mood.working.tint
        case .countdown: return Mood.countdown.tint
        }
    }
}

// MARK: - Hero orb

/// The animated ring at the top of the popover. Working: a comet chases around the ring. Countdown: the ring
/// drains. Armed: a slow breath. Paused: a dashed, still ring. Off: dim and static.
struct Orb: View {
    let mood: Mood
    /// 0...1 of the countdown left; only used for `.countdown`.
    var progress: Double = 1
    var size: CGFloat = 148

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: mood == .off || mood == .paused)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let breath = (sin(t * (mood == .working ? 2.4 : 1.2)) + 1) / 2 // 0...1
            ZStack {
                // Soft glow behind everything.
                Circle()
                    .fill(RadialGradient(colors: [mood.tint.opacity(mood == .off ? 0.10 : 0.34), .clear],
                                         center: .center, startRadius: 4, endRadius: size * 0.48))
                    .scaleEffect(1 + 0.06 * breath)
                    .blur(radius: 6)

                // Track.
                Circle()
                    .stroke(mood.tint.opacity(0.16), style: StrokeStyle(lineWidth: 5, dash: mood == .paused ? [3, 7] : []))
                    .frame(width: size * 0.78, height: size * 0.78)

                ring(t: t, breath: breath)
                    .frame(width: size * 0.78, height: size * 0.78)

                // Core disc.
                Circle()
                    .fill(LinearGradient(colors: [mood.tint.opacity(0.26), mood.glow.opacity(0.12)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(Circle().strokeBorder(.white.opacity(0.10)))
                    .frame(width: size * 0.56, height: size * 0.56)
                    .scaleEffect(mood == .armed ? 0.97 + 0.03 * breath : 1)
            }
            .frame(width: size, height: size)
        }
    }

    @ViewBuilder
    private func ring(t: Double, breath: Double) -> some View {
        let gradient = AngularGradient(colors: [mood.tint.opacity(0), mood.tint, mood.glow], center: .center)
        switch mood {
        case .working:
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(gradient, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees((t * 150).truncatingRemainder(dividingBy: 360)))
                .shadow(color: mood.tint.opacity(0.6), radius: 6)
        case .countdown:
            Circle()
                .trim(from: 0, to: max(0.001, progress))
                .stroke(LinearGradient(colors: [mood.tint, mood.glow], startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: mood.tint.opacity(0.5), radius: 5)
                .animation(.linear(duration: 1), value: progress)
        case .armed:
            Circle()
                .stroke(gradient, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees((t * 18).truncatingRemainder(dividingBy: 360)))
                .opacity(0.35 + 0.45 * breath)
        case .paused:
            Circle()
                .trim(from: 0, to: 0.25)
                .stroke(mood.tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        case .off:
            EmptyView()
        }
    }
}

// MARK: - Containers

/// Rounded container used for every block in the popover.
struct Card<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(0.06)))
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
    }
}

/// A label on the left, a control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var control: Control
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
    }
}

// MARK: - Small pieces

struct Pill: View {
    let text: String
    let tint: Color
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(tint.opacity(0.16), in: Capsule())
            .foregroundStyle(tint)
    }
}

/// Icon + short text, used for the live lid / power / heat readout under the hero.
struct Chip: View {
    let symbol: String
    let text: String
    var tint: Color = .secondary
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
            Text(text)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(.primary.opacity(0.05), in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.06)))
    }
}

/// Coloured dot; `live` adds an expanding ripple. Clock-driven (no @State: the Command Line Tools
/// toolchain lacks the SwiftUI macro plugin).
struct LiveDot: View {
    let tint: Color
    var live = false
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !live)) { context in
            let p = live ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4 : 0
            ZStack {
                if live {
                    Circle().fill(tint.opacity(0.5))
                        .scaleEffect(1 + 1.6 * p)
                        .opacity(0.8 * (1 - p))
                }
                Circle().fill(tint)
            }
            .frame(width: 8, height: 8)
        }
    }
}

struct StatusDot: View {
    let ok: Bool
    var body: some View {
        Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
            .font(.system(size: 18))
            .foregroundStyle(ok ? Mood.working.tint : Color.secondary.opacity(0.6))
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.bounce, value: ok)
    }
}

// MARK: - Buttons

/// Soft, rounded button with a springy press.
struct SoftButtonStyle: ButtonStyle {
    var tint: Color = .accentColor
    var prominent = false
    @SwiftUI.Environment(\.isEnabled) private var isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .foregroundStyle(prominent ? Color.white : tint)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(prominent ? AnyShapeStyle(LinearGradient(colors: [tint, tint.opacity(0.78)], startPoint: .top, endPoint: .bottom))
                                    : AnyShapeStyle(tint.opacity(0.13)))
            }
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(prominent ? 0.18 : 0)))
            .shadow(color: prominent ? tint.opacity(0.35) : .clear, radius: configuration.isPressed ? 2 : 6, y: 2)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Shows a spinner while `busy`, otherwise a small button.
struct ActionButton: View {
    let title: String
    var busy = false
    var prominent = false
    let action: () -> Void
    var body: some View {
        Group {
            if busy {
                ProgressView().controlSize(.small).frame(minWidth: 60)
            } else if prominent {
                Button(title, action: action).buttonStyle(.borderedProminent)
            } else {
                Button(title, action: action).buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
        .transition(.opacity)
    }
}

// MARK: - Tab bar

struct TabBar: View {
    @Binding var selection: Tab
    let tint: Color
    @Namespace private var ns

    private let items: [(Tab, String, String)] = [
        (.overview, "circle.hexagongrid.fill", L("Overview")),
        (.history, "clock.fill", L("History")),
        (.settings, "gearshape.fill", L("Settings")),
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.0) { item in
                let (tab, symbol, title) = item
                let on = selection == tab
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { selection = tab }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                            .symbolEffect(.bounce, value: on)
                        Text(title).font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(on ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .background {
                        if on {
                            Capsule().fill(LinearGradient(colors: [tint.opacity(0.26), tint.opacity(0.14)],
                                                          startPoint: .top, endPoint: .bottom))
                                .matchedGeometryEffect(id: "tab", in: ns)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(.primary.opacity(0.04), in: Capsule())
    }
}

enum Durations {
    static func short(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        return "\(s / 3600) h"
    }
}
