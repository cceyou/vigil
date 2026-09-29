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
        case .notifications: return L("Notifications")
        }
    }

    private func fixLabel(_ fix: FixAction) -> String {
        switch fix {
        case .installSudoers: return L("Install permission")
        case .installHooks: return L("Install hooks")
        case .updateHooks: return L("Update hooks")
        case .restartServer: return L("Restart listener")
        case .requestNotifications: return L("Allow notifications")
        }
    }

    var body: some View {
        HStack {
            Button { model.tab = .overview } label: { Label(L("Back"), systemImage: "chevron.left") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            Spacer()
            ActionButton(title: L("Run again"), busy: model.selfTestRunning) { model.runSelfTest() }
        }

        let results = model.selfTestResults
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: L("Self-test"))
            Card {
                if model.selfTestRunning && results.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(L("Running checks…")).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(results) { r in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: r.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundStyle(r.passed ? Color.green : Color.red)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(title(r.id)).font(.system(size: 13, weight: .medium))
                                    Text(r.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 6)
                                if let fix = r.fix {
                                    ActionButton(title: fixLabel(fix), busy: fix == .installSudoers && model.busy.contains("sudoers")
                                                 || (fix == .installHooks || fix == .updateHooks) && model.busy.contains("hooks"), prominent: true) {
                                        model.fix(fix)
                                    }
                                }
                            }
                        }
                        if !results.isEmpty {
                            Divider().opacity(0.5)
                            let passed = results.filter(\.passed).count
                            Label(passed == results.count ? L("All checks passed") : L("%d of %d checks passed", passed, results.count),
                                  systemImage: passed == results.count ? "party.popper.fill" : "exclamationmark.triangle.fill")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(passed == results.count ? Color.green : Color.orange)
                        }
                    }
                }
            }
        }
    }
}
