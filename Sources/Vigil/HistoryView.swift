import SwiftUI
import VigilCore

enum HistoryTab: Hashable { case sessions, accuracy }

/// Native tables; the tab picker and Clear live in the window toolbar.
struct HistoryView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            switch model.historyTab {
            case .sessions:
                if model.sleepDecisions.isEmpty {
                    SessionHistory(model: model)
                } else {
                    VSplitView {
                        SessionHistory(model: model).frame(minHeight: 160)
                        SleepDecisionHistory(decisions: model.sleepDecisions).frame(minHeight: 120)
                    }
                }
            case .accuracy:
                AccuracyHistory(turns: model.turns, now: model.now)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker(L("View"), selection: $model.historyTab) {
                    Text(L("Sessions")).tag(HistoryTab.sessions)
                    Text(L("Estimate accuracy")).tag(HistoryTab.accuracy)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            ToolbarItem(placement: .primaryAction) {
                if model.historyTab == .sessions {
                    Button { model.clearHistory() } label: { Label(L("Clear"), systemImage: "trash") }
                        .disabled(model.history.isEmpty)
                        .help(L("Clear"))
                }
            }
        }
    }
}

// MARK: - Sessions

private struct SessionHistory: View {
    let model: AppModel

    var body: some View {
        if model.history.isEmpty {
            ContentUnavailableView(L("No sessions yet"), systemImage: "clock.arrow.circlepath",
                                   description: Text(L("Finished sessions appear here.")))
        } else {
            Table(model.history) {
                TableColumn(L("Project")) { r in
                    Label {
                        Text(r.project).fontWeight(.medium).lineLimit(1)
                    } icon: {
                        Image(systemName: icon(r.reason)).symbolRenderingMode(.hierarchical)
                            .foregroundStyle(r.reason == .ended ? model.accent : .secondary)
                    }
                }
                .width(min: 110, ideal: 140)
                TableColumn(L("Started")) { r in
                    Text(r.startedAt, format: .dateTime.day().month().hour().minute()).foregroundStyle(.secondary).monospacedDigit()
                }
                .width(min: 90, ideal: 120)
                TableColumn(L("Duration")) { r in
                    Text(Format.clock(r.duration)).monospacedDigit()
                }
                .width(min: 60, ideal: 70)
                TableColumn(L("Subagents")) { r in
                    if r.maxSubagents > 0 {
                        Text(L("Up to %@ · %@ total", Format.subagents(r.maxSubagents), Format.clock(r.subagentTime)))
                            .foregroundStyle(.secondary).monospacedDigit()
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }
                .width(min: 90, ideal: 150)
                TableColumn(L("Result")) { r in
                    Text(label(r.reason)).foregroundStyle(.secondary)
                }
                .width(min: 70, ideal: 90)
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

/// How good the work-time estimate has been: a summary row and one table row per finished turn.
private struct AccuracyHistory: View {
    let turns: [TurnRecord]
    let now: Date

    var body: some View {
        let summary = EtaAccuracy.summary(turns, now: now)
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 24) {
                SummaryItem(title: L("Average error"), value: summary.meanError.map { "±" + Format.minutes($0) } ?? "—",
                            detail: Format.lastTurns(summary.scored))
                SummaryItem(title: L("Hits in range"),
                            value: summary.scored > 0 ? Format.countOf(summary.hits, summary.scored) : "—",
                            detail: L("actual inside the estimate"))
                SummaryItem(title: L("Trend"), value: trendTitle(summary.trend), detail: trendDetail(summary.trend))
                Spacer(minLength: 0)
            }
            .padding(16)
            Divider()
            if turns.isEmpty {
                ContentUnavailableView(L("No estimates yet"), systemImage: "gauge.with.dots.needle.33percent",
                                       description: Text(L("Estimates appear after the first finished turns.")))
            } else {
                Table(Array(turns.prefix(50))) {
                    TableColumn(L("When")) { t in Text(when(t.startedAt)).foregroundStyle(.secondary).monospacedDigit() }
                        .width(min: 50, ideal: 60)
                    TableColumn(L("Project")) { t in Text(t.project).fontWeight(.medium).lineLimit(1) }
                        .width(min: 90, ideal: 150)
                    TableColumn(L("Basis")) { t in Text(basis(EtaAccuracy.checkpoint(t))).foregroundStyle(.secondary) }
                        .width(min: 60, ideal: 70)
                    TableColumn(L("Estimate")) { t in
                        if let c = EtaAccuracy.checkpoint(t) {
                            Text(EtaFormat.range(c.low, c.high)).monospacedDigit()
                        } else {
                            Text(L("no estimate")).foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 70, ideal: 100)
                    TableColumn(L("Took")) { t in Text(Format.took(t.activeDuration)).monospacedDigit() }
                        .width(min: 50, ideal: 60)
                    TableColumn(L("Difference")) { t in difference(EtaAccuracy.verdict(t)) }
                        .width(min: 60, ideal: 80)
                }
            }
        }
    }

    @ViewBuilder
    private func difference(_ verdict: EtaAccuracy.Verdict) -> some View {
        switch verdict {
        case .hit:
            Label(L("hit"), systemImage: "checkmark.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.accent(.green))
        case .over(let d):
            Text("+" + Format.minutes(d)).monospacedDigit()
        case .under(let d):
            Text("−" + Format.minutes(d)).monospacedDigit()
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

/// Label, rounded value, detail: the accuracy summary without boxes.
private struct SummaryItem: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.title3.weight(.semibold)).fontDesign(.rounded).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Sleep decisions

/// Every forced sleep and every time Vigil let macOS decide instead, with the reason.
private struct SleepDecisionHistory: View {
    let decisions: [SleepDecisionRecord]

    var body: some View {
        Table(Array(decisions.prefix(30))) {
            TableColumn(L("Sleep decisions")) { d in
                Label(d.slept ? L("Vigil put the Mac to sleep") : L("Left sleep to macOS"),
                      systemImage: d.slept ? "moon.fill" : "arrow.uturn.backward.circle")
                    .symbolRenderingMode(.hierarchical)
                    .fontWeight(.medium)
            }
            .width(min: 140, ideal: 200)
            TableColumn(L("Reason")) { d in
                Text(SleepGateText.reason(d.reason) + " · " + trigger(d.trigger)).foregroundStyle(.secondary)
                    .help(SleepGateText.reason(d.reason) + " · " + trigger(d.trigger))
            }
            .width(min: 140, ideal: 260)
            TableColumn(L("When")) { d in
                Text(d.date, format: .dateTime.day().month().hour().minute()).foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 90, ideal: 110)
        }
    }

    private func trigger(_ t: SleepTrigger) -> String {
        switch t {
        case .finished: return L("after Claude finished")
        case .countdownExpired: return L("end of the countdown")
        case .countdownCancelled: return L("countdown cancelled")
        case .maxDuration: return L("maximum keep-awake time")
        case .lowBattery: return L("low battery")
        case .thermal: return L("Mac running hot")
        case .userRequested: return L("Sleep now")
        }
    }
}
