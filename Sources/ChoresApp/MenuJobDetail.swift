import AppKit
import ChoresKit
import SwiftUI

/// A job's page inside the menu panel: what the window shows, condensed to the panel's width.
struct MenuJobDetail: View {
    let job: JobSnapshot
    let model: JobsModel
    let back: () -> Void
    let openInWindow: () -> Void

    @State private var selectedRunID: String?
    @AppStorage(AppSettings.detailTab) private var tab: DetailTab = .history

    private var recentRuns: [RunRecord] { Array(job.runs.suffix(5).reversed()) }
    private var selectedRun: RunRecord? {
        job.runs.first { $0.id == selectedRunID } ?? job.runs.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Picker("", selection: $tab) {
                Text("History").tag(DetailTab.history)
                Text("Info").tag(DetailTab.info)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .pointerStyle(.link)
            if tab == .info || CommandLine.arguments.contains("--menu-info") {
                ScrollView {
                    JobInfoView(job: job, store: model.store, compact: true)
                        .padding(.bottom, 4)
                }
                .frame(height: min(400, MenuLayout.maxDetailBody))
            } else {
                runsTab
            }
            footer
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var runsTab: some View {
        stats
        RunStrip(outcomes: JobStats.strip(job.runs, count: 24), cell: 9)
            .frame(maxWidth: .infinity, alignment: .leading)
        if job.runs.isEmpty {
            Text("No runs yet. History and reports appear here after the first run.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            runList
            RunOutputView(job: job, run: selectedRun, store: model.store, compact: true)
                .frame(height: min(210, max(120, MenuLayout.maxDetailBody - 190)))
                .background(.fill.quinary, in: .rect(cornerRadius: 12))
                .clipShape(.rect(cornerRadius: 12))
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            PanelIconButton(systemImage: "chevron.left", help: "Back", action: back)
                .keyboardShortcut(.cancelAction)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if model.busyJobIDs.contains(job.id) {
                ProgressView().controlSize(.small).frame(width: 28)
            } else if job.isRunning {
                PanelIconButton(systemImage: "stop.fill", help: "Stop") { model.stop(job.id) }
            } else {
                PanelIconButton(systemImage: "play.fill", help: "Run Now") { model.runNow(job.id) }
                    .disabled(job.definitionError != nil)
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let version = job.definition?.version { parts.append("v\(version)") }
        if job.loadState != .loaded { parts.append(job.loadState.label) }
        parts.append(job.definition.map { Fmt.schedule($0.schedule) } ?? "—")
        if let next = job.nextRun { parts.append(String(localized: "next \(Fmt.nextRunShort(next, midSentence: true))")) }
        return parts.joined(separator: " · ")
    }

    private var stats: some View {
        let stats = JobStats(runs: job.runs)
        return HStack(spacing: 8) {
            MiniTile(value: stats.successRate.map(Fmt.percent) ?? "—", label: "Success")
            MiniTile(value: stats.averageDuration.map(Fmt.duration) ?? "—", label: "Avg. time")
            MiniTile(value: "\(stats.runCount)", label: "Runs")
        }
    }

    private var runList: some View {
        VStack(spacing: 1) {
            ForEach(recentRuns) { run in
                Button {
                    selectedRunID = run.id
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: run.outcome.symbol)
                            .foregroundStyle(run.outcome.color)
                            .font(.system(size: 11))
                        Text(Fmt.absolute(run.endedAt))
                            .monospacedDigit()
                            .frame(width: 118, alignment: .leading)
                        Text(run.summary ?? Fmt.duration(run.durationSeconds))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(run.id == selectedRun?.id ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear),
                                in: .rect(cornerRadius: 7))
                    .contentShape(.rect(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            PanelCapsuleButton(title: "Open in Window", systemImage: "macwindow", action: openInWindow)
            Spacer()
            PanelIconMenu(systemImage: "ellipsis", help: "More") {
                let id = job.id
                let folder = model.store.paths.definitionURL(id)
                return [
                    job.loadState == .disabled
                        ? .action(String(localized: "Turn On"), systemImage: "power") { model.setEnabled(id, true) }
                        : .action(String(localized: "Turn Off"), systemImage: "pause") { model.setEnabled(id, false) },
                    .separator,
                    .action(String(localized: "Show Folder in Finder"), systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    },
                    .action(String(localized: "Copy Manual Run Command"), systemImage: "terminal") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("chores run \(id)", forType: .string)
                    },
                ]
            }
            .disabled(model.busyJobIDs.contains(job.id))
        }
    }
}

private struct MiniTile: View {
    let value: String
    let label: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.fill.quinary, in: .rect(cornerRadius: 12))
    }
}
