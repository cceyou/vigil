import SwiftUI
import VigilCore

/// The menu bar popover in the "Live Activity" style: island, session card, waiting card, status tiles, actions.
struct PopoverView: View {
    @Bindable var model: AppModel

    var body: some View {
        let accent = model.accent
        VStack(spacing: 12) {
            ZStack(alignment: .trailing) {
                IslandView(state: model.island, accent: accent)
                    .frame(maxWidth: .infinity)
                MoreMenu(model: model)
            }
            .padding(.bottom, 2)

            if let error = model.powerError {
                NoticeCard(symbol: "exclamationmark.triangle.fill", title: L("Couldn't change sleep settings"), detail: error) {
                    if !model.setup.sudoers {
                        ActionButton(title: L("Install sleep permission"), busy: model.busy.contains("sudoers"), prominent: true,
                                     accent: accent) { model.installSudoers() }
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let reason = model.pausedReason {
                NoticeCard(symbol: "pause.circle.fill", title: PausedText.title(reason), detail: PausedText.detail(reason, model: model)) {
                    if reason == .lowBattery {
                        ActionButton(title: L("Change battery limit"), accent: accent) { model.open(.settings) }
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            SessionSection(model: model)

            ForEach(model.waitingSessions.prefix(2)) { session in
                WaitingCard(session: session) { model.openApp(for: session) }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            StatusTiles(environment: model.environment, accent: accent)

            HStack(spacing: 10) {
                Button(L("+1 h awake")) { model.keepAwake() }
                    .buttonStyle(CapsuleButtonStyle(fill: .white, foreground: .black))
                    .disabled(!model.enabled)
                Button(L("Sleep now")) { model.sleepNow() }
                    .buttonStyle(CapsuleButtonStyle(fill: Theme.card, foreground: .white))
            }

            if !model.setup.checklistComplete {
                SetupChecklist(model: model)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }

            if let message = model.message {
                MessageBar(text: message) { model.dismissMessage() }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            BagHint()
        }
        .padding(16)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.background)
        .environment(\.colorScheme, .dark)
        .tint(accent)
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: model.island.kind)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.waitingSessions.map(\.id))
        .animation(.smooth, value: model.message)
        .animation(.smooth, value: model.setup)
    }
}

// MARK: - Island

/// Centered black capsule: accent bolt on the left, the most important live value on the right.
struct IslandView: View {
    let state: IslandState
    let accent: Color

    private var text: String {
        switch state {
        case .working(let elapsed): return Format.clock(elapsed)
        case .countdown(let remaining): return L("Sleeps in %@", Format.clock(remaining))
        case .waiting: return L("Waiting")
        case .idle: return L("Ready")
        case .off: return L("Off")
        case .paused: return L("Paused")
        }
    }

    private var color: Color {
        switch state {
        case .working, .countdown: return accent
        case .waiting: return Theme.waiting
        case .idle, .off, .paused: return .secondary
        }
    }

    private var width: CGFloat {
        switch state {
        case .working, .countdown, .paused: return 210
        case .idle, .off: return 190
        case .waiting: return 150
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(accent)
                .frame(width: 24, height: 24)
                .overlay(Image(systemName: "bolt.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(.black))
            Spacer(minLength: 4)
            Text(text)
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(color)
                .contentTransition(.numericText(countsDown: { if case .countdown = state { return true }; return false }()))
                .lineLimit(1)
        }
        .padding(.leading, 7).padding(.trailing, 14)
        .frame(width: width, height: 38)
        .background(Capsule().fill(Color.black))
        .overlay(Capsule().strokeBorder(Theme.outline, lineWidth: 1))
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: width)
        .animation(.smooth(duration: 0.3), value: text)
    }
}

/// "…" in the top right corner: History, Settings, Quit.
struct MoreMenu: View {
    let model: AppModel
    var body: some View {
        Menu {
            Button(L("History")) { model.open(.history) }
            Button(L("Settings")) { model.open(.settings) }
            Divider()
            Button(L("Quit")) { model.quit() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Theme.card, in: Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("More"))
    }
}

// MARK: - Session card(s)

/// One card for the most recently active session, or a horizontally paged stack when several are working.
struct SessionSection: View {
    @Bindable var model: AppModel

    var body: some View {
        let working = model.workingByActivity
        if working.count > 1 {
            VStack(spacing: 8) {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(working) { session in
                            SessionCard(model: model, session: session)
                                .containerRelativeFrame(.horizontal)
                                .id(session.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $model.sessionPage)
                .scrollIndicators(.hidden)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))

                PageDots(ids: working.map(\.id), selected: model.sessionPage ?? working.first?.id, accent: model.accent) { id in
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { model.sessionPage = id }
                }
            }
        } else {
            SessionCard(model: model, session: model.primarySession)
        }
    }
}

struct PageDots: View {
    let ids: [String]
    let selected: String?
    let accent: Color
    let select: (String) -> Void
    var body: some View {
        HStack(spacing: 7) {
            ForEach(ids, id: \.self) { id in
                Button { select(id) } label: {
                    Capsule()
                        .fill(id == selected ? Color.white : Theme.track)
                        .frame(width: id == selected ? 16 : 6, height: 6)
                        .contentShape(Rectangle().inset(by: -4))
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: selected)
    }
}

struct SessionCard: View {
    let model: AppModel
    let session: Session?

    private var stateLabel: String {
        switch model.island {
        case .countdown: return L("Going to sleep")
        case .off: return L("Off")
        case .paused: return L("Paused")
        case .working:
            if let session, !session.isWorking { return L("Ready") }
            return model.workingSessions.isEmpty ? L("Keeping awake") : L("Claude is working")
        case .waiting, .idle: return L("Ready")
        }
    }

    private var title: String {
        if let session { return session.projectName }
        return model.keepAwakeRemaining != nil ? L("Keeping awake") : L("No Claude Code session")
    }

    private var subtitle: String {
        if let session { return Format.agents(session.subagents.count) }
        return model.enabled ? L("Starts as soon as Claude Code begins working.") : L("Your Mac sleeps normally.")
    }

    private var running: TimeInterval? {
        if let session {
            return model.now.timeIntervalSince(session.workingSince ?? session.startedAt)
        }
        return model.machine.awakeHeld ? model.awakeElapsed : nil
    }

    var body: some View {
        let accent = model.accent
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(accent)
                    Text("Vigil").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Text(stateLabel).font(.system(size: 13, weight: .semibold)).foregroundStyle(accent)
                        .contentTransition(.interpolate)
                }

                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, 14)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .contentTransition(.numericText())
                    .padding(.top, 2)

                SleepTrack(progress: model.sleepProgress, accent: accent)
                    .padding(.top, 18)

                HStack(alignment: .firstTextBaseline) {
                    if let running {
                        FooterValue(label: L("Running"), value: Format.clock(running))
                    }
                    Spacer(minLength: 8)
                    if let r = model.countdownRemaining, model.phase == .countdown {
                        FooterValue(label: L("Sleeps in"), value: Format.clock(r))
                    } else if let r = model.awakeRemaining {
                        FooterValue(label: L("Awake for"), value: Format.clock(r))
                    }
                }
                .padding(.top, 12)

                if model.phase == .countdown {
                    HStack {
                        Spacer()
                        Button(L("Cancel")) { model.cancelCountdown() }
                            .buttonStyle(PillButtonStyle())
                    }
                    .padding(.top, 10)
                    .transition(.opacity)
                }
            }
        }
    }
}

struct FooterValue: View {
    let label: String
    let value: String
    var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(value).foregroundStyle(.primary).monospacedDigit().contentTransition(.numericText())
        }
        .font(.system(size: 13, weight: .medium))
        .lineLimit(1)
    }
}

/// bolt ─── track ─── moon: progress toward sleep. `nil` progress: indeterminate, a slow shimmer moves along.
struct SleepTrack: View {
    let progress: Double?
    let accent: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(accent)
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track).frame(height: 6)
                    if let progress {
                        Capsule().fill(accent).frame(width: max(6, w * progress), height: 6)
                        Circle().fill(.white).frame(width: 14, height: 14)
                            .shadow(color: .black.opacity(0.4), radius: 2)
                            .offset(x: min(w - 14, max(0, w * progress - 7)))
                    } else {
                        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                            let t = context.date.timeIntervalSinceReferenceDate
                            let phase = (t / 2.6).truncatingRemainder(dividingBy: 1) // one sweep every 2.6 s
                            let seg = w * 0.32
                            Capsule()
                                .fill(LinearGradient(colors: [accent.opacity(0), accent, accent.opacity(0)],
                                                     startPoint: .leading, endPoint: .trailing))
                                .frame(width: seg, height: 6)
                                .offset(x: -seg + (w + seg) * phase)
                        }
                        .frame(width: w, height: 6)
                        .clipShape(Capsule())
                    }
                }
                .frame(height: 14)
                .animation(.linear(duration: 1), value: progress)
            }
            .frame(height: 14)
            Image(systemName: "moon.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Waiting card

struct WaitingCard: View {
    let session: Session
    let open: () -> Void
    var body: some View {
        Card(padding: 14) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.waiting)
                    .frame(width: 40, height: 40)
                    .overlay(Image(systemName: "questionmark").font(.system(size: 18, weight: .bold)).foregroundStyle(.black))
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.projectName).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(L("Waiting for your answer")).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.waiting)
                }
                Spacer(minLength: 6)
                Button(L("Open"), action: open)
                    .buttonStyle(PillButtonStyle(fill: Theme.waiting, foreground: .black))
            }
        }
    }
}

// MARK: - Status tiles

struct StatusTiles: View {
    let environment: VigilCore.Environment
    let accent: Color

    var body: some View {
        let env = environment
        HStack(spacing: 8) {
            Tile(symbol: env.lidClosed ? "laptopcomputer.slash" : "laptopcomputer", symbolColor: .primary,
                 title: L("Lid"), value: env.lidClosed ? L("Closed (lid)") : L("Open (lid)"))
            Tile(symbol: batterySymbol(env), symbolColor: env.isCharging ? Theme.accent(.green) : .primary,
                 title: L("Battery"), value: env.batteryPercent.map { "\($0) %" } ?? "—", detail: batteryDetail(env))
            Tile(symbol: env.thermal.rawValue >= ThermalLevel.serious.rawValue ? "thermometer.high" : "thermometer.medium",
                 symbolColor: .primary, title: L("Temperature"), value: thermalText(env.thermal))
        }
        .animation(.smooth, value: env)
    }

    private func batterySymbol(_ env: VigilCore.Environment) -> String {
        guard let pct = env.batteryPercent else { return "powerplug.fill" }
        if env.isCharging { return "battery.100percent.bolt" }
        switch pct {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private func batteryDetail(_ env: VigilCore.Environment) -> String? {
        guard env.batteryPercent != nil else { return nil }
        if env.isCharging { return L("Charging") }
        return env.onBattery ? L("On battery") : L("Plugged in")
    }

    private func thermalText(_ level: ThermalLevel) -> String {
        switch level {
        case .nominal: return L("Normal")
        case .fair: return L("Elevated")
        case .serious, .critical: return L("High")
        }
    }
}

struct Tile: View {
    let symbol: String
    let symbolColor: Color
    let title: String
    let value: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(symbolColor)
                .contentTransition(.symbolEffect(.replace))
                .frame(height: 20)
            Spacer(minLength: 10)
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                .contentTransition(.numericText())
            Text(detail ?? " ").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous))
    }
}

// MARK: - Notices

enum PausedText {
    static func title(_ reason: GuardReason) -> String {
        switch reason {
        case .lowBattery: return L("Paused · battery low")
        case .thermal: return L("Paused · Mac is too hot")
        case .maxDuration: return L("Paused · time limit reached")
        case .manualSleep: return L("Paused · you put the Mac to sleep")
        }
    }

    @MainActor
    static func detail(_ reason: GuardReason, model: AppModel) -> String {
        switch reason {
        case .lowBattery:
            let pct = model.environment.batteryPercent.map { "\($0) %" } ?? "?"
            return L("Battery %@ is below the %@ limit, so closing the lid sleeps the Mac. Plug in, or lower the limit in Settings.",
                     pct, "\(model.settings.config.lowBatteryThreshold) %")
        case .thermal: return L("Let it cool down on a flat surface; Vigil resumes by itself.")
        case .maxDuration: return L("Resumes once Claude is idle again.")
        case .manualSleep: return L("Resumes with the next prompt.")
        }
    }
}

struct NoticeCard<Actions: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder var actions: Actions
    var body: some View {
        Card(padding: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .lineLimit(4)
                    actions.padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Onboarding

struct SetupChecklist: View {
    let model: AppModel

    var body: some View {
        let s = model.setup
        let accent = model.accent
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(L("Setup")).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text("\(s.doneCount)/5").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).monospacedDigit()
                        .contentTransition(.numericText())
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.track)
                        Capsule().fill(accent).frame(width: g.size.width * CGFloat(s.doneCount) / 5)
                    }
                }
                .frame(height: 6)
                .animation(.spring(response: 0.6, dampingFraction: 0.8), value: s.doneCount)

                step(title: L("Sleep permission"),
                     detail: L("One-time admin password so Vigil can keep the Mac awake with the lid closed."),
                     done: s.sudoers, action: L("Allow"), busy: model.busy.contains("sudoers")) { model.installSudoers() }
                if s.hooksOutdated {
                    step(title: L("Claude Code hooks are out of date"),
                         detail: L("Adds the newer hooks (subagents, waiting for your answer). Other hooks are left alone."),
                         done: s.hooks, action: L("Update hooks"), busy: model.busy.contains("hooks")) { model.updateHooks() }
                } else {
                    step(title: L("Claude Code hooks"),
                         detail: L("Adds hooks to ~/.claude/settings.json (backed up first)."),
                         done: s.hooks, action: L("Add hooks"), busy: model.busy.contains("hooks")) { model.installHooks() }
                }
                step(title: L("Status line"),
                     detail: L("Shows your Claude usage limits at the screen edge. Your current status line keeps working."),
                     done: s.statusLine, action: L("Install"), busy: model.busy.contains("statusLine")) { model.installStatusLine() }
                step(title: L("Notifications"),
                     detail: L("Warns you before the Mac sleeps, with Cancel and Keep awake buttons."),
                     done: s.notifications, action: L("Allow"), busy: false) { model.requestNotifications() }
                step(title: L("Launch at login"),
                     detail: L("Start Vigil automatically when you log in."),
                     done: s.loginItem, action: L("Enable"), busy: false) { model.setLaunchAtLogin(true) }

                if model.hooksJustInstalled {
                    Label(L("Restart Claude Code sessions that are already running so they load the new hooks."),
                          systemImage: "arrow.clockwise")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }

                Button { model.runSelfTest() } label: { Label(L("Run self-test"), systemImage: "checklist") }
                    .buttonStyle(PillButtonStyle())
            }
        }
    }

    @ViewBuilder
    private func step(title: String, detail: String, done: Bool, action: String, busy: Bool,
                      perform: @escaping () -> Void) -> some View {
        if !done {
            HStack(alignment: .top, spacing: 10) {
                StatusDot(ok: done, accent: model.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                ActionButton(title: action, busy: busy, prominent: true, accent: model.accent, action: perform)
            }
            .transition(.move(edge: .leading).combined(with: .opacity))
        }
    }
}

// MARK: - Chrome

struct BagHint: View {
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "flame.fill").font(.system(size: 10))
            Text(L("A closed laptop in a bag overheats. Keep it on a flat surface, ideally plugged in."))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
    }
}

struct MessageBar: View {
    let text: String
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 4)
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous))
    }
}
