import SwiftUI
import VigilCore

struct PopoverView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(model: model)
                .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)

            if model.tab != .selfTest {
                Picker("", selection: $model.tab) {
                    Text(L("Overview")).tag(Tab.overview)
                    Text(L("History")).tag(Tab.history)
                    Text(L("Settings")).tag(Tab.settings)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16).padding(.bottom, 10)
            }

            ScrollView {
                VStack(spacing: 14) {
                    switch model.tab {
                    case .overview: OverviewView(model: model)
                    case .history: HistoryView(model: model)
                    case .settings: SettingsView(model: model)
                    case .selfTest: SelfTestView(model: model)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 12)
                .animation(.smooth(duration: 0.25), value: model.tab)
            }
            .scrollIndicators(.hidden)

            if let message = model.message {
                MessageBar(text: message) { model.dismissMessage() }
                    .padding(.horizontal, 16).padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            BagHint()
                .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 380, height: 600)
        .background(.regularMaterial)
        .animation(.smooth, value: model.message)
    }
}

// MARK: header

struct HeaderView: View {
    let model: AppModel

    private var title: String {
        switch model.phase {
        case .off: return L("Vigil is off")
        case .armed: return L("Armed · waiting for Claude")
        case .working: return L("Claude is working · %@", Format.clock(model.workingElapsed))
        case .countdown: return L("Sleeping in %@", Format.clock(model.countdownRemaining ?? 0))
        }
    }

    private var subtitle: String {
        switch model.phase {
        case .off: return L("Your Mac sleeps normally.")
        case .armed:
            return model.keepAwakeRemaining != nil ? L("Keeping awake") : L("Starts as soon as Claude Code begins working.")
        case .working:
            let n = model.workingSessions.count
            if n == 0 { return L("Keeping awake manually. The lid can stay closed.") }
            return n == 1 ? L("1 session working. Your Mac stays awake, even with the lid closed.")
                          : L("%d sessions working. Your Mac stays awake, even with the lid closed.", n)
        case .countdown: return L("Claude Code has finished.")
        }
    }

    var body: some View {
        let phase = model.phase
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(phase.tint.opacity(0.18))
                    Image(systemName: phase.symbol)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(phase.tint)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.pulse, options: .repeating, isActive: phase == .working)
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 18, weight: .semibold, design: .default))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if phase == .countdown {
                HStack(spacing: 8) {
                    Button { model.cancelCountdown() } label: {
                        Label(L("Cancel"), systemImage: "xmark").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button { model.keepAwake() } label: {
                        Label(L("Keep awake"), systemImage: "bolt.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.orange)
                }
                .controlSize(.regular)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .padding(14)
        .background(phase.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(phase.tint.opacity(0.18)))
        .animation(.smooth(duration: 0.35), value: phase)
    }
}

// MARK: overview

struct OverviewView: View {
    @Bindable var model: AppModel

    var body: some View {
        if !model.setup.checklistComplete {
            SetupChecklist(model: model)
        }

        if let error = model.powerError {
            Card {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
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
        }

        Card {
            Toggle(isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Watch Claude Code")).font(.system(size: 14, weight: .semibold))
                    Text(L("Keep the Mac awake while Claude works, then sleep it.")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
        }

        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: L("Sessions"))
            Card(padding: 4) { SessionList(model: model) }
        }

        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button { model.sleepNow() } label: {
                    Label(L("Sleep now"), systemImage: "moon.zzz").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button { model.keepAwake() } label: {
                    Label(L("Keep awake for 1 h"), systemImage: "bolt.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.enabled)
            }
            .controlSize(.large)

            if let remaining = model.keepAwakeRemaining {
                Text(L("Keeping awake for another %@", Format.clock(remaining)))
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
        }

        Card {
            SettingRow(title: L("Grace period"), subtitle: L("How long to wait after Claude finishes before sleeping.")) {
                Picker("", selection: Binding(get: { model.settings.config.graceSeconds },
                                              set: { v in model.update { $0.config.graceSeconds = v } })) {
                    ForEach([10.0, 30, 60, 120, 300], id: \.self) { Text(Durations.short($0)).tag($0) }
                }
                .labelsHidden().frame(width: 84)
            }
        }
    }
}

struct SessionList: View {
    let model: AppModel

    var body: some View {
        let sessions = model.machine.sessions
        if sessions.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "terminal").foregroundStyle(.tertiary)
                Text(L("No Claude Code sessions yet")).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(10)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, s in
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.projectName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text(Format.clock(model.now.timeIntervalSince(s.stateSince)))
                                .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Spacer()
                        Pill(text: stateLabel(s.state), tint: stateTint(s.state))
                    }
                    .padding(10)
                    if index < sessions.count - 1 { Divider().opacity(0.5) }
                }
            }
            .animation(.smooth, value: sessions.map(\.id))
        }
    }

    private func stateLabel(_ s: SessionState) -> String {
        switch s {
        case .working: return L("Working")
        case .waiting: return L("Waiting for you")
        case .idle: return L("Idle")
        }
    }

    private func stateTint(_ s: SessionState) -> Color {
        switch s {
        case .working: return .green
        case .waiting: return .orange
        case .idle: return .gray
        }
    }
}

// MARK: onboarding

struct SetupChecklist: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: L("Setup"))
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    step(1, title: L("Sleep permission"),
                         detail: L("One-time admin password so Vigil can keep the Mac awake with the lid closed."),
                         done: model.setup.sudoers, action: L("Allow"), busy: model.busy.contains("sudoers")) { model.installSudoers() }
                    step(2, title: L("Claude Code hooks"),
                         detail: L("Adds hooks to ~/.claude/settings.json (backed up first)."),
                         done: model.setup.hooks, action: L("Add hooks"), busy: model.busy.contains("hooks")) { model.installHooks() }
                    step(3, title: L("Notifications"),
                         detail: L("Warns you before the Mac sleeps, with Cancel and Keep awake buttons."),
                         done: model.setup.notifications, action: L("Allow"), busy: false) { model.requestNotifications() }
                    step(4, title: L("Launch at login"),
                         detail: L("Start Vigil automatically when you log in."),
                         done: model.setup.loginItem, action: L("Enable"), busy: false) { model.setLaunchAtLogin(true) }

                    if model.hooksJustInstalled || model.setup.hooks {
                        Label(L("Restart Claude Code sessions that are already running so they load the new hooks."),
                              systemImage: "arrow.clockwise")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }

                    Button { model.runSelfTest() } label: {
                        Label(L("Run self-test"), systemImage: "checklist").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).controlSize(.regular)
                }
            }
        }
    }

    private func step(_ n: Int, title: String, detail: String, done: Bool, action: String, busy: Bool,
                      perform: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(ok: done)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(n). \(title)").font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if !done { ActionButton(title: action, busy: busy, prominent: true, action: perform) }
        }
    }
}

// MARK: chrome

struct BagHint: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "flame.fill").foregroundStyle(.orange).font(.system(size: 12))
            Text(L("A closed laptop in a bag overheats. Keep it on a flat surface, ideally plugged in."))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MessageBar: View {
    let text: String
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(.blue)
            Text(text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 4)
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
