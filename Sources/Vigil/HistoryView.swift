import SwiftUI
import VigilCore

struct HistoryView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(text: L("Last %d sessions", 50))
                Spacer()
                if !model.history.isEmpty {
                    Button(L("Clear")) { model.clearHistory() }.buttonStyle(PillButtonStyle())
                }
            }
            Card(padding: 6) {
                if model.history.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(.tertiary)
                        Text(L("Finished sessions appear here.")).font(.system(size: 13)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(14)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.history.enumerated()), id: \.element.id) { index, record in
                            HStack(spacing: 12) {
                                Image(systemName: icon(record.reason))
                                    .font(.system(size: 15))
                                    .foregroundStyle(record.reason == .ended ? model.accent : .secondary)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(record.project).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                    Text(record.startedAt, format: .dateTime.day().month().hour().minute())
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                    if record.maxSubagents > 0 {
                                        Label(L("Up to %@ · %@ total", Format.subagents(record.maxSubagents), Format.clock(record.subagentTime)),
                                              systemImage: "arrow.triangle.branch")
                                            .font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
                                    }
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(Format.clock(record.duration)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                                    Text(label(record.reason)).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            if index < model.history.count - 1 { RowDivider().padding(.leading, 44) }
                        }
                    }
                }
            }
        }
    }

    private func label(_ r: SessionEndReason) -> String {
        switch r {
        case .ended: return L("Ended")
        case .interrupted: return L("Interrupted")
        case .timedOut: return L("Timed out")
        }
    }
    private func icon(_ r: SessionEndReason) -> String {
        switch r {
        case .ended: return "checkmark.circle.fill"
        case .interrupted: return "bolt.slash.fill"
        case .timedOut: return "hourglass"
        }
    }
}
