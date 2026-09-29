import SwiftUI
import VigilCore

enum HistoryTab: Hashable { case sessions, accuracy }

struct HistoryView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $model.historyTab) {
                Text(L("Sessions")).tag(HistoryTab.sessions)
                Text(L("Estimate accuracy")).tag(HistoryTab.accuracy)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity)

            switch model.historyTab {
            case .sessions: SessionHistory(model: model)
            case .accuracy: AccuracyHistory(turns: model.turns, now: model.now, accent: model.accent)
            }
        }
    }
}

private struct SessionHistory: View {
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

// MARK: - Estimate accuracy

/// How good the work-time estimate has been: three summary tiles and one row per finished turn.
private struct AccuracyHistory: View {
    let turns: [TurnRecord]
    let now: Date
    let accent: Color

    static let hitGreen = Color(hex: 0x30D158)

    var body: some View {
        let summary = EtaAccuracy.summary(turns, now: now)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                SummaryTile(title: L("Average error"),
                            value: summary.meanError.map { "±" + Format.minutes($0) } ?? "—",
                            detail: Format.lastTurns(summary.scored))
                SummaryTile(title: L("Hits in range"),
                            value: summary.scored > 0 ? Format.countOf(summary.hits, summary.scored) : "—",
                            detail: L("actual inside the estimate"))
                SummaryTile(title: L("Trend"), value: trendTitle(summary.trend), detail: trendDetail(summary.trend))
            }
            if turns.isEmpty {
                Card(padding: 14) {
                    HStack(spacing: 10) {
                        Image(systemName: "gauge.with.dots.needle.33percent").foregroundStyle(.tertiary)
                        Text(L("Estimates appear after the first finished turns.")).font(.system(size: 13)).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            } else {
                table
            }
        }
    }

    private var table: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 0) {
            GridRow {
                header(L("When"))
                header(L("Project"))
                header(L("Basis"))
                header(L("Estimate")).gridColumnAlignment(.trailing)
                header(L("Took")).gridColumnAlignment(.trailing)
                header(L("Difference")).gridColumnAlignment(.trailing)
            }
            .padding(.bottom, 8)
            ForEach(turns.prefix(50)) { turn in
                Divider().gridCellUnsizedAxes(.horizontal).overlay(Theme.outline)
                row(turn).padding(.vertical, 9)
            }
        }
        .padding(.horizontal, 6)
    }

    private func header(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private func row(_ turn: TurnRecord) -> some View {
        let checkpoint = EtaAccuracy.checkpoint(turn)
        GridRow {
            Text(when(turn.startedAt)).foregroundStyle(.secondary).monospacedDigit()
            Text(turn.project).fontWeight(.medium).lineLimit(1).truncationMode(.tail)
            Text(basis(checkpoint)).foregroundStyle(.secondary).lineLimit(1)
            Group {
                if let c = checkpoint {
                    Text(EtaFormat.range(c.low, c.high))
                } else {
                    Text(L("no estimate")).foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
            Text(Format.took(turn.activeDuration)).monospacedDigit()
            difference(EtaAccuracy.verdict(turn))
        }
        .font(.system(size: 13))
    }

    @ViewBuilder
    private func difference(_ verdict: EtaAccuracy.Verdict) -> some View {
        switch verdict {
        case .hit:
            Label(L("hit"), systemImage: "checkmark").labelStyle(TightLabel()).foregroundStyle(Self.hitGreen)
        case .over(let d):
            Text("+" + Format.minutes(d)).foregroundStyle(Theme.waiting).monospacedDigit()
        case .under(let d):
            Text("−" + Format.minutes(d)).foregroundStyle(Theme.waiting).monospacedDigit()
        case .noEstimate:
            Text("—").foregroundStyle(.secondary)
        }
    }

    private func when(_ date: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.day().month(.defaultDigits))
    }

    private func basis(_ c: EtaCheckpoint?) -> String {
        guard let c else { return "—" }
        if let n = c.tasksTotal { return L("tasks %d", n) }
        return L("history")
    }

    private func trendTitle(_ t: EtaAccuracy.Trend) -> String {
        switch t {
        case .improving: return L("Getting more accurate")
        case .worsening: return L("Getting less accurate")
        case .steady: return L("No change")
        case .notEnoughData: return L("Not enough data")
        }
    }

    private func trendDetail(_ t: EtaAccuracy.Trend) -> String {
        switch t {
        case .improving(let p), .worsening(let p), .steady(let p): return L("last week ±%@", Format.minutes(p))
        case .notEnoughData: return L("needs two weeks of estimates")
        }
    }
}

private struct SummaryTile: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.system(size: 20, weight: .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Icon and title close together ("✓ trefa").
private struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 11, weight: .bold))
            configuration.title
        }
    }
}
