import SwiftUI
import VigilCore

extension Phase {
    var tint: Color {
        switch self {
        case .off: return .gray
        case .armed: return .blue
        case .working: return .green
        case .countdown: return .orange
        }
    }

    var symbol: String {
        switch self {
        case .off: return "moon.zzz.fill"
        case .armed: return "eye.fill"
        case .working: return "bolt.fill"
        case .countdown: return "timer"
        }
    }
}

/// Rounded, vibrant container used for every block in the popover.
struct Card<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.07)))
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.6)
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
                Text(title).font(.system(size: 13))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
    }
}

struct Pill: View {
    let text: String
    let tint: Color
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint.opacity(0.16), in: Capsule())
            .foregroundStyle(tint)
    }
}

struct StatusDot: View {
    let ok: Bool
    var body: some View {
        Image(systemName: ok ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 18))
            .foregroundStyle(ok ? Color.green : Color.secondary.opacity(0.6))
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.bounce, value: ok)
    }
}

/// Shows a spinner while `busy`, otherwise a small bordered button.
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
