import AppKit
import ChoresKit
import SwiftUI

/// The panel shown from the menu-bar icon: the job list, and a job's detail that slides in over
/// it like a navigation push, without opening the window.
struct MenuContent: View {
    let model: JobsModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @State private var detailJobID: String? = MenuContent.initialDetail
    @State private var cardsHeight: CGFloat = 0
    /// Outcomes picked with the header chips; empty shows every job. Reset when the panel closes.
    @State private var filter: Set<Outcome> = []
    @AppStorage(AppSettings.showDisabledInMenu) private var showDisabled = false

    /// The jobs the list shows: disabled ones only when asked for, then the chip filter.
    private var visibleJobs: [JobSnapshot] {
        model.jobs.filter { job in
            (showDisabled || job.loadState != .disabled) && (filter.isEmpty || counts(job, in: filter))
        }
    }

    private var hiddenDisabledCount: Int {
        showDisabled ? 0 : model.jobs.filter { $0.loadState == .disabled }.count
    }

    /// First-frame guess before the real height is measured, so the panel does not open collapsed.
    private var estimatedCardsHeight: CGFloat {
        let jobs = visibleJobs
        let headers = JobOverview.grouped(jobs).count
        return CGFloat(jobs.count) * 58 + (headers > 1 ? CGFloat(headers) * 24 : 0) + 12
    }

    /// `--menu-detail <id>` opens the panel on a job's page, for screenshots of the menu preview.
    private static var initialDetail: String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--menu-detail"), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if let job = model.jobs.first(where: { $0.id == detailJobID }) {
                    MenuJobDetail(job: job, model: model, back: { show(nil) }, openInWindow: { open(job.id) })
                        .transition(.move(edge: .trailing))
                } else {
                    listPage
                        .transition(.move(edge: .leading))
                }
            }
            // Actions started here fail here; the window's alert would only show it much later.
            if let error = model.actionError {
                errorBanner(error)
            }
        }
        .frame(width: 360)
        .clipped()
        .onAppear {
            guard !JobsModel.isSnapshot else { return }
            model.refresh()
            model.refreshLoginItemStatus()
        }
        // Reopening the panel starts from the list, as a menu should.
        .onDisappear {
            detailJobID = nil
            filter = []
        }
    }

    private func show(_ jobID: String?) {
        withAnimation(.snappy(duration: 0.28)) { detailJobID = jobID }
    }

    private var listPage: some View {
        VStack(spacing: 0) {
            header
            if !model.schedulerRunning, !JobsModel.isSnapshot {
                schedulerBanner
            }
            if model.jobs.isEmpty {
                emptyState
            } else {
                // Grows with its content up to what the screen can show, then scrolls; the soft edge
                // shows there is more below, since overlay scrollers stay hidden until a scroll.
                ScrollView {
                    cards.onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { cardsHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollEdgeEffectStyle(.soft, for: .vertical)
                .frame(height: min(cardsHeight > 0 ? cardsHeight : estimatedCardsHeight, MenuLayout.maxListHeight))
            }
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Chores").font(.system(size: 15, weight: .semibold))
            Spacer()
            HStack(spacing: 4) {
                ForEach([Outcome.ok, .warn, .fail], id: \.self) { outcome in
                    CountChip(outcome: outcome, count: count(outcome), active: filter.contains(outcome)) {
                        withAnimation(.snappy(duration: 0.2)) {
                            if filter.contains(outcome) { filter.remove(outcome) } else { filter.insert(outcome) }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func count(_ outcome: Outcome) -> Int {
        model.jobs.filter { counts($0, in: [outcome]) }.count
    }

    /// Disabled jobs are `.ok` by definition; only a broken job.json still counts, as for the icon.
    private func counts(_ job: JobSnapshot, in outcomes: Set<Outcome>) -> Bool {
        guard outcomes.contains(job.attention) else { return false }
        return job.attention != .ok || (job.loadState != .disabled && job.lastRun != nil)
    }

    private var cards: some View {
        // Relative times must move even when no job data changes.
        TimelineView(.everyMinute) { context in
            let groups = JobOverview.grouped(visibleJobs)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(groups, id: \.category) { group in
                    // Headers only help once there is more than one group to tell apart.
                    if groups.count > 1 {
                        Text(Fmt.category(group.category).uppercased(with: Fmt.locale))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 14)
                            .padding(.top, 6)
                    }
                    ForEach(group.jobs) { job in
                        JobCard(job: job, now: context.date, busy: model.busyJobIDs.contains(job.id),
                                run: { model.runNow(job.id) }, open: { show(job.id) })
                    }
                }
                if groups.isEmpty {
                    Text(filter.isEmpty ? "All jobs are turned off." : "No job matches this filter.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                }
                if hiddenDisabledCount > 0 {
                    Button {
                        showDisabled = true
                    } label: {
                        Text(hiddenDisabledCount == 1 ? "Show 1 turned-off job" : "Show \(hiddenDisabledCount) turned-off jobs")
                            .font(.caption)
                    }
                    .buttonStyle(.link)
                    .pointerStyle(.link)
                    .padding(.leading, 14)
                    .padding(.vertical, 4)
                }
            }
            .padding(6)
        }
    }

    private var schedulerBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("The scheduler is not running; jobs will not start on time.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Start") { model.restartScheduler() }
                .controlSize(.small)
                .pointerStyle(.link)
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 10))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            Button {
                model.actionError = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .pointerStyle(.link)
            .help("Dismiss")
            .accessibilityLabel("Dismiss error")
        }
        .padding(10)
        .background(.red.opacity(0.1), in: .rect(cornerRadius: 10))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray").font(.title2).foregroundStyle(.secondary)
            Text("No jobs yet").font(.callout.weight(.medium))
            Text("Jobs appear here once Claude Code sets one up for you.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                PanelCapsuleButton(title: "All Jobs", systemImage: "macwindow") {
                    open(model.selectedJobID ?? model.jobs.first?.id)
                }
                Spacer()
                // Next to the button that was pressed; always laid out, only faded in, so
                // nothing in the footer shifts.
                Text("Updated")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .opacity(model.refreshFeedback == .done ? 1 : 0)
                    .animation(.easeInOut(duration: 0.25), value: model.refreshFeedback)
                    .accessibilityHidden(model.refreshFeedback != .done)
                RefreshButton(feedback: model.refreshFeedback) { model.userRefresh() }
                PanelIconMenu(systemImage: "ellipsis", help: "More") {
                    [
                        .action(String(localized: "Open at Login"), checked: model.launchAtLogin) {
                            model.setLaunchAtLogin(!model.launchAtLogin)
                        },
                        .action(String(localized: "Settings…"), systemImage: "gearshape") {
                            dismiss()
                            openSettings()
                            NSApp.activate()
                        },
                        .separator,
                        .action(String(localized: "Quit Chores")) { NSApp.terminate(nil) },
                    ]
                }
            }
            if let note = loginNote {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
            if let note = updateNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        // Same inset as the cards' colour edge (6 outer + 8 inner), so everything shares one margin.
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 14)
    }

    private var updateNote: String? {
        switch Updater.shared.state {
        case let .installing(tag): String(localized: "Updating to \(tag)…")
        case let .available(tag): String(localized: "\(tag) is available (Settings › Updates)")
        default: nil
        }
    }

    private var loginNote: String? {
        if let error = model.loginItemError { return error }
        if model.loginItemStatus == .requiresApproval {
            return String(localized: "Open at login is waiting for approval: System Settings › General › Login Items")
        }
        return nil
    }

    private func open(_ jobID: String?) {
        model.selectedJobID = jobID
        dismiss()
        openWindow(id: MainWindow.id)
        NSApp.activate()
    }
}

/// An outcome count in the header that doubles as a filter toggle for the list.
private struct CountChip: View {
    let outcome: Outcome
    let count: Int
    let active: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 3) {
                Image(systemName: outcome.symbol)
                Text(verbatim: "\(count)").monospacedDigit()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(count == 0 && !active ? Color.secondary.opacity(0.6) : outcome.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(active ? AnyShapeStyle(outcome.color.opacity(0.18))
                               : AnyShapeStyle(.fill.quaternary.opacity(hovering ? 1 : 0)),
                        in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .disabled(count == 0 && !active)
        .onHover { hovering = $0 }
        .help(active ? "Show all jobs" : "Show only these jobs")
        .accessibilityLabel("\(count) jobs: \(outcome.label)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

struct JobCard: View {
    let job: JobSnapshot
    let now: Date
    let busy: Bool
    let run: () -> Void
    let open: () -> Void
    @State private var hovering: Bool

    init(job: JobSnapshot, now: Date, busy: Bool, hovering: Bool = false,
         run: @escaping () -> Void, open: @escaping () -> Void) {
        self.job = job
        self.now = now
        self.busy = busy
        self.run = run
        self.open = open
        _hovering = State(initialValue: hovering)
    }

    /// Height of the title row. The trailing controls are overlaid on a box of this height, so
    /// showing the run button or a spinner never changes the card's size.
    static let titleRowHeight: CGFloat = 18

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(job.tint)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(job.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    trailing
                }
                .frame(height: Self.titleRowHeight)
                HStack(spacing: 8) {
                    RunStrip(outcomes: JobStats.strip(job.runs, count: 10))
                    Text(job.statusLine(now: now))
                        .font(.caption)
                        .foregroundStyle(job.attention == .ok ? Color.secondary : job.attention.color)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(.fill.quaternary.opacity(hovering ? 1 : 0), in: .rect(cornerRadius: 12))
        .contentShape(.rect(cornerRadius: 12))
        // A card does not look like a button, so the hand cursor tells that it opens the job.
        .pointerStyle(.link)
        .onTapGesture(perform: open)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Run Now") {
            if !job.isRunning, !busy, job.definitionError == nil { run() }
        }
    }

    private var showsRunButton: Bool { hovering && !job.isRunning && !busy && job.definitionError == nil }

    /// The next-run time always keeps its place; the run button and the spinner sit on top of it.
    private var trailing: some View {
        Text(job.nextRun.map { Fmt.nextRunShort($0) } ?? " ")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .opacity(showsRunButton || job.isRunning || busy ? 0 : 1)
            .frame(minWidth: 22, alignment: .trailing)
            .overlay(alignment: .trailing) {
                if job.isRunning || busy {
                    ProgressView().controlSize(.mini)
                } else if showsRunButton {
                    Button(action: run) {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .controlSize(.mini)
                    .help("Run Now")
                    .transition(.opacity)
                }
            }
    }
}

/// Panel sizing from the screen the menu opens on, so it never runs off a small display.
enum MenuLayout {
    /// The screen under the pointer, which is the one whose menu bar was just clicked. `NSScreen.main`
    /// follows the key window, which an accessory app usually lacks, so it falls to the primary screen.
    static var screenHeight: CGFloat {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        return screen?.visibleFrame.height ?? 800
    }

    /// The job list's cap: three quarters of the visible screen minus the header and footer.
    static var maxListHeight: CGFloat { max(240, screenHeight * 0.75 - 120) }

    /// Room for a job page's variable parts (runs, report, info) below its fixed header and stats.
    static var maxDetailBody: CGFloat { max(260, screenHeight * 0.75 - 200) }
}

