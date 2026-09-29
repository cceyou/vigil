import SwiftUI
import VigilCore

struct SettingsView: View {
    @Bindable var model: AppModel

    private func config<T>(_ keyPath: WritableKeyPath<Config, T>) -> Binding<T> {
        Binding(get: { model.settings.config[keyPath: keyPath] },
                set: { v in model.update { $0.config[keyPath: keyPath] = v } })
    }

    var body: some View {
        group(L("General")) {
            SettingRow(title: L("Launch at login")) {
                Toggle("", isOn: Binding(get: { model.setup.loginItem }, set: { model.setLaunchAtLogin($0) }))
                    .labelsHidden().toggleStyle(.switch)
            }
            Divider().opacity(0.5)
            SettingRow(title: L("Grace period"), subtitle: L("Wait this long after Claude finishes before sleeping.")) {
                Picker("", selection: config(\.graceSeconds)) {
                    ForEach([10.0, 30, 60, 120, 300], id: \.self) { Text(Durations.short($0)).tag($0) }
                }.labelsHidden().frame(width: 84)
            }
            Divider().opacity(0.5)
            SettingRow(title: L("Maximum keep-awake time"), subtitle: L("Failsafe: restore normal sleep and sleep after this long.")) {
                Picker("", selection: config(\.maxKeepAwake)) {
                    ForEach([1.0, 2, 4, 8, 12, 24].map { $0 * 3600 }, id: \.self) { Text(Durations.short($0)).tag($0) }
                }.labelsHidden().frame(width: 84)
            }
            Divider().opacity(0.5)
            SettingRow(title: L("Stuck subagent limit"), subtitle: L("A subagent that never reports back is dropped after this long.")) {
                Picker("", selection: config(\.stuckSubagentLimit)) {
                    ForEach([0.5, 1, 2, 4].map { $0 * 3600 }, id: \.self) { Text(Durations.short($0)).tag($0) }
                }.labelsHidden().frame(width: 84)
            }
            Divider().opacity(0.5)
            SettingRow(title: L("Low battery threshold"), subtitle: L("On battery below this level Vigil stops keeping the Mac awake, and sleeps it if the lid is closed.")) {
                Picker("", selection: config(\.lowBatteryThreshold)) {
                    Text(L("Off")).tag(0)
                    ForEach([3, 5, 10, 15, 20, 30], id: \.self) { Text("\($0) %").tag($0) }
                }.labelsHidden().frame(width: 84)
            }
            Divider().opacity(0.5)
            SettingRow(title: L("Only sleep if the lid is closed"), subtitle: L("With the lid open, Vigil restores normal sleep but does not force it.")) {
                Toggle("", isOn: config(\.sleepOnlyIfLidClosed)).labelsHidden().toggleStyle(.switch)
            }
            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("When Claude is waiting for me")).font(.system(size: 13))
                    Text(L("A permission prompt or question from Claude Code.")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Picker("", selection: config(\.notificationPolicy)) {
                    Text(L("Start sleep countdown")).tag(NotificationPolicy.treatAsIdle)
                    Text(L("Keep awake")).tag(NotificationPolicy.keepAwake)
                }
                .labelsHidden().pickerStyle(.segmented)
            }
        }

        group(L("Permissions and hooks")) {
            SettingRow(title: L("Sleep permission"),
                       subtitle: model.setup.sudoers ? L("Installed in /etc/sudoers.d/vigil") : L("Not installed")) {
                if model.setup.sudoers {
                    ActionButton(title: L("Remove"), busy: model.busy.contains("sudoers")) { model.removeSudoers() }
                } else {
                    ActionButton(title: L("Install"), busy: model.busy.contains("sudoers"), prominent: true) { model.installSudoers() }
                }
            }
            Divider().opacity(0.5)
            SettingRow(title: L("Claude Code hooks"),
                       subtitle: model.setup.hooks ? L("Present in ~/.claude/settings.json")
                           : model.setup.hooksOutdated ? L("Out of date: the subagent hooks are missing") : L("Not installed")) {
                if model.setup.hooks {
                    ActionButton(title: L("Remove hooks"), busy: model.busy.contains("hooks")) { model.removeHooks() }
                } else if model.setup.hooksOutdated {
                    ActionButton(title: L("Update hooks"), busy: model.busy.contains("hooks"), prominent: true) { model.updateHooks() }
                } else {
                    ActionButton(title: L("Install"), busy: model.busy.contains("hooks"), prominent: true) { model.installHooks() }
                }
            }
            Text(L("Already-running Claude Code sessions must be restarted to load new hooks."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }

        group(L("Diagnostics")) {
            SettingRow(title: L("Self-test"), subtitle: L("Checks permission, hooks, socket, fake hook and subagent events, and notifications.")) {
                ActionButton(title: L("Run self-test"), busy: model.selfTestRunning) { model.runSelfTest() }
            }
            Divider().opacity(0.5)
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
            Divider().opacity(0.5)
            SettingRow(title: L("Log")) {
                ActionButton(title: L("Open log")) { model.openLog() }
            }
        }

        HStack {
            Text("Vigil \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
            Spacer()
            Button(L("Quit Vigil")) { model.quit() }.buttonStyle(SoftButtonStyle(tint: Mood.paused.tint)).frame(width: 110)
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: title)
            Card { VStack(alignment: .leading, spacing: 10) { content() } }
        }
    }
}
