import AppKit
import SwiftUI
import VigilCore

// MARK: - Tokens

/// Color carries meaning only: the accent marks "active", orange "waiting for you" or a warning, red a critical state.
/// Everything else is .primary / .secondary / .tertiary on a system material.
enum Theme {
    static let warning = Color(nsColor: .systemOrange)
    static let critical = Color(nsColor: .systemRed)

    static func accent(_ choice: AccentChoice) -> Color {
        switch choice {
        case .green: return Color(hex: 0x30D158)
        case .blue: return Color(hex: 0x0A84FF)
        case .orange: return Color(hex: 0xFF9F0A)
        case .purple: return Color(hex: 0xBF5AF2)
        }
    }
}

/// 8 pt grid; the popover and the usage card share the outer padding and the corner radius.
enum Metrics {
    static let surfaceRadius: CGFloat = 26
    static let padding: CGFloat = 16
    static let popoverWidth: CGFloat = 320
    static let barHeight: CGFloat = 4
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

// MARK: - Accessibility environment

private struct ForceSolidKey: EnvironmentKey { static let defaultValue = false }

private struct SnapshotKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Offscreen snapshots: `cacheDisplay` cannot draw Liquid Glass (it samples the live backdrop), so snapshots
    /// get a translucent stand-in for the glass surface and bordered buttons instead of glass ones.
    var vigilSnapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }

    /// Snapshots set this to render the Reduce Transparency look without changing the system setting.
    var vigilForceSolid: Bool {
        get { self[ForceSolidKey.self] }
        set { self[ForceSolidKey.self] = newValue }
    }
}

/// Track and divider strength: stronger under Increase Contrast.
enum Contrast {
    static func track(_ contrast: ColorSchemeContrast) -> Double { contrast == .increased ? 0.32 : 0.14 }
    static func hairline(_ contrast: ColorSchemeContrast) -> Double { contrast == .increased ? 0.4 : 0.12 }
}

/// Springs become short ease curves under Reduce Motion.
enum Motion {
    static func spring(_ reduce: Bool, response: Double = 0.4) -> Animation {
        reduce ? .easeInOut(duration: 0.2) : .spring(response: response, dampingFraction: 0.86)
    }

    static func move(_ reduce: Bool, edge: Edge = .top) -> AnyTransition {
        reduce ? .opacity : .move(edge: edge).combined(with: .opacity)
    }
}

/// Rolling digits, or a plain swap under Reduce Motion.
struct NumericTransition: ViewModifier {
    var countsDown = false
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.contentTransition(reduceMotion ? .opacity : .numericText(countsDown: countsDown))
    }
}

extension View {
    func numericTransition(countsDown: Bool = false) -> some View { modifier(NumericTransition(countsDown: countsDown)) }
}

// MARK: - GlassSurface

/// The one surface everything sits on: Liquid Glass on macOS 26, a regular material before that, and a solid
/// window background under Reduce Transparency. Increase Contrast adds a visible edge.
struct GlassSurface: ViewModifier {
    var radius: CGFloat = Metrics.surfaceRadius
    @SwiftUI.Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @SwiftUI.Environment(\.vigilForceSolid) private var forceSolid
    @SwiftUI.Environment(\.vigilSnapshot) private var snapshot
    @SwiftUI.Environment(\.colorSchemeContrast) private var contrast
    @SwiftUI.Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let edge = shape.strokeBorder(.primary.opacity(contrast == .increased ? 0.45 : 0.1), lineWidth: contrast == .increased ? 1 : 0.5)
        if reduceTransparency || forceSolid {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay(edge)
                .shadow(color: .black.opacity(0.2), radius: 14, y: 6)
        } else if snapshot {
            content
                .background(Color(nsColor: .windowBackgroundColor).opacity(scheme == .dark ? 0.55 : 0.6), in: shape)
                .overlay(shape.strokeBorder(.white.opacity(scheme == .dark ? 0.18 : 0.5), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        } else if #available(macOS 26, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: radius))
                .overlay { if contrast == .increased { edge } }
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(edge)
                .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        }
    }
}

extension View {
    func glassSurface(radius: CGFloat = Metrics.surfaceRadius) -> some View { modifier(GlassSurface(radius: radius)) }

    /// `.glass` on macOS 26, `.bordered` before; prominent: `.glassProminent` / `.borderedProminent`.
    func vigilButtonStyle(prominent: Bool = false) -> some View { modifier(VigilButtonStyle(prominent: prominent)) }
}

private struct VigilButtonStyle: ViewModifier {
    let prominent: Bool
    @SwiftUI.Environment(\.vigilSnapshot) private var snapshot

    func body(content: Content) -> some View {
        if snapshot {
            if prominent { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
        } else if #available(macOS 26, *) {
            if prominent { content.buttonStyle(.glassProminent) } else { content.buttonStyle(.glass) }
        } else {
            if prominent { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
        }
    }
}

// MARK: - Hairline

struct Hairline: View {
    @SwiftUI.Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        Rectangle()
            .fill(.primary.opacity(Contrast.hairline(contrast)))
            .frame(height: contrast == .increased ? 1 : 0.5)
            .accessibilityHidden(true)
    }
}

// MARK: - SectionHeader

/// Title (.headline), a caption with an optional small state symbol, and a trailing accessory.
struct SectionHeader<Accessory: View>: View {
    let title: String
    var caption: String? = nil
    var symbol: String? = nil
    var symbolColor: Color = .secondary
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                    .accessibilityAddTraits(.isHeader)
                if let caption {
                    HStack(spacing: 4) {
                        if let symbol {
                            // A colored state symbol is drawn solid; hierarchical would fade its fill.
                            Image(systemName: symbol)
                                .symbolRenderingMode(symbolColor == .secondary ? .hierarchical : .monochrome)
                                .foregroundStyle(symbolColor)
                                .contentTransition(.symbolEffect(.replace))
                                .accessibilityHidden(true)
                        }
                        Text(caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .numericTransition()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.caption)
                    .accessibilityElement(children: .combine)
                }
            }
            Spacer(minLength: 8)
            accessory
        }
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(title: String, caption: String? = nil, symbol: String? = nil, symbolColor: Color = .secondary) {
        self.init(title: title, caption: caption, symbol: symbol, symbolColor: symbolColor) { EmptyView() }
    }
}

// MARK: - SegmentedProgressBar

/// 4 pt bar on a translucent track. One segment per task (or a single one); each segment fills by its share of
/// `progress`. `progress == nil` is indeterminate: a soft shimmer, or a slow crossfade under Reduce Motion.
struct SegmentedProgressBar: View {
    var segments = 1
    var progress: Double?
    var tint: Color = .primary
    var dimmed = false
    var accessibilityLabel: String = ""
    var accessibilityValue: String? = nil

    @SwiftUI.Environment(\.colorSchemeContrast) private var contrast
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { g in
            if let progress {
                bars(width: g.size.width, progress: min(1, max(0, progress)))
            } else {
                indeterminate(width: g.size.width)
            }
        }
        .frame(height: Metrics.barHeight)
        .opacity(dimmed ? 0.4 : 1)
        .animation(Motion.spring(reduceMotion, response: 0.6), value: progress)
        .animation(Motion.spring(reduceMotion), value: segments)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue ?? progress.map { L("%d percent", Int(($0 * 100).rounded())) } ?? L("In progress"))
        .accessibilityHidden(accessibilityLabel.isEmpty)
    }

    private var track: Color { .primary.opacity(Contrast.track(contrast)) }

    private func bars(width: CGFloat, progress: Double) -> some View {
        let n = max(1, segments)
        let gap: CGFloat = n == 1 ? 0 : n > 20 ? 2 : 3
        let segment = max(2, (width - gap * CGFloat(n - 1)) / CGFloat(n))
        return HStack(spacing: gap) {
            ForEach(0..<n, id: \.self) { i in
                let fill = min(1, max(0, progress * Double(n) - Double(i)))
                ZStack(alignment: .leading) {
                    Capsule().fill(track)
                    if fill > 0 {
                        Capsule().fill(tint).frame(width: max(Metrics.barHeight, segment * fill))
                    }
                }
                .frame(width: segment)
            }
        }
    }

    @ViewBuilder
    private func indeterminate(width: CGFloat) -> some View {
        if reduceMotion {
            TimelineView(.periodic(from: .now, by: 1.4)) { context in
                let on = Int(context.date.timeIntervalSinceReferenceDate / 1.4) % 2 == 0
                Capsule().fill(tint.opacity(on ? 0.35 : 0.15))
                    .animation(.easeInOut(duration: 1.4), value: on)
            }
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                let phase = (context.date.timeIntervalSinceReferenceDate / 2.6).truncatingRemainder(dividingBy: 1)
                let seg = width * 0.32
                ZStack(alignment: .leading) {
                    Capsule().fill(track)
                    Capsule()
                        .fill(LinearGradient(colors: [tint.opacity(0), tint.opacity(0.8), tint.opacity(0)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: seg)
                        .offset(x: -seg + (width + seg) * phase)
                }
                .clipShape(Capsule())
            }
        }
    }

    /// Usage bars: primary, orange from 80 %, red from 95 %.
    static func usageTint(_ fraction: Double) -> Color {
        if fraction >= 0.95 { return Theme.critical }
        if fraction >= 0.80 { return Theme.warning }
        return .primary
    }
}

// MARK: - MetricRow

/// A label (or a session name with a subtitle), a big rounded number, a bar and caption lines.
/// The usage card's "Current session 5 %" and the popover's primary session are the same row.
struct MetricRow<Caption: View>: View {
    let title: String
    var subtitle: String? = nil
    /// Session names are headlines; usage labels are quiet.
    var prominentTitle = false
    var value: String?
    var valueSecondary = false
    var valueCountsDown = false
    var valueAccessibility: String? = nil
    /// A small line under the number ("běží 12:34").
    var valueCaption: String? = nil
    var bar: SegmentedProgressBar? = nil
    @ViewBuilder var caption: Caption

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(prominentTitle ? .headline : .subheadline.weight(.medium))
                        .foregroundStyle(prominentTitle ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .numericTransition()
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                if let value {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(value)
                            .font(.title.weight(.semibold))
                            .fontDesign(.rounded)
                            .monospacedDigit()
                            .foregroundStyle(valueSecondary ? .secondary : .primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .numericTransition(countsDown: valueCountsDown)
                            .accessibilityLabel(valueAccessibility ?? value)
                        if let valueCaption {
                            Text(valueCaption)
                                .font(.caption)
                                .fontDesign(.rounded)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .numericTransition()
                        }
                    }
                    .layoutPriority(1)
                }
            }
            if let bar { bar }
            caption
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

extension MetricRow where Caption == EmptyView {
    init(title: String, subtitle: String? = nil, prominentTitle: Bool = false, value: String?, valueSecondary: Bool = false,
         valueAccessibility: String? = nil, bar: SegmentedProgressBar? = nil) {
        self.init(title: title, subtitle: subtitle, prominentTitle: prominentTitle, value: value, valueSecondary: valueSecondary,
                  valueAccessibility: valueAccessibility, bar: bar) { EmptyView() }
    }
}

// MARK: - SessionRow

/// Context ring, project, "Opus · krok 4/7 · kontext 42 %", and a trailing value (the estimate, elapsed time, or a button).
struct SessionRow<Trailing: View>: View {
    enum Leading { case ring(Double?), symbol(String, Color) }

    let leading: Leading
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Group {
                switch leading {
                case .ring(let percent):
                    ContextRing(percent: percent)
                case .symbol(let name, let color):
                    Image(systemName: name)
                        .font(.title3)
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(color)
                        .frame(width: 22, height: 22)
                        .accessibilityHidden(true)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            trailing
        }
        .contentShape(Rectangle())
    }
}

/// The trailing number of a session row: rounded, monospaced; secondary when it is only a rough guess.
struct TrailingValue: View {
    let text: String
    var emphasized = true
    var accessibility: String? = nil
    var body: some View {
        Text(text)
            .font(.subheadline.weight(emphasized ? .semibold : .medium))
            .fontDesign(.rounded)
            .monospacedDigit()
            .foregroundStyle(emphasized ? .primary : .secondary)
            .multilineTextAlignment(.trailing)
            .numericTransition()
            .accessibilityLabel(accessibility ?? text)
    }
}

struct ContextRing: View {
    let percent: Double?
    @SwiftUI.Environment(\.colorSchemeContrast) private var contrast
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let f = min(1, max(0, (percent ?? 0) / 100))
        ZStack {
            Circle().stroke(.primary.opacity(Contrast.track(contrast)), lineWidth: 3)
            if percent != nil {
                Circle().trim(from: 0, to: f)
                    .stroke((percent ?? 0) >= 80 ? Theme.warning : Color.primary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: 22, height: 22)
        .animation(reduceMotion ? nil : .smooth, value: f)
        .help(L("Context window used"))
        .accessibilityElement()
        .accessibilityLabel(percent.map { L("Context %d percent", Int($0.rounded())) } ?? L("Context unknown"))
    }
}

// MARK: - StatusInline

/// SF Symbol + secondary text; colored only when the value is abnormal.
struct StatusInline: View {
    let symbol: String
    let text: String
    var tint: Color? = nil
    var accessibility: String
    var help: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .contentTransition(.symbolEffect(.replace))
            Text(text).monospacedDigit().numericTransition().lineLimit(1)
        }
        .font(.footnote)
        .foregroundStyle(tint ?? .secondary)
        .help(help ?? accessibility)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
    }
}

// MARK: - FooterBar

/// "Mac vzhůru · 7:35:17" and the two actions: identical in the popover and the usage card.
struct FooterBar: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Text(model.vigilLine)
                .font(.footnote.weight(.medium))
                .fontDesign(.rounded)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .numericTransition()
            Spacer(minLength: 4)
            Button { model.keepAwake() } label: { Text("+1 h").fontDesign(.rounded) }
                .disabled(!model.enabled)
                .help(L("Keep awake for 1 h"))
                .accessibilityLabel(L("Keep awake for 1 h"))
            Button { model.sleepNow() } label: { Label(L("Sleep"), systemImage: "moon.fill") }
                .help(L("Sleep now"))
                .accessibilityLabel(L("Sleep now"))
        }
        .controlSize(.small)
        .vigilButtonStyle()
    }
}

// MARK: - Buttons

/// A native button, replaced by a small spinner while its job runs.
struct BusyButton: View {
    let title: String
    var busy = false
    var prominent = false
    let action: () -> Void

    var body: some View {
        Group {
            if busy {
                ProgressView().controlSize(.small).frame(minWidth: 44)
                    .accessibilityLabel(L("Working…"))
            } else if prominent {
                Button(title, action: action).buttonStyle(.borderedProminent)
            } else {
                Button(title, action: action).buttonStyle(.bordered)
            }
        }
        .transition(.opacity)
    }
}

/// Info row with a close button (results of install/remove actions).
struct MessageRow: View {
    let text: String
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(text).font(.footnote).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 4)
            Button(action: dismiss) { Image(systemName: "xmark.circle.fill").symbolRenderingMode(.hierarchical) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(L("Close"))
                .accessibilityLabel(L("Close"))
        }
    }
}
