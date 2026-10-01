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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(text: L("Checks"))
                Spacer()
                ActionButton(title: L("Run again"), busy: model.selfTestRunning, accent: model.accent) { model.runSelfTest() }
            }
            Card {
                if model.selfTestRunning && results.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(L("Running checks…")).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(results) { r in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: r.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundStyle(r.passed ? model.accent : Color.white)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(title(r.id)).font(.system(size: 13, weight: .semibold))
                                    Text(r.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 6)
                                if let fix = r.fix {
                                    ActionButton(title: fixLabel(fix), busy: busy(fix), prominent: true, accent: model.accent) { model.fix(fix) }
                                }
                            }
                        }
                        if !results.isEmpty {
                            RowDivider()
                            let passed = results.filter(\.passed).count
                            Label(passed == results.count ? L("All checks passed") : L("%d of %d checks passed", passed, results.count),
                                  systemImage: passed == results.count ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(passed == results.count ? model.accent : Color.white)
                        }
                    }
                }
            }
        }
    }
}
