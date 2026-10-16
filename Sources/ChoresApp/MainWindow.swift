import AppKit
import ChoresKit
import SwiftUI

struct MainWindow: View {
    static let id = "main"

    @Bindable var model: JobsModel
    @State private var query = ""

    private var shownJobs: [JobSnapshot] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return model.jobs }
        return model.jobs.filter { job in
            [job.title, job.id, job.definition?.summary, job.definition?.category.map(Fmt.category), job.lastRun?.summary]
                .compactMap { $0 }
                .contains { $0.localizedStandardContains(query) }
        }
    }

    var body: some View {
        // The sidebar is always shown and cannot be toggled: while it animated open, AppKit pushed
        // its own toggle button into the toolbar overflow (a » flashed at the right) and slid the
        // detail content off the window's edge (screen-recorded 2026-09-24).
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: $model.selectedJobID) {
                ForEach(JobOverview.grouped(shownJobs), id: \.category) { group in
                    Section(Fmt.category(group.category)) {
                        ForEach(group.jobs) { job in
                            SidebarRow(job: job).tag(job.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $query, placement: .sidebar, prompt: "Search Jobs")
            .overlay {
                if shownJobs.isEmpty, !query.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .navigationSplitViewColumnWidth(min: SplitLimits.sidebarMin, ideal: 240, max: SplitLimits.sidebarMax)
            .toolbar(removing: .sidebarToggle)
            .background(SplitLimits())
        } detail: {
            Group {
                if let job = model.selectedJob {
                    JobDetailView(job: job, store: model.store, model: model)
                        .id(job.id)
                } else {
                    ContentUnavailableView("Select a Job", systemImage: "checklist",
                                           description: Text("Its history, report and log appear here."))
                }
            }
            .navigationSplitViewColumnWidth(min: SplitLimits.detailMin, ideal: 660)
        }
        .frame(minWidth: 880, minHeight: 580)
        .toolbarTitleDisplayMode(.inline)
        .alert("Action Failed", isPresented: Binding(get: { model.actionError != nil },
                                                      set: { if !$0 { model.actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
        .onAppear {
            guard !JobsModel.isSnapshot else { return }
            // An LSUIElement app has no Dock icon; become a regular app while the window is open
            // so it can be found with Cmd-Tab and is not left behind other apps.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

private struct SidebarRow: View {
    let job: JobSnapshot

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(job.tint).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title).lineLimit(1)
                RunStrip(outcomes: JobStats.strip(job.runs, count: 12), cell: 5)
            }
        }
        .padding(.vertical, 3)
    }
}

/// Puts the column limits on the `NSSplitViewController` behind `NavigationSplitView`.
///
/// `navigationSplitViewColumnWidth(max:)` only bounds the SwiftUI content: the AppKit divider kept
/// moving past it, so the sidebar content drifted left and the detail drifted right and was
/// clipped (seen 2026-09-24). Thickness limits on the split view items stop the divider itself.
struct SplitLimits: NSViewRepresentable {
    static let sidebarMin: CGFloat = 200
    static let sidebarMax: CGFloat = 320
    static let detailMin: CGFloat = 560

    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        private var observations: [NSKeyValueObservation] = []
        private weak var observedItem: NSSplitViewItem?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        private func apply() {
            guard let controller = SplitLimits.controller(from: self),
                  let sidebar = controller.splitViewItems.first, sidebar !== observedItem else { return }
            SplitLimits.configure(controller)
            // SwiftUI writes its own thickness back on later updates (min 140, no max), so the
            // limits are re-applied whenever the sidebar item's change.
            observedItem = sidebar
            observations = [\NSSplitViewItem.minimumThickness, \NSSplitViewItem.maximumThickness].map { keyPath in
                sidebar.observe(keyPath, options: [.new]) { [weak controller] _, _ in
                    DispatchQueue.main.async {
                        guard let controller else { return }
                        SplitLimits.configure(controller)
                    }
                }
            }
        }
    }

    @MainActor
    static func controller(from view: NSView) -> NSSplitViewController? {
        var current: NSView? = view
        while let candidate = current {
            if let split = candidate as? NSSplitView, let controller = split.delegate as? NSSplitViewController {
                return controller
            }
            current = candidate.superview
        }
        return nil
    }

    @MainActor
    static func configure(_ controller: NSSplitViewController) {
        guard let sidebar = controller.splitViewItems.first, let detail = controller.splitViewItems.last,
              sidebar !== detail else { return }
        // Only write when different, so the observers above do not loop.
        if sidebar.minimumThickness != sidebarMin { sidebar.minimumThickness = sidebarMin }
        if sidebar.maximumThickness != sidebarMax { sidebar.maximumThickness = sidebarMax }
        if sidebar.canCollapse { sidebar.canCollapse = false }
        if detail.minimumThickness != detailMin { detail.minimumThickness = detailMin }
    }
}

