import AppKit
import ChoresKit
import SwiftUI

/// `ChoresApp --snapshot <dir>` renders the menu panel and each job's detail view to PNG files and
/// exits, so the UI can be checked without clicking the menu bar or granting screen recording.
///
/// Views are hosted in an off-screen window and captured with `cacheDisplay`; `ImageRenderer`
/// cannot draw AppKit-backed controls (buttons, lists, scroll views) and shows placeholders.
@MainActor
enum Snapshot {
    static func render(to directory: URL) {
        JobsModel.isSnapshot = true
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = JobsModel.shared
        let jobs = JobOverview.load(store: model.store)
        // Rendered in the "just refreshed" state so the footer note's space is visible and checked.
        model.replaceForSnapshot(jobs, refreshFeedback: .done)
        model.selectedJobID = jobs.first?.id

        let menuSize = NSHostingView(rootView: MenuContent(model: model)).fittingSize
        capture(MenuContent(model: model), size: menuSize, to: directory.appending(path: "menu.png"))
        layoutReport(jobs, menuSize: menuSize)
        capture(MainWindow(model: model), size: NSSize(width: 1000, height: 760),
                to: directory.appending(path: "window.png"), check: checkSplitLimits)
        for job in jobs {
            capture(JobDetailView(job: job, store: model.store), size: NSSize(width: 760, height: 900),
                    to: directory.appending(path: "detail-\(job.id).png"))
        }
        print("rendered \(jobs.count + 2) snapshots to \(directory.path)")
        exit(0)
    }

    /// Measurements that screenshots cannot show: a card must be the same height with and without
    /// hover, and the list must stop growing at the screen-derived cap.
    private static func layoutReport(_ jobs: [JobSnapshot], menuSize: NSSize) {
        func height(_ view: some View) -> CGFloat { NSHostingView(rootView: view.frame(width: 348)).fittingSize.height }
        var stable = true
        for job in jobs {
            let plain = height(JobCard(job: job, now: Date(), busy: false, run: {}, open: {}))
            let hovered = height(JobCard(job: job, now: Date(), busy: false, hovering: true, run: {}, open: {}))
            let busy = height(JobCard(job: job, now: Date(), busy: true, run: {}, open: {}))
            if plain != hovered || plain != busy { stable = false }
            print("card \(job.id): plain=\(plain) hover=\(hovered) busy=\(busy)")
        }
        print("cards stable across hover/busy: \(stable)")
        print("screen visible height=\(MenuLayout.screenHeight) list cap=\(MenuLayout.maxListHeight) menu=\(menuSize)")
    }

    /// Drags the sidebar divider far past its limit and reports where it ends up.
    private static func checkSplitLimits(_ root: NSView) {
        func find(_ view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView { return split }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        guard let split = find(root) else { print("split limits: no split view found"); return }
        if let controller = split.delegate as? NSSplitViewController { SplitLimits.configure(controller) }
        split.setPosition(700, ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
        let sidebar = split.arrangedSubviews.first?.frame.width ?? -1
        let detail = split.arrangedSubviews.last?.frame.width ?? -1
        print("split limits: divider pushed to 700 -> sidebar=\(sidebar) detail=\(detail) (max \(SplitLimits.sidebarMax))")
    }

    private static func capture(_ view: some View, size: NSSize, to url: URL, check: ((NSView) -> Void)? = nil) {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .light))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        // Let SwiftUI run its first layout and onAppear passes before capturing.
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        check?(hosting)
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
        window.orderOut(nil)
    }
}
