import SwiftUI
import VigilCore

// MARK: - Look

/// "Live Activity" palette: pure black, #1C1C1E cards, one accent, orange only for "waiting for you".
enum Theme {
    static let background = Color.black
    static let card = Color(hex: 0x1C1C1E)
    static let track = Color(hex: 0x3A3A3C)
    static let outline = Color(hex: 0x2C2C2E)
    /// Boxes inside a card (the step row).
    static let inset = Color(hex: 0x2C2C2E)
    static let waiting = Color(hex: 0xFF9F0A)
    static let cardRadius: CGFloat = 28
    static let tileRadius: CGFloat = 20

    static func accent(_ choice: AccentChoice) -> Color {
        switch choice {
        case .green: return Color(hex: 0x30D158)
        case .blue: return Color(hex: 0x0A84FF)
        case .orange: return Color(hex: 0xFF9F0A)
        case .purple: return Color(hex: 0xBF5AF2)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

// MARK: - Containers

/// #1C1C1E rounded card (radius 28) used for every block in the popover and the small windows.
struct Card<Content: View>: View {
    var padding: CGFloat = 18
    var radius: CGFloat = Theme.cardRadius
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 6)
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

struct RowDivider: View {
    var body: some View { Rectangle().fill(Theme.outline).frame(height: 1) }
}

// MARK: - Small pieces

struct StatusDot: View {
    let ok: Bool
    let accent: Color
    var body: some View {
        Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
            .font(.system(size: 18))
            .foregroundStyle(ok ? accent : Color.secondary.opacity(0.6))
            .contentTransition(.symbolEffect(.replace))
    }
}

// MARK: - Buttons

/// Full-width capsule button, 50 pt tall (the two big actions in the popover).
struct CapsuleButtonStyle: ButtonStyle {
    var fill: Color
    var foreground: Color
    var height: CGFloat = 50
    @SwiftUI.Environment(\.isEnabled) private var isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .foregroundStyle(foreground)
            .background(fill, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// Small capsule button for rows and cards.
struct PillButtonStyle: ButtonStyle {
    var fill: Color = Theme.track
    var foreground: Color = .primary
    @SwiftUI.Environment(\.isEnabled) private var isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .foregroundStyle(foreground)
            .background(fill, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// Shows a spinner while `busy`, otherwise a pill button (accent-filled when prominent).
struct ActionButton: View {
    let title: String
    var busy = false
    var prominent = false
    var accent: Color = Theme.accent(.green)
    let action: () -> Void
    var body: some View {
        Group {
            if busy {
                ProgressView().controlSize(.small).frame(minWidth: 60)
            } else {
                Button(title, action: action)
                    .buttonStyle(PillButtonStyle(fill: prominent ? accent : Theme.track, foreground: prominent ? .black : .primary))
            }
        }
        .transition(.opacity)
    }
}
