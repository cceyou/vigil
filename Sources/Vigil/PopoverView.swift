import SwiftUI
import VigilCore

struct PopoverView: View {
    @Bindable var model: AppModel

    var body: some View {
        let mood = model.mood
        VStack(spacing: 0) {
            HeroView(model: model, compact: model.tab != .overview)
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 14) {
                    switch model.tab {
                    case .overview: OverviewView(model: model)
                    case .history: HistoryView(model: model)
                    case .settings: SettingsView(model: model)
                    case .selfTest: SelfTestView(model: model)
                    }
                }
                .id(model.tab)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 14)),
                                        removal: .opacity))
                .padding(.horizontal, 16).padding(.bottom, 12).padding(.top, 2)
            }
            .scrollIndicators(.hidden)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.03),
                                         .init(color: .black, location: 0.95), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))

            if let message = model.message {
                MessageBar(text: message) { model.dismissMessage() }
                    .padding(.horizontal, 16).padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if model.tab != .selfTest {
                TabBar(selection: $model.tab, tint: mood.tint)
                    .padding(.horizontal, 16).padding(.bottom, 14).padding(.top, 4)
            }
        }
        .frame(width: 380, height: 600)
        .background {
            ZStack {
                Rectangle().fill(.regularMaterial)
                // Mood-tinted wash at the top; crossfades when the state changes.
                LinearGradient(colors: [mood.tint.opacity(0.22), mood.glow.opacity(0.06), .clear],
                               startPoint: .top, endPoint: .init(x: 0.5, y: 0.55))
            }
            .ignoresSafeArea()
        }
        .animation(.smooth(duration: 0.6), value: mood)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: model.tab)
        .animation(.smooth, value: model.message)
    }
}

// MARK: - Hero

struct HeroView: View {
    let model: AppModel
    let compact: Bool

    private var title: String {
        if let reason = model.pausedReason { return Self.pausedTitle(reason) }
        switch model.phase {
        case .off: return L("Vigil is off")
        case .armed: return L("Armed · waiting for Claude")
        case .working:
            if model.onlySubagentsWorking { return L("Subagents working · %@", Format.clock(model.workingElapsed)) }
            return L("Claude is working · %@", Format.clock(model.workingElapsed))
        case .countdown: return L("Sleeping in %@", Format.clock(model.countdownRemaining ?? 0))
        }
    }

    private var subtitle: String {
        if let reason = model.pausedReason { return Self.pausedDetail(reason, model: model) }
        switch model.phase {
        case .off: return L("Your Mac sleeps normally.")
        case .armed:
            return model.keepAwakeRemaining != nil ? L("Keeping awake") : L("Starts as soon as Claude Code begins working.")
        case .working:
            if model.onlySubagentsWorking {
                return L("The main agent is done; still running: %@. Your Mac stays awake until they finish.",
                         Format.subagents(model.activeSubagentCount))
            }
            let n = model.workingSessions.count
            if n == 0 { return L("Keeping awake manually. The lid can stay closed.") }
            return n == 1 ? L("1 session working. Your Mac stays awake, even with the lid closed.")
                          : L("%d sessions working. Your Mac stays awake, even with the lid closed.", n)
        case .countdown: return L("Claude Code has finished.")
        }
    }

    static func pausedTitle(_ reason: GuardReason) -> String {
        switch reason {
        case .lowBattery: return L("Paused · battery low")
        case .thermal: return L("Paused · Mac is too hot")
        case .maxDuration: return L("Paused · time limit reached")
        case .manualSleep: return L("Paused · you put the Mac to sleep")
        }
    }

    static func pausedDetail(_ reason: GuardReason, model: AppModel) -> String {
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

    var body: some View {
        let mood = model.mood
        let layout = compact ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 10))
        VStack(spacing: 12) {
            layout {
                ZStack {
                    Orb(mood: mood, progress: model.countdownProgress, size: compact ? 56 : 132)
                    center(mood: mood)
                }
                .frame(width: compact ? 56 : 132, height: compact ? 56 : 132)

                VStack(alignment: compact ? .leading : .center, spacing: 4) {
                    Text(title)
                        .font(.system(size: compact ? 15 : 19, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .multilineTextAlignment(compact ? .leading : .center)
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.system(size: compact ? 11 : 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(compact ? .leading : .center)
                        .lineLimit(compact ? 2 : 4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: compact ? .leading : .center)
            }

            if !compact {
                EnvironmentChips(model: model)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            if model.phase == .countdown && !compact {
                HStack(spacing: 8) {
                    Button { model.cancelCountdown() } label: { Label(L("Cancel"), systemImage: "xmark") }
                        .buttonStyle(SoftButtonStyle(tint: mood.tint))
                    Button { model.keepAwake() } label: { Label(L("Keep awake"), systemImage: "bolt.fill") }
                        .buttonStyle(SoftButtonStyle(tint: mood.tint, prominent: true))
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: compact)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: model.phase)
        .animation(.smooth, value: title)
    }

    @ViewBuilder
    private func center(mood: Mood) -> some View {
        if mood == .countdown, !compact, let r = model.countdownRemaining {
            VStack(spacing: 0) {
                Text(Format.clock(r))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                Image(systemName: "moon.fill").font(.system(size: 11)).foregroundStyle(mood.tint)
            }
            .transition(.scale.combined(with: .opacity))
        } else {
            Image(systemName: mood.symbol)
                .font(.system(size: compact ? 18 : 38, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [mood.tint, mood.glow], startPoint: .top, endPoint: .bottom))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.pulse, options: .repeating, isActive: mood == .working || mood == .paused)
                .shadow(color: mood.tint.opacity(0.5), radius: 8)
        }
    }
}

/// Live lid / power / heat readout. It makes it obvious why the Mac would or would not stay awake.
struct EnvironmentChips: View {
    let model: AppModel

    var body: some View {
        let env = model.environment
        let threshold = model.settings.config.lowBatteryThreshold
        let low = env.onBattery && (env.batteryPercent ?? 100) < threshold
        HStack(spacing: 6) {
            Chip(symbol: env.lidClosed ? "laptopcomputer.slash" : "laptopcomputer",
                 text: env.lidClosed ? L("Lid closed") : L("Lid open"))
            if let pct = env.batteryPercent {
                Chip(symbol: env.onBattery ? batterySymbol(pct) : "bolt.batteryblock.fill",
                     text: env.onBattery ? "\(pct) %" : L("Plugged in"),
                     tint: low ? Mood.paused.tint : .secondary)
            }
            if env.thermal.rawValue >= ThermalLevel.serious.rawValue {
                Chip(symbol: "thermometer.high", text: L("Hot"), tint: Mood.paused.tint)
            }
        }
        .animation(.smooth, value: env)
    }

    private func batterySymbol(_ pct: Int) -> String {
        switch pct {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

// MARK: - Overview

struct OverviewView: View {
    @Bindable var model: AppModel

    var body: some View {
        if let error = model.powerError {
            Card {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Mood.paused.tint)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("Couldn't change sleep settings")).font(.system(size: 13, weight: .semibold))
                        Text(error).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                        if !model.setup.sudoers {
                            ActionButton(title: L("Install sleep permission"), busy: model.busy.contains("sudoers"), prominent: true) {
                                model.installSudoers()
                            }
                        }
                    }
                }
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }

        if model.pausedReason == .lowBattery {
            Button { model.tab = .settings } label: {
                Label(L("Change battery limit"), systemImage: "battery.25percent")
            }
            .buttonStyle(SoftButtonStyle(tint: Mood.paused.tint))
            .transition(.move(edge: .top).combined(with: .opacity))
        }

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(text: L("Sessions"))
                Spacer()
                if !model.machine.sessions.isEmpty {
                    Text("\(model.machine.sessions.count)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .padding(.trailing, 4)
                }
            }
            SessionList(model: model)
        }

        HStack(spacing: 8) {
            Button { model.sleepNow() } label: { Label(L("Sleep now"), systemImage: "moon.zzz.fill") }
                .buttonStyle(SoftButtonStyle(tint: Mood.armed.tint))
            Button { model.keepAwake() } label: { Label(L("Keep awake for 1 h"), systemImage: "bolt.fill") }
                .buttonStyle(SoftButtonStyle(tint: Mood.working.tint, prominent: true))
                .disabled(!model.enabled)
        }

        if let remaining = model.keepAwakeRemaining {
            Text(L("Keeping awake for another %@", Format.clock(remaining)))
                .font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary).monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
                .transition(.opacity)
        }

        if !model.setup.checklistComplete {
            SetupChecklist(model: model)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
        }

        Card {
            Toggle(isOn: Binding(get: { model.enabled }, set: { v in withAnimation(.smooth) { model.setEnabled(v) } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Watch Claude Code")).font(.system(size: 13, weight: .semibold))
                    Text(L("Keep the Mac awake while Claude works, then sleep it.")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .tint(Mood.working.tint)
        }

        BagHint()
    }
}

struct SessionList: View {
    let model: AppModel

    var body: some View {
        let sessions = model.machine.sessions
        VStack(spacing: 6) {
            if sessions.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "terminal").foregroundStyle(.tertiary)
                    Text(L("No Claude Code sessions yet")).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(12)
                .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .transition(.opacity)
            } else {
                ForEach(sessions) { s in
                    SessionRow(session: s, now: model.now,
                               showAgents: Binding(get: { model.expandedSessions.contains(s.id) },
                                                   set: { on in
                                                       if on { model.expandedSessions.insert(s.id) } else { model.expandedSessions.remove(s.id) }
                                                   }))
                        .transition(.asymmetric(insertion: .scale(scale: 0.92).combined(with: .opacity),
                                                removal: .move(edge: .leading).combined(with: .opacity)))
                }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: sessions.map(\.id))
        .animation(.smooth, value: sessions.map(\.state))
        .animation(.smooth, value: sessions.map(\.subagents.count))
    }
}

struct SessionRow: View {
    let session: Session
    let now: Date
    @Binding var showAgents: Bool

    var body: some View {
        // Running subagents make the session "working" even after the main agent's Stop.
        let state: SessionState = session.isWorking ? .working : session.state
        let tint = Self.tint(state)
        let since = session.workingSince ?? session.stateSince
        HStack(alignment: .top, spacing: 12) {
            LiveDot(tint: tint, live: state == .working)
                .frame(width: 20, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.projectName).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(Format.clock(now.timeIntervalSince(since)))
                        .font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary).monospacedDigit()
                        .contentTransition(.numericText())
                    if !session.subagents.isEmpty {
                        subagentBadge(tint: tint)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                if showAgents && !session.subagents.isEmpty {
                    Text(Format.agentTypes(session.subagents))
                        .font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            Spacer()
            Pill(text: Self.label(state), tint: tint)
                .contentTransition(.interpolate)
                .frame(height: 34)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(state == .working ? 0.12 : 0.05), .primary.opacity(0.03)],
                                     startPoint: .leading, endPoint: .trailing))
        }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.16)))
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showAgents)
    }

    /// "⑂ 2 subagents ›": hover lists the agent types, click discloses them under the row.
    private func subagentBadge(tint: Color) -> some View {
        Button { showAgents.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 9, weight: .bold))
                Text(Format.subagents(session.subagents.count))
                    .contentTransition(.numericText())
                Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold))
                    .rotationEffect(.degrees(showAgents ? 90 : 0))
            }
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(Format.agentTypes(session.subagents))
    }

    static func label(_ s: SessionState) -> String {
        switch s {
        case .working: return L("Working")
        case .waiting: return L("Waiting for you")
        case .idle: return L("Idle")
        }
    }

    static func tint(_ s: SessionState) -> Color {
        switch s {
        case .working: return Mood.working.tint
        case .waiting: return Mood.countdown.tint
        case .idle: return Mood.off.tint
        }
    }
}

// MARK: - Onboarding

struct SetupChecklist: View {
    let model: AppModel

    var body: some View {
        let s = model.setup
        let done = [s.sudoers, s.hooks, s.notifications, s.loginItem].filter { $0 }.count
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(text: L("Setup"))
                Spacer()
                Text("\(done)/4").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                    .contentTransition(.numericText()).padding(.trailing, 4)
            }
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.primary.opacity(0.08))
                            Capsule().fill(LinearGradient(colors: [Mood.working.tint, Mood.working.glow], startPoint: .leading, endPoint: .trailing))
                                .frame(width: g.size.width * CGFloat(done) / 4)
                        }
                    }
                    .frame(height: 5)
                    .animation(.spring(response: 0.6, dampingFraction: 0.8), value: done)
                    .padding(.bottom, 2)

                    step(title: L("Sleep permission"),
                         detail: L("One-time admin password so Vigil can keep the Mac awake with the lid closed."),
                         done: s.sudoers, action: L("Allow"), busy: model.busy.contains("sudoers")) { model.installSudoers() }
                    if s.hooksOutdated {
                        step(title: L("Claude Code hooks are out of date"),
                             detail: L("Adds the subagent hooks, so the Mac stays awake while subagents work. Other hooks are left alone."),
                             done: s.hooks, action: L("Update hooks"), busy: model.busy.contains("hooks")) { model.updateHooks() }
                    } else {
                        step(title: L("Claude Code hooks"),
                             detail: L("Adds hooks to ~/.claude/settings.json (backed up first)."),
                             done: s.hooks, action: L("Add hooks"), busy: model.busy.contains("hooks")) { model.installHooks() }
                    }
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
                        .buttonStyle(SoftButtonStyle(tint: Mood.armed.tint))
                }
            }
        }
    }

    @ViewBuilder
    private func step(title: String, detail: String, done: Bool, action: String, busy: Bool,
                      perform: @escaping () -> Void) -> some View {
        if !done {
            HStack(alignment: .top, spacing: 10) {
                StatusDot(ok: done)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                ActionButton(title: action, busy: busy, prominent: true, action: perform)
            }
            .transition(.move(edge: .leading).combined(with: .opacity))
        }
    }
}

// MARK: - Chrome

struct BagHint: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "flame.fill").foregroundStyle(Mood.countdown.tint).font(.system(size: 11))
            Text(L("A closed laptop in a bag overheats. Keep it on a flat surface, ideally plugged in."))
                .font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

struct MessageBar: View {
    let text: String
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(Mood.armed.tint)
            Text(text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 4)
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Mood.armed.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
