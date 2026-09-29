import SwiftUI
import VigilCore

struct HistoryView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle(text: L("Last %d sessions", 50))
                Spacer()
                if !model.history.isEmpty {
                    Button(L("Clear")) { model.clearHistory() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Card(padding: 4) {
                if model.history.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(.tertiary)
                        Text(L("Finished sessions appear here.")).font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(10)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.history.enumerated()), id: \.element.id) { index, record in
                            HStack(spacing: 10) {
                                Image(systemName: icon(record.reason)).foregroundStyle(tint(record.reason)).frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(record.project).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Text(record.startedAt, format: .dateTime.day().month().hour().minute())
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                    if record.maxSubagents > 0 {
                                        Label(L("Up to %@ · %@ total", Format.subagents(record.maxSubagents), Format.clock(record.subagentTime)),
                                              systemImage: "arrow.triangle.branch")
                                            .font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
                                    }
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text(Format.clock(record.duration)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                                    Text(label(record.reason)).font(.system(size: 11)).foregroundStyle(tint(record.reason))
                                }
                            }
                            .padding(10)
                            if index < model.history.count - 1 { Divider().opacity(0.5) }
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
    private func tint(_ r: SessionEndReason) -> Color {
        switch r {
        case .ended: return .green
        case .interrupted: return .orange
        case .timedOut: return .red
        }
    }
}
