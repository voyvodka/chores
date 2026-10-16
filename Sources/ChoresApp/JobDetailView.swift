import AppKit
import ChoresKit
import SwiftUI

struct JobDetailView: View {
    let job: JobSnapshot
    let store: JobStore
    /// `nil` in snapshots, where actions are not rendered.
    var model: JobsModel?

    /// Rows picked in the history table; Shift and Cmd extend it. Empty means the newest run.
    @State private var selection: Set<String> = []
    @State private var pendingDelete: Set<String>?
    @AppStorage(AppSettings.detailTab) private var tab: DetailTab = .history

    private var recentRuns: [RunRecord] { Array(job.runs.suffix(100).reversed()) }
    private var selectedRun: RunRecord? {
        recentRuns.first { selection.contains($0.id) } ?? recentRuns.first
    }

    private var tableSelection: Binding<Set<String>> {
        Binding(get: { selection.isEmpty ? Set(recentRuns.prefix(1).map(\.id)) : selection },
                set: { selection = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                if let error = job.definitionError {
                    Label("job.json is invalid: \(error)", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                if let error = job.schedulingError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                Label(scheduleLine, systemImage: "calendar")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                StatTiles(job: job)
                if let definition = job.definition, !definition.summary.isEmpty {
                    Text(definition.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(20)

            Picker("", selection: $tab) {
                Text("History").tag(DetailTab.history)
                Text("Info").tag(DetailTab.info)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .pointerStyle(.link)
            .padding(.horizontal, 20)
            .padding(.bottom, 10)

            // Same History / Info split as the menu page. An `.inspector` was tried and dropped: in
            // this split view it sends AppKit into an endless constraint-update loop and crashes.
            if tab == .info {
                ScrollView {
                    JobInfoView(job: job, store: store)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                }
            } else if recentRuns.isEmpty {
                ContentUnavailableView("No Runs Yet", systemImage: "clock",
                                       description: Text("History, report and log appear here after the first run."))
            } else {
                VSplitView {
                    historyTable
                        .frame(minHeight: 120, idealHeight: 200)
                    RunOutputView(job: job, run: selectedRun, store: store)
                        .frame(minHeight: 200)
                }
            }
        }
        // Title and actions live in the window's title bar and toolbar, where macOS draws them as
        // Liquid Glass. This only works because the sidebar is permanent: while it animated open,
        // AppKit pushed toolbar items into the overflow menu (screen-recorded 2026-09-24). The
        // schedule stays in the content so the toolbar fits at the narrowest window width.
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { pendingDelete != nil },
                                                               set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                guard let ids = pendingDelete else { return }
                model?.deleteRuns(job.id, ids.count == job.runs.count ? nil : ids)
                selection.subtract(ids)
                pendingDelete = nil
            }
        } message: {
            Text("Their logs and the reports in the job folder are deleted too. This cannot be undone.")
        }
        .navigationTitle(job.title)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) { actions }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let version = job.definition?.version { parts.append("v\(version)") }
        if job.loadState != .loaded { parts.append(job.loadState.label) }
        return parts.joined(separator: " · ")
    }

    private var scheduleLine: String {
        let schedule = job.definition.map { Fmt.schedule($0.schedule) } ?? "—"
        guard let next = job.nextRun else { return schedule }
        return String(localized: "\(schedule) · next \(Fmt.nextRun(next, midSentence: true))")
    }

    @ViewBuilder
    private var actions: some View {
        let busy = model?.busyJobIDs.contains(job.id) ?? false
        let id = job.id
        Menu("More", systemImage: "ellipsis") {
            if job.loadState == .disabled {
                Button("Turn On", systemImage: "power") { model?.setEnabled(id, true) }
            } else {
                Button("Turn Off", systemImage: "pause") { model?.setEnabled(id, false) }
            }
            Button("Clear History…", systemImage: "trash") {
                pendingDelete = Set(job.runs.map(\.id))
            }
            .disabled(job.runs.isEmpty)
            Divider()
            Button("Show Folder in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([store.paths.definitionURL(id)])
            }
            Button("Copy Manual Run Command", systemImage: "terminal") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("chores run \(id)", forType: .string)
            }
        }
        .menuIndicator(.hidden)
        .pointerStyle(.link)
        .disabled(busy)

        if job.isRunning {
            Button {
                model?.stop(id)
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.glass)
            .pointerStyle(.link)
            .disabled(busy)
            .help("Stops the run; it is recorded as stopped by you and does not notify")
        } else {
            Button {
                model?.runNow(id)
            } label: {
                Label("Run", systemImage: "play.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.glassProminent)
            .pointerStyle(.link)
            .disabled(busy || job.definitionError != nil)
            .help("Runs the job once now; it is recorded as manual")
        }
    }

    private var historyTable: some View {
        Table(recentRuns, selection: tableSelection) {
            // Fixed-content columns stay narrow so the summary gets the remaining width.
            TableColumn("Date") { run in
                Text(Fmt.runDate(run.endedAt)).monospacedDigit().help(Fmt.absolute(run.endedAt))
            }
            .width(min: 100, ideal: 105, max: 160)
            TableColumn("Result") { run in
                OutcomeBadge(outcome: run.outcome)
            }
            .width(min: 95, ideal: 105, max: 130)
            TableColumn("Duration") { run in
                Text(Fmt.duration(run.durationSeconds)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 85, max: 110)
            TableColumn("Version") { run in
                Text(run.jobVersion.map { "v\($0)" } ?? "—").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 45, ideal: 55, max: 80)
            TableColumn("Summary") { run in
                Text(run.summary ?? "—").lineLimit(1).help(run.summary ?? "")
            }
            TableColumn("") { run in
                if run.trigger == .manual {
                    Image(systemName: "hand.tap").foregroundStyle(.secondary).help("Run manually")
                        .accessibilityLabel("Run manually")
                }
            }
            .width(22)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if !ids.isEmpty, model != nil {
                Button(ids.count == 1 ? String(localized: "Delete Run…") : String(localized: "Delete \(ids.count) Runs…"),
                       systemImage: "trash") {
                    pendingDelete = ids
                }
            }
        }
        .onDeleteCommand {
            guard model != nil else { return }
            pendingDelete = tableSelection.wrappedValue
        }
    }

    private var deleteTitle: String {
        let count = pendingDelete?.count ?? 0
        if count == 1 { return String(localized: "Delete this run?") }
        if count == job.runs.count { return String(localized: "Delete all \(count) runs of \(job.title)?") }
        return String(localized: "Delete \(count) runs?")
    }
}

private struct StatTiles: View {
    let job: JobSnapshot

    var body: some View {
        let stats = JobStats(runs: job.runs)
        HStack(spacing: 10) {
            StatTile(value: stats.successRate.map(Fmt.percent) ?? "—",
                     label: "Success · last 30",
                     color: (stats.successRate ?? 1) < 0.8 ? .orange : nil)
            StatTile(value: stats.averageDuration.map(Fmt.duration) ?? "—", label: "Average time")
            StatTile(value: "\(stats.runCount)", label: "Runs")
            StatTile(value: job.lastRun.map { Fmt.relative($0.endedAt) } ?? "—",
                     label: "Last run",
                     color: job.lastRun.map { $0.outcome == .ok ? nil : $0.outcome.color } ?? nil)
        }
    }
}

private struct StatTile: View {
    let value: String
    let label: LocalizedStringKey
    var color: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(color ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.fill.quinary, in: .rect(cornerRadius: 14))
    }
}

/// The selected run's report or log, loaded off the main thread.
struct RunOutputView: View {
    let job: JobSnapshot
    let run: RunRecord?
    let store: JobStore
    /// Smaller text for the menu panel's narrow page.
    var compact = false

    enum Pane: String { case report, log }
    @AppStorage(AppSettings.outputPane) private var preferred: Pane = .report
    /// A pick made on this run that the preference alone would not show (Report on a run without one).
    @State private var explicit: Pane?
    @State private var content = AttributedString("")

    /// What is shown: the preference, except that a run without a report shows its log rather than
    /// an empty report, without changing the preference for the next run.
    private var pane: Pane {
        if let explicit { return explicit }
        return preferred == .report && run?.report == nil ? .log : preferred
    }

    private var paneBinding: Binding<Pane> {
        Binding(get: { pane }, set: { picked in
            preferred = picked
            explicit = picked
        })
    }

    private struct LoadKey: Hashable {
        var runID: String?
        var pane: Pane
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("", selection: paneBinding) {
                    Text("Report").tag(Pane.report)
                    Text("Log").tag(Pane.log)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .pointerStyle(.link)
                Spacer()
                if let url = currentFileURL {
                    Button("Open File") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.link)
                        .pointerStyle(.link)
                }
            }
            .padding(.horizontal, compact ? 10 : 12)
            .padding(.vertical, 8)
            if let run, let summary = run.summary {
                // The table and the run list truncate the summary; this is where it is read in full.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: run.outcome.symbol).foregroundStyle(run.outcome.color)
                    Text(summary)
                        .textSelection(.enabled)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(run.id)
                }
                .font(compact ? .caption : .callout)
                .padding(.horizontal, compact ? 10 : 12)
                .padding(.bottom, 8)
            }
            Divider()
            ScrollView {
                Text(content)
                    .font(pane == .log ? .system(compact ? .caption2 : .callout, design: .monospaced)
                                       : (compact ? .caption : .callout))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(compact ? 10 : 12)
                    // A new identity per run and pane: otherwise a selection made in one pane
                    // stays on the view and lands on the other pane's text.
                    .id(LoadKey(runID: run?.id, pane: pane))
            }
        }
        .onChange(of: run?.id) { explicit = nil }
        .task(id: LoadKey(runID: run?.id, pane: pane)) {
            let text = await Self.load(pane: pane, run: run, jobID: job.id, store: store)
            // The detached load does not inherit cancellation; a slower, older load must not
            // overwrite the run selected since.
            guard !Task.isCancelled else { return }
            content = text
        }
    }

    private var currentFileURL: URL? {
        guard let run else { return nil }
        switch pane {
        case .report: return run.report.map { URL(fileURLWithPath: $0) }
        case .log: return store.paths.jobDirectory(job.id).appending(path: run.log)
        }
    }

    private nonisolated static let maxReportBytes = 256 * 1024

    private static func load(pane: Pane, run: RunRecord?, jobID: String, store: JobStore) async -> AttributedString {
        await Task.detached {
            guard let run else { return AttributedString(String(localized: "No run selected.")) }
            switch pane {
            case .report:
                guard let path = run.report else { return AttributedString(String(localized: "This run produced no report.")) }
                guard let handle = FileHandle(forReadingAtPath: path) else {
                    return AttributedString(String(localized: "Could not read the report: \(path)"))
                }
                defer { try? handle.close() }
                let data = (try? handle.read(upToCount: maxReportBytes)) ?? Data()
                var text = String(decoding: data, as: UTF8.self)
                if data.count == maxReportBytes { text += "\n\n" + String(localized: "… (report shortened; Open File shows all of it)") }
                return renderReport(text)
            case .log:
                let text = store.logTail(jobID, run: run) ?? String(localized: "Log not found.")
                return AttributedString(text.isEmpty ? String(localized: "(log is empty)") : text)
            }
        }.value
    }

    /// Inline markdown only (bold, code, links) with line breaks kept; headings become bold lines,
    /// since block-level markdown does not render inside a single `Text`.
    nonisolated static func renderReport(_ text: String) -> AttributedString {
        let lines = text.components(separatedBy: "\n").map { line -> String in
            guard line.hasPrefix("#") else { return line }
            let title = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? line : "**\(title)**"
        }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: lines.joined(separator: "\n"), options: options)) ?? AttributedString(text)
    }
}
