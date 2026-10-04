import SwiftUI
import VigilCore

struct SelfTestView: View {
    let model: AppModel

    private func title(_ id: CheckID) -> String {
        switch id {
        case .sudoers: return L("Sleep permission")
        case .hooks: return L("Claude Code hooks")
        case .socket: return L("Hook socket")
        case .roundTrip: return L("Hook round trip")
        case .subagents: return L("Subagent tracking")
        case .statusLine: return L("Status line")
        case .notifications: return L("Notifications")
        case .sleepGate: return L("Sleep gate")
        case .notch: return L("Edge notch")
        }
    }

    private func fixLabel(_ fix: FixAction) -> String {
        switch fix {
        case .installSudoers: return L("Install permission")
        case .installHooks: return L("Install hooks")
        case .updateHooks: return L("Update hooks")
        case .restartServer: return L("Restart listener")
        case .requestNotifications: return L("Allow notifications")
        case .installStatusLine: return L("Install status line")
        }
    }

    private func busy(_ fix: FixAction) -> Bool {
        switch fix {
        case .installSudoers: return model.busy.contains("sudoers")
        case .installHooks, .updateHooks: return model.busy.contains("hooks")
        case .installStatusLine: return model.busy.contains("statusLine")
        case .restartServer, .requestNotifications: return false
        }
    }

    var body: some View {
        let results = model.selfTestResults
        Form {
            Section {
                if model.selfTestRunning && results.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L("Running checks…")).foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(results) { r in
                        LabeledContent {
                            if let fix = r.fix {
                                BusyButton(title: fixLabel(fix), busy: busy(fix), prominent: true) { model.fix(fix) }
                            }
                        } label: {
                            Label {
                                Text(title(r.id))
                                Text(r.detail)
                            } icon: {
                                Image(systemName: r.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(r.passed ? model.accent : Theme.critical)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(r.passed ? L("Passed") : L("Failed"))
                    }
                }
            } header: {
                Text(L("Checks"))
            } footer: {
                if !results.isEmpty {
                    let passed = results.filter(\.passed).count
                    Text(passed == results.count ? L("All checks passed") : L("%d of %d checks passed", passed, results.count))
                }
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.runSelfTest() } label: { Label(L("Run again"), systemImage: "arrow.clockwise") }
                    .disabled(model.selfTestRunning)
                    .help(L("Run again"))
            }
        }
    }
}
