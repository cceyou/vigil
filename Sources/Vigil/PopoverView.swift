import SwiftUI
import VigilCore

/// The menu bar popover: one surface (the popover's own system material), grouped by spacing and hairlines,
/// built from the same pieces as the usage card (DesignSystem.swift).
struct PopoverView: View {
    @Bindable var model: AppModel
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let caption = model.stateCaption
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Vigil", caption: caption.text, symbol: caption.symbol, symbolColor: caption.color) {
                MoreMenu(model: model)
            }

            if let error = model.powerError {
                NoticeRow(symbol: "exclamationmark.triangle.fill", tint: Theme.warning,
                          title: L("Couldn't change sleep settings"), detail: error) {
                    if !model.setup.sudoers {
                        BusyButton(title: L("Install sleep permission"), busy: model.busy.contains("sudoers"), prominent: true) {
                            model.installSudoers()
                        }
                    }
                }
                .transition(Motion.move(reduceMotion))
            }

            if let reason = model.pausedReason {
                NoticeRow(symbol: "pause.circle.fill", tint: PausedText.tint(reason),
                          title: PausedText.title(reason), detail: PausedText.detail(reason, model: model)) {
                    if reason == .lowBattery {
                        Button(L("Change battery limit")) { model.open(.settings) }.buttonStyle(.bordered)
                    }
                }
                .transition(Motion.move(reduceMotion))
            }

            PrimarySessionView(model: model)
            SessionList(model: model)

            if !model.setup.checklistComplete {
                Hairline()
                SetupChecklist(model: model)
                    .transition(.opacity)
            }

            Hairline()
            VStack(alignment: .leading, spacing: 12) {
                StatusLine(model: model)
                if model.usage.hasRateLimits {
                    UsageRow(model: model)
                }
                if model.environment.lidClosed && model.environment.onBattery {
                    BagHint().transition(.opacity)
                }
                if let message = model.message {
                    MessageRow(text: message) { model.dismissMessage() }
                        .transition(Motion.move(reduceMotion, edge: .bottom))
                }
            }

            Hairline()
            FooterBar(model: model)
        }
        .padding(Metrics.padding)
        .frame(width: Metrics.popoverWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .animation(Motion.spring(reduceMotion, response: 0.45), value: model.island.kind)
        .animation(Motion.spring(reduceMotion), value: model.waitingSessions.map(\.id))
        .animation(Motion.spring(reduceMotion), value: model.selectedSession?.id)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth, value: model.message)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth, value: model.setup)
    }
}

// MARK: - Header menu

/// ⋯ in the header: Watch Claude Code, History, Settings, Quit.
struct MoreMenu: View {
    let model: AppModel
    var body: some View {
        Menu {
            Toggle(L("Watch Claude Code"), isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) }))
            Divider()
            Button(L("History…")) { model.open(.history) }
            Button(L("Settings…")) { model.open(.settings) }
                .keyboardShortcut(",")
            Divider()
            Button(L("Quit")) { model.quit() }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(.secondary)
        .fixedSize()
        .help(L("More"))
        .accessibilityLabel(L("More"))
    }
}

// MARK: - Primary session

/// The working session (or, when none works, the most recently active one) as a MetricRow: name, the same
/// subtitle as the session list, the estimate or the running time as the big number, one bar segment per task,
/// and what is being worked on. When idle: when the last task finished and how long it took.
struct PrimarySessionView: View {
    let model: AppModel

    private var session: Session? { model.selectedSession }
    private var summary: UsageCardSession? { session.flatMap { s in model.sessionSummaries.first { $0.id == s.id } } }

    /// Only while the session works; the countdown and idle states keep their own look.
    private var eta: SessionEta? {
        guard let session, session.isWorking, model.phase == .working else { return nil }
        return model.eta(for: session.id)
    }

    /// Without a live session, the last finished one from the history (so idle is not an empty row).
    private var lastRecord: SessionRecord? {
        session == nil && model.keepAwakeRemaining == nil ? model.history.first : nil
    }

    private var title: String {
        if let session { return ProjectName.display(session.projectName, cwd: session.cwd) }
        if let lastRecord { return lastRecord.project }
        return model.keepAwakeRemaining != nil ? L("Keeping awake") : L("No Claude Code session")
    }

    /// The session list's subtitle without the step (the caption below names it): "Opus 5.5 · kontext 31 % · + 2 subagenti".
    private var subtitle: String? {
        if var summary {
            summary.step = nil
            if let growth = eta?.growth { return summary.subtitle + " · " + Format.addedSteps(growth) }
            return summary.subtitle
        }
        if let lastRecord { return lastRecord.maxSubagents > 0 ? "+\u{00A0}" + Format.subagents(lastRecord.maxSubagents) : nil }
        return model.enabled ? L("Starts as soon as Claude Code begins working.") : L("Your Mac sleeps normally.")
    }

    private var running: TimeInterval? {
        guard let session, session.isWorking else { return nil }
        return model.now.timeIntervalSince(session.workingSince ?? session.startedAt)
    }

    private struct Value { var text: String; var secondary = false; var countsDown = false; var spoken: String; var caption: String? }

    private var value: Value? {
        if model.phase == .countdown, let r = model.countdownRemaining {
            return Value(text: Format.clock(r), countsDown: true, spoken: L("Sleeps in %@", Format.clock(r)), caption: nil)
        }
        if let eta {
            return Value(text: eta.remainingText, secondary: eta.fromHistory || !eta.confident,
                         spoken: L("About %@ left", eta.remainingText.replacingOccurrences(of: "~", with: "")),
                         caption: running.map { L("running %@", Format.elapsed($0)) })
        }
        if let running {
            return Value(text: Format.elapsed(running), spoken: L("Running %@", Format.elapsed(running)), caption: L("running"))
        }
        if session == nil, model.machine.awakeHeld, let r = model.awakeRemaining {
            return Value(text: Format.elapsed(r), spoken: L("Awake for %@", Format.elapsed(r)), caption: L("awake for"))
        }
        return nil
    }

    /// Task segments with a task list; sleep progress in the countdown or the manual keep-awake hour.
    /// No bar without a task list: a full gray track would read as finished or empty.
    private var bar: SegmentedProgressBar? {
        if let eta {
            guard let total = eta.total, total > 0 else { return nil }
            let done = eta.done ?? 0
            return SegmentedProgressBar(segments: total, progress: eta.progress ?? Double(done) / Double(total),
                                        accessibilityLabel: L("Task list"),
                                        accessibilityValue: Format.stepOf(eta.step ?? done + 1, total))
        }
        guard model.phase == .working || model.phase == .countdown, session?.state != .waiting,
              let progress = model.sleepProgress else { return nil }
        return SegmentedProgressBar(progress: progress, accessibilityLabel: L("Progress to sleep"))
    }

    var body: some View {
        let value = self.value
        MetricRow(title: title, subtitle: subtitle, prominentTitle: true, titleHelp: summary?.pathHelp,
                  value: value?.text, valueSecondary: value?.secondary ?? false, valueCountsDown: value?.countsDown ?? false,
                  valueAccessibility: value?.spoken, valueCaption: value?.caption, bar: bar) {
            caption
        }
    }

    @ViewBuilder private var caption: some View {
        if model.phase == .countdown {
            HStack {
                Text(L("Going to sleep"))
                Spacer()
                Button(L("Cancel")) { model.cancelCountdown() }
                    .controlSize(.small)
                    .vigilButtonStyle()
            }
        } else if let session, session.state == .waiting, session.subagents.isEmpty {
            WaitingLine { model.openApp(for: session) }
        } else if let eta {
            if eta.fromHistory {
                Text(Format.estimateBasis(eta.historyCount ?? 0, eta.historyScope ?? .project))
                    .lineLimit(1).truncationMode(.tail)
            } else {
                Text(taskLine(eta)).lineLimit(1).truncationMode(.tail)
                    .help(eta.subject ?? "")
            }
        } else if let finished {
            Text(finished)
        }
    }

    /// "Dokončeno v 10:41 · trvalo 12 min" for an idle session or, without one, the last finished session.
    private var finished: String? {
        if let session, !session.isWorking, session.state != .waiting {
            let turn = model.turns.first { $0.project == session.projectName }
            let end = turn.map { $0.startedAt.addingTimeInterval($0.duration) }
            // The turn belongs to this idle period only when it ended about when the session went idle.
            let matching = end.map { abs($0.timeIntervalSince(session.stateSince)) < 300 } ?? false
            return Self.finishedLine(at: session.stateSince, took: matching ? turn?.duration : nil)
        }
        if let lastRecord {
            return Self.finishedLine(at: lastRecord.startedAt.addingTimeInterval(lastRecord.duration), took: lastRecord.duration)
        }
        return nil
    }

    private static func finishedLine(at date: Date, took: TimeInterval?) -> String {
        let done = L("Finished at %@", date.formatted(date: .omitted, time: .shortened))
        return took.map { done + " · " + L("took %@", Format.span($0)) } ?? done
    }

    /// "Hotovo asi v 9:59 (±4 min) · Krok 4: stránky sign-in / sign-up".
    private func taskLine(_ eta: SessionEta) -> String {
        var line = L("Done around %@ (%@)", eta.finishAt.formatted(date: .omitted, time: .shortened), eta.plusMinus)
        if let subject = eta.subject { line += " · " + L("Step %d: %@", eta.step ?? 1, subject) }
        return line
    }
}

/// Orange symbol, "Čeká na vaši odpověď", Open: the one orange thing on screen.
struct WaitingLine: View {
    let open: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(Theme.warning)
                .accessibilityHidden(true)
            Text(L("Waiting for your answer"))
            Spacer(minLength: 4)
            Button(L("Open"), action: open)
                .controlSize(.small)
                .vigilButtonStyle()
        }
    }
}

// MARK: - Other sessions

/// The other sessions, like the usage card's list: at most three rows, then "+N další". Clicking a working
/// session shows it in the primary row. Sessions waiting for an answer get the orange row with Open.
struct SessionList: View {
    let model: AppModel

    var body: some View {
        let primaryID = model.selectedSession?.id
        let waiting = model.waitingSessions.filter { $0.id != primaryID }
        let waitingIDs = Set(model.waitingSessions.map(\.id))
        let others = model.sessionSummaries.filter { $0.id != primaryID && !waitingIDs.contains($0.id) }
        if !waiting.isEmpty || !others.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(waiting.prefix(2)) { session in
                    SessionRow(leading: .symbol("exclamationmark.bubble.fill", Theme.warning),
                               title: ProjectName.display(session.projectName, cwd: session.cwd),
                               subtitle: L("Waiting for your answer"),
                               help: session.cwd.map { ($0 as NSString).abbreviatingWithTildeInPath }) {
                        Button(L("Open")) { model.openApp(for: session) }
                            .controlSize(.small)
                            .vigilButtonStyle()
                    }
                    .transition(.opacity)
                }
                ForEach(others.prefix(3)) { s in
                    row(s)
                }
                if others.count > 3 {
                    Text(L("+%d more", others.count - 3))
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.leading, 34)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ s: UsageCardSession) -> some View {
        let content = SessionRow(leading: .ring(s.contextPercent), title: s.project, subtitle: s.subtitle, help: s.pathHelp) {
            SessionStateValue(session: s)
        }
        if s.working {
            Button { model.selectedSessionID = s.id } label: { content }
                .buttonStyle(.plain)
                .accessibilityHint(L("Shows this session above"))
        } else {
            content
        }
    }
}

// MARK: - Status line

/// Lid, battery, temperature in one row. Secondary unless something is wrong.
struct StatusLine: View {
    let model: AppModel

    var body: some View {
        let env = model.environment
        HStack(spacing: 16) {
            StatusInline(symbol: env.lidClosed ? "laptopcomputer.slash" : "laptopcomputer",
                         text: env.lidClosed ? L("Lid closed") : L("Lid open"),
                         accessibility: env.lidClosed ? L("Lid closed") : L("Lid open"))
            let battery = batterySymbol(env)
            StatusInline(symbol: battery, text: env.batteryPercent.map { "\($0) %" } ?? "—",
                         trailingSymbol: env.isCharging && !battery.hasSuffix(".bolt") ? "bolt.fill" : nil,
                         tint: batteryTint(env), accessibility: batteryAccessibility(env))
            StatusInline(symbol: "thermometer.medium", text: thermalText(env.thermal), tint: thermalTint(env.thermal),
                         accessibility: L("Temperature: %@", thermalText(env.thermal)))
            Spacer(minLength: 0)
        }
    }

    private func batterySymbol(_ env: VigilCore.Environment) -> String {
        guard let pct = env.batteryPercent else { return "powerplug" }
        // The level decides the symbol; only the full one has a bolt variant, the others get a small bolt after the text.
        switch pct {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return env.isCharging ? "battery.100percent.bolt" : "battery.100percent"
        }
    }

    /// Orange when getting low on battery, red at or below the limit where Vigil stops.
    private func batteryTint(_ env: VigilCore.Environment) -> Color? {
        guard let pct = env.batteryPercent, env.onBattery, !env.isCharging else { return nil }
        let limit = model.settings.config.lowBatteryThreshold
        if limit > 0, pct <= limit { return Theme.critical }
        return pct <= max(20, limit) ? Theme.warning : nil
    }

    private func batteryAccessibility(_ env: VigilCore.Environment) -> String {
        guard let pct = env.batteryPercent else { return L("No battery") }
        let detail = env.isCharging ? L("Charging") : env.onBattery ? L("On battery") : L("Plugged in")
        return L("Battery %d percent, %@", pct, detail)
    }

    private func thermalText(_ level: ThermalLevel) -> String {
        switch level {
        case .nominal: return L("Normal")
        case .fair: return L("Elevated")
        case .serious, .critical: return L("High")
        }
    }

    private func thermalTint(_ level: ThermalLevel) -> Color? {
        switch level {
        case .nominal: return nil
        case .fair: return Theme.warning
        case .serious, .critical: return Theme.critical
        }
    }
}

// MARK: - Usage row

/// "Relace 5 % ▬▬░░░ · Týden 12 % ▬▬░░░ ›": the bars take the available width; the whole row opens the usage card.
struct UsageRow: View {
    let model: AppModel

    var body: some View {
        let stale = model.usage.freshness(at: model.now).isStale
        let five = model.usageWindow(.fiveHour)
        let week = model.usageWindow(.sevenDay)
        Button { model.showUsageCard() } label: {
            HStack(spacing: 16) {
                if let five { mini(L("Session"), five, stale: stale) }
                if let week { mini(L("Week"), week, stale: stale) }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(HoverRowButtonStyle())
        .help(L("Opens the usage card"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Claude usage"))
        .accessibilityValue([five.map { L("session %d percent", Int($0.usedPercentage.rounded())) },
                             week.map { L("week %d percent", Int($0.usedPercentage.rounded())) }]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(L("Opens the usage card"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.showUsageCard() }
    }

    private func mini(_ label: String, _ window: EffectiveWindow, stale: Bool) -> some View {
        let f = window.usedPercentage / 100
        return HStack(spacing: 6) {
            Text("\(label) \(Int(window.usedPercentage.rounded())) %")
                .font(.footnote).fontDesign(.rounded).monospacedDigit().foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            SegmentedProgressBar(progress: f, tint: SegmentedProgressBar.usageTint(f), dimmed: stale && !window.isReset)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
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

    /// Red for the critical states (battery, heat); the others are plain information.
    static func tint(_ reason: GuardReason) -> Color {
        switch reason {
        case .lowBattery, .thermal: return Theme.critical
        case .maxDuration, .manualSleep: return .secondary
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

/// Symbol, title and explanation in one flat row, with optional actions below.
struct NoticeRow<Actions: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    @ViewBuilder var actions: Actions
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).symbolRenderingMode(.hierarchical).foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                actions.controlSize(.small).padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Onboarding

struct SetupChecklist: View {
    let model: AppModel

    var body: some View {
        let s = model.setup
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: L("Setup")) {
                Text(Format.countOf(s.doneCount, 5)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    .numericTransition()
            }
            SegmentedProgressBar(segments: 5, progress: Double(s.doneCount) / 5, accessibilityLabel: L("Setup"),
                                 accessibilityValue: Format.countOf(s.doneCount, 5))

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
                    .font(.caption).foregroundStyle(.secondary)
            }

            Button { model.runSelfTest() } label: { Label(L("Run self-test"), systemImage: "checklist") }
                .controlSize(.small)
                .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func step(title: String, detail: String, done: Bool, action: String, busy: Bool,
                      perform: @escaping () -> Void) -> some View {
        if !done {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "circle.dashed").foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                BusyButton(title: action, busy: busy, prominent: true, action: perform)
                    .controlSize(.small)
            }
            .transition(.opacity)
        }
    }
}

// MARK: - Hints

/// Only when it matters: lid closed on battery.
struct BagHint: View {
    var body: some View {
        Label {
            Text(L("A closed laptop in a bag overheats. Keep it on a flat surface, ideally plugged in."))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "flame").symbolRenderingMode(.hierarchical)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

extension String {
    /// "Podle 14 podobných…" -> "podle 14 podobných…" (to continue a sentence after " · ").
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
