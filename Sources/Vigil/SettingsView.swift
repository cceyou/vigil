import AppKit
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
        let setup = model.setup
        Form {
            Section {
                Toggle(isOn: Binding(get: { model.enabled }, set: { v in withAnimation(.smooth) { model.setEnabled(v) } })) {
                    Text(L("Watch Claude Code"))
                    Text(L("Keep the Mac awake while Claude works, then sleep it."))
                }
                Toggle(L("Launch at login"), isOn: Binding(get: { setup.loginItem }, set: { model.setLaunchAtLogin($0) }))
                Picker(selection: config(\.graceSeconds)) {
                    ForEach([10.0, 30, 60, 120, 300], id: \.self) { Text(Durations.short($0)).tag($0) }
                } label: {
                    Text(L("Grace period"))
                    Text(L("Wait this long after Claude finishes before sleeping."))
                }
                Picker(selection: config(\.maxKeepAwake)) {
                    ForEach([1.0, 2, 4, 8, 12, 24].map { $0 * 3600 }, id: \.self) { Text(Durations.short($0)).tag($0) }
                } label: {
                    Text(L("Maximum keep-awake time"))
                    Text(L("Failsafe: restore normal sleep and sleep after this long."))
                }
                Picker(selection: config(\.stuckSubagentLimit)) {
                    ForEach([0.5, 1, 2, 4].map { $0 * 3600 }, id: \.self) { Text(Durations.short($0)).tag($0) }
                } label: {
                    Text(L("Stuck subagent limit"))
                    Text(L("A subagent that never reports back is dropped after this long."))
                }
            } header: {
                Text(L("General"))
            }

            Section {
                Picker(selection: config(\.lowBatteryThreshold)) {
                    Text(L("Off")).tag(0)
                    ForEach([3, 5, 10, 15, 20, 30], id: \.self) { Text("\($0) %").tag($0) }
                } label: {
                    Text(L("Low battery threshold"))
                    Text(L("On battery below this level Vigil stops keeping the Mac awake, and sleeps it if the lid is closed."))
                }
                Picker(selection: config(\.lidOpenIdleSleep)) {
                    Text(L("Never")).tag(0.0)
                    ForEach([5.0, 10, 20], id: \.self) { Text("\(Int($0)) min").tag($0 * 60) }
                } label: {
                    Text(L("Sleep with the lid open after inactivity"))
                    Text(L("Vigil only forces sleep when you are away: lid closed without an external display. With the lid open it hands sleep back to macOS, unless there has been no keyboard, mouse or trackpad input for this long."))
                }
            } header: {
                Text(L("Sleep"))
            } footer: {
                Text(L("Vigil never keeps a hot Mac or an almost empty battery awake.")).frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Picker(selection: config(\.notificationPolicy)) {
                    Text(L("Keep awake")).tag(NotificationPolicy.keepAwake)
                    Text(L("Sleep after a delay")).tag(NotificationPolicy.treatAsIdle)
                } label: {
                    Text(L("When Claude is waiting for an answer"))
                    Text(L("A permission prompt or a question from Claude Code. Keep the Mac awake to answer from your phone with Remote Control."))
                }
                Picker(selection: config(\.maxWaiting)) {
                    ForEach([0.5, 1, 2, 4, 8].map { $0 * 3600 }, id: \.self) { Text(Durations.short($0)).tag($0) }
                } label: {
                    Text(L("Maximum wait for an answer"))
                    Text(L("Then Vigil notifies you and starts the sleep countdown."))
                }
                .disabled(model.settings.config.notificationPolicy != .keepAwake)
            } header: {
                Text(L("Waiting for you"))
            }

            Section {
                Picker(selection: ui(\.islandContent)) {
                    Text(L("Elapsed time")).tag(IslandContent.elapsed)
                    Text(L("Estimate")).tag(IslandContent.estimate)
                } label: {
                    Text(L("The island shows while Claude works"))
                }
                Toggle(isOn: ui(\.etaNotification)) {
                    Text(L("Notify when Claude is almost done"))
                    Text(L("Once per task, only when the estimate is reasonably confident."))
                }
                LabeledContent {
                    Button(L("Clear estimate history")) { model.clearEtaHistory() }
                        .disabled(model.turns.isEmpty)
                } label: {
                    Text(L("Estimate history"))
                    Text(L("Finished tasks the estimate learns from: %d.", model.turns.count))
                }
            } header: {
                Text(L("Work-time estimate"))
            } footer: {
                Text(L("The estimate is a range with a confidence level. It never affects sleep.")).frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Picker(L("Accent color"), selection: ui(\.accent)) {
                    ForEach(AccentChoice.allCases, id: \.self) { choice in
                        Label { Text(accentName(choice)) } icon: { Image(nsImage: Self.swatch(Theme.accent(choice))) }
                            .tag(choice)
                    }
                }
            } header: {
                Text(L("Look"))
            } footer: {
                Text(L("The accent only marks that Vigil is active. Warnings stay orange and red.")).frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Toggle(isOn: ui(\.notchEnabled)) {
                    Text(L("Notch at the screen edge"))
                    Text(L("Hover it to see your Claude usage."))
                }
                LabeledContent {
                    Slider(value: ui(\.notchPosition), in: 0.2...0.8)
                        .frame(width: 160)
                        .accessibilityValue("\(Int((model.settings.ui.notchPosition * 100).rounded())) %")
                } label: {
                    Text(L("Position on the edge"))
                    Text("\(Int((model.settings.ui.notchPosition * 100).rounded())) %").monospacedDigit()
                }
                .disabled(!model.settings.ui.notchEnabled)
                Picker(L("Displays"), selection: ui(\.notchDisplays)) {
                    Text(L("All displays")).tag(NotchDisplays.all)
                    Text(L("Main display only")).tag(NotchDisplays.main)
                }
                Picker(selection: ui(\.hoverDelay)) {
                    ForEach([0.1, 0.18, 0.3, 0.5, 0.8], id: \.self) { Text("\(Int($0 * 1000)) ms").tag($0) }
                } label: {
                    Text(L("Hover delay"))
                    Text(L("How long the pointer rests on the notch before the card opens."))
                }
                Toggle(L("Hide in full-screen apps"), isOn: ui(\.hideInFullScreen))
                LabeledContent {
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
                        .buttonStyle(.bordered)
                        .disabled(!spec.enabled)
                        Toggle(L("Keyboard shortcut"), isOn: ui(\.shortcut.enabled)).labelsHidden().toggleStyle(.switch)
                    }
                } label: {
                    Text(L("Keyboard shortcut"))
                    Text(L("Shows or hides the usage card from anywhere."))
                }
                Toggle(isOn: ui(\.usageNotifications)) {
                    Text(L("Usage notifications"))
                    Text(L("At 80 % and 95 % of the session limit, 80 % of the weekly limit, and when a limit resets."))
                }
                LabeledContent {
                    if setup.statusLine {
                        BusyButton(title: L("Remove"), busy: model.busy.contains("statusLine")) { model.removeStatusLine() }
                    } else {
                        BusyButton(title: L("Install"), busy: model.busy.contains("statusLine"), prominent: true) { model.installStatusLine() }
                    }
                } label: {
                    Text(L("Status line"))
                    Text(setup.statusLine ? L("Installed. Your previous status line (if any) still runs and is restored on removal.")
                                          : L("Needed for Claude usage. Your current status line keeps working."))
                }
            } header: {
                Text(L("Edge notch and usage"))
            }

            Section {
                LabeledContent {
                    if setup.sudoers {
                        BusyButton(title: L("Remove"), busy: model.busy.contains("sudoers")) { model.removeSudoers() }
                    } else {
                        BusyButton(title: L("Install"), busy: model.busy.contains("sudoers"), prominent: true) { model.installSudoers() }
                    }
                } label: {
                    Text(L("Sleep permission"))
                    Text(setup.sudoers ? L("Installed in /etc/sudoers.d/vigil") : L("Not installed"))
                }
                LabeledContent {
                    if setup.hooks {
                        BusyButton(title: L("Remove hooks"), busy: model.busy.contains("hooks")) { model.removeHooks() }
                    } else if setup.hooksOutdated {
                        BusyButton(title: L("Update hooks"), busy: model.busy.contains("hooks"), prominent: true) { model.updateHooks() }
                    } else {
                        BusyButton(title: L("Install"), busy: model.busy.contains("hooks"), prominent: true) { model.installHooks() }
                    }
                } label: {
                    Text(L("Claude Code hooks"))
                    Text(setup.hooks ? L("Present in ~/.claude/settings.json")
                         : setup.hooksOutdated ? L("Out of date: newer hooks are available") : L("Not installed"))
                }
            } header: {
                Text(L("Permissions and hooks"))
            } footer: {
                Text(L("Already-running Claude Code sessions must be restarted to load new hooks.")).frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                LabeledContent {
                    BusyButton(title: L("Run self-test"), busy: model.selfTestRunning) { model.runSelfTest() }
                } label: {
                    Text(L("Self-test"))
                    Text(L("Checks permission, hooks, socket, fake hook, subagent and status line events, and notifications."))
                }
                Toggle(isOn: Binding(get: { model.settings.dryRun }, set: { v in model.update { $0.dryRun = v } })) {
                    Text(L("Dry run"))
                    Text(L("Goes through the whole flow but only logs; never calls pmset."))
                }
                if model.settings.dryRun {
                    Button(L("Simulate a session")) { model.simulateSession() }
                    if !model.dryRunLog.isEmpty {
                        Text(model.dryRunLog.joined(separator: "\n"))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                LabeledContent(L("Log")) {
                    Button(L("Open log")) { model.openLog() }
                }
            } header: {
                Text(L("Diagnostics"))
            }

            Section {
                LabeledContent(L("Version"), value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                Button(L("Quit Vigil")) { model.quit() }
            }
        }
        .formStyle(.grouped)
    }

    private func accentName(_ c: AccentChoice) -> String {
        switch c {
        case .green: return L("Green")
        case .blue: return L("Blue")
        case .orange: return L("Orange")
        case .purple: return L("Purple")
        }
    }

    /// A small colored dot for the accent menu (menus draw SwiftUI symbols as templates, so this is a bitmap).
    private static func swatch(_ color: Color) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(color).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
