import SwiftUI
import VigilCore

struct SettingsView: View {
    @Bindable var model: AppModel

    private func config<T>(_ keyPath: WritableKeyPath<Config, T>) -> Binding<T> {
        Binding(get: { model.settings.config[keyPath: keyPath] },
                set: { v in model.update { $0.config[keyPath: keyPath] = v } })
    }

    private func ui<T>(_ keyPath: WritableKeyPath<UISettings, T>) -> Binding<T> {
        Binding(get: { model.settings.ui[keyPath: keyPath] },
                set: { v in model.update { $0.ui[keyPath: keyPath] = v } })
    }

    var body: some View {
        let accent = model.accent
        group(L("General")) {
            SettingRow(title: L("Watch Claude Code"), subtitle: L("Keep the Mac awake while Claude works, then sleep it.")) {
                Toggle("", isOn: Binding(get: { model.enabled }, set: { v in withAnimation(.smooth) { model.setEnabled(v) } }))
                    .labelsHidden().toggleStyle(.switch)
            }
            RowDivider()
            SettingRow(title: L("Launch at login")) {
                Toggle("", isOn: Binding(get: { model.setup.loginItem }, set: { model.setLaunchAtLogin($0) }))
                    .labelsHidden().toggleStyle(.switch)
            }
            RowDivider()
            SettingRow(title: L("Grace period"), subtitle: L("Wait this long after Claude finishes before sleeping.")) {
                Picker("", selection: config(\.graceSeconds)) {
                    ForEach([10.0, 30, 60, 120, 300], id: \.self) { Text(Durations.short($0)).tag($0) }
                }.labelsHidden().frame(width: 84)
            }
            RowDivider()
            SettingRow(title: L("Maximum keep-awake time"), subtitle: L("Failsafe: restore normal sleep and sleep after this long.")) {
                Picker("", selection: config(\.maxKeepAwake)) {
                    ForEach([1.0, 2, 4, 8, 12, 24].map { $0 * 3600 }, id: \.self) { Text(Durations.short($0)).tag($0) }
                }.labelsHidden().frame(width: 84)
            }
            RowDivider()
            SettingRow(title: L("Stuck subagent limit"), subtitle: L("A subagent that never reports back is dropped after this long.")) {
                Picker("", selection: config(\.stuckSubagentLimit)) {
                    ForEach([0.5, 1, 2, 4].map { $0 * 3600 }, id: \.self) { Text(Durations.short($0)).tag($0) }
                }.labelsHidden().frame(width: 84)
            }
            RowDivider()
            SettingRow(title: L("Low battery threshold"), subtitle: L("On battery below this level Vigil stops keeping the Mac awake, and sleeps it if the lid is closed.")) {
                Picker("", selection: config(\.lowBatteryThreshold)) {
                    Text(L("Off")).tag(0)
                    ForEach([3, 5, 10, 15, 20, 30], id: \.self) { Text("\($0) %").tag($0) }
                }.labelsHidden().frame(width: 84)
            }
            RowDivider()
            SettingRow(title: L("Only sleep if the lid is closed"), subtitle: L("With the lid open, Vigil restores normal sleep but does not force it.")) {
                Toggle("", isOn: config(\.sleepOnlyIfLidClosed)).labelsHidden().toggleStyle(.switch)
            }
            RowDivider()
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("When Claude is waiting for me")).font(.system(size: 13, weight: .medium))
                    Text(L("A permission prompt or question from Claude Code.")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Picker("", selection: config(\.notificationPolicy)) {
                    Text(L("Start sleep countdown")).tag(NotificationPolicy.treatAsIdle)
                    Text(L("Keep awake")).tag(NotificationPolicy.keepAwake)
                }
                .labelsHidden().pickerStyle(.segmented)
            }
        }

        group(L("Look")) {
            SettingRow(title: L("Accent color")) {
                HStack(spacing: 10) {
                    ForEach(AccentChoice.allCases, id: \.self) { choice in
                        Button { model.update { $0.ui.accent = choice } } label: {
                            Circle().fill(Theme.accent(choice))
                                .frame(width: 20, height: 20)
                                .overlay(Circle().strokeBorder(.white, lineWidth: model.settings.ui.accent == choice ? 2 : 0))
                                .padding(2)
                        }
                        .buttonStyle(.plain)
                        .help(accentName(choice))
                    }
                }
            }
        }

        group(L("Edge notch and usage")) {
            SettingRow(title: L("Notch at the screen edge"), subtitle: L("Hover it to see your Claude usage.")) {
                Toggle("", isOn: ui(\.notchEnabled)).labelsHidden().toggleStyle(.switch)
            }
            RowDivider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L("Position on the edge")).font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("\(Int((model.settings.ui.notchPosition * 100).rounded())) %")
                        .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: ui(\.notchPosition), in: 0.2...0.8)
                    .controlSize(.small)
                    .disabled(!model.settings.ui.notchEnabled)
            }
            RowDivider()
            SettingRow(title: L("Displays")) {
                Picker("", selection: ui(\.notchDisplays)) {
                    Text(L("All displays")).tag(NotchDisplays.all)
                    Text(L("Main display only")).tag(NotchDisplays.main)
                }.labelsHidden().frame(width: 150)
            }
            RowDivider()
            SettingRow(title: L("Hover delay"), subtitle: L("How long the pointer rests on the notch before the card opens.")) {
                Picker("", selection: ui(\.hoverDelay)) {
                    ForEach([0.1, 0.18, 0.3, 0.5, 0.8], id: \.self) { Text("\(Int($0 * 1000)) ms").tag($0) }
                }.labelsHidden().frame(width: 96)
            }
            RowDivider()
            SettingRow(title: L("Hide in full-screen apps")) {
                Toggle("", isOn: ui(\.hideInFullScreen)).labelsHidden().toggleStyle(.switch)
            }
            RowDivider()
            SettingRow(title: L("Keyboard shortcut"), subtitle: L("Shows or hides the usage card from anywhere.")) {
                HStack(spacing: 8) {
                    let recorder = ShortcutRecorder.shared
                    let spec = model.settings.ui.shortcut
                    Button(recorder.isRecording ? L("Press keys…") : KeyNames.describe(keyCode: spec.keyCode, modifiers: spec.modifiers)) {
                        if recorder.isRecording { recorder.stop() } else {
                            recorder.start { code, mods in
                                model.update { $0.ui.shortcut = HotKeySpec(enabled: true, keyCode: code, modifiers: mods) }
                            }
                        }
                    }
                    .buttonStyle(PillButtonStyle(fill: recorder.isRecording ? accent : Theme.track,
                                                 foreground: recorder.isRecording ? .black : .primary))
                    .disabled(!spec.enabled)
                    Toggle("", isOn: ui(\.shortcut.enabled)).labelsHidden().toggleStyle(.switch)
                }
            }
            RowDivider()
            SettingRow(title: L("Usage notifications"), subtitle: L("At 80 % and 95 % of the session limit, 80 % of the weekly limit, and when a limit resets.")) {
                Toggle("", isOn: ui(\.usageNotifications)).labelsHidden().toggleStyle(.switch)
            }
            RowDivider()
            SettingRow(title: L("Status line"),
                       subtitle: model.setup.statusLine ? L("Installed. Your previous status line (if any) still runs and is restored on removal.")
                                                        : L("Needed for Claude usage. Your current status line keeps working.")) {
                if model.setup.statusLine {
                    ActionButton(title: L("Remove"), busy: model.busy.contains("statusLine")) { model.removeStatusLine() }
                } else {
                    ActionButton(title: L("Install"), busy: model.busy.contains("statusLine"), prominent: true, accent: accent) { model.installStatusLine() }
                }
            }
        }

        group(L("Permissions and hooks")) {
            SettingRow(title: L("Sleep permission"),
                       subtitle: model.setup.sudoers ? L("Installed in /etc/sudoers.d/vigil") : L("Not installed")) {
                if model.setup.sudoers {
                    ActionButton(title: L("Remove"), busy: model.busy.contains("sudoers")) { model.removeSudoers() }
                } else {
                    ActionButton(title: L("Install"), busy: model.busy.contains("sudoers"), prominent: true, accent: accent) { model.installSudoers() }
                }
            }
            RowDivider()
            SettingRow(title: L("Claude Code hooks"),
                       subtitle: model.setup.hooks ? L("Present in ~/.claude/settings.json")
                           : model.setup.hooksOutdated ? L("Out of date: the subagent hooks are missing") : L("Not installed")) {
                if model.setup.hooks {
                    ActionButton(title: L("Remove hooks"), busy: model.busy.contains("hooks")) { model.removeHooks() }
                } else if model.setup.hooksOutdated {
                    ActionButton(title: L("Update hooks"), busy: model.busy.contains("hooks"), prominent: true, accent: accent) { model.updateHooks() }
                } else {
                    ActionButton(title: L("Install"), busy: model.busy.contains("hooks"), prominent: true, accent: accent) { model.installHooks() }
                }
            }
            Text(L("Already-running Claude Code sessions must be restarted to load new hooks."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }

        group(L("Diagnostics")) {
            SettingRow(title: L("Self-test"), subtitle: L("Checks permission, hooks, socket, fake hook, subagent and status line events, and notifications.")) {
                ActionButton(title: L("Run self-test"), busy: model.selfTestRunning) { model.runSelfTest() }
            }
            RowDivider()
            SettingRow(title: L("Dry run"), subtitle: L("Goes through the whole flow but only logs; never calls pmset.")) {
                Toggle("", isOn: Binding(get: { model.settings.dryRun }, set: { v in model.update { $0.dryRun = v } }))
                    .labelsHidden().toggleStyle(.switch)
            }
            if model.settings.dryRun {
                HStack {
                    ActionButton(title: L("Simulate a session")) { model.simulateSession() }
                    Spacer()
                }
                if !model.dryRunLog.isEmpty {
                    Text(model.dryRunLog.joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            RowDivider()
            SettingRow(title: L("Log")) {
                ActionButton(title: L("Open log")) { model.openLog() }
            }
        }

        HStack {
            Text("Vigil \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
            Spacer()
            Button(L("Quit Vigil")) { model.quit() }.buttonStyle(PillButtonStyle())
        }
        .padding(.horizontal, 6)
    }

    private func accentName(_ c: AccentChoice) -> String {
        switch c {
        case .green: return L("Green")
        case .blue: return L("Blue")
        case .orange: return L("Orange")
        case .purple: return L("Purple")
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: title)
            Card { VStack(alignment: .leading, spacing: 12) { content() } }
        }
    }
}
