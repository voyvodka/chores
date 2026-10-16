import AppKit
import SwiftUI

// Menu-panel controls are standard system buttons, so macOS draws them with its own Liquid Glass
// look and sizing. Hand-applied `glassEffect` on custom controls looked flat inside the panel,
// which is itself glass, and Apple advises against it ("use Liquid Glass effects sparingly").

struct PanelCapsuleButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .pointerStyle(.link)
    }
}

struct PanelIconButton: View {
    let systemImage: String
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .pointerStyle(.link)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A circle button that opens a native menu. SwiftUI's `Menu` ignores the circle border shape and
/// renders smaller than the neighbouring buttons, so this is a normal bordered button that pops up
/// an `NSMenu` under itself.
struct PanelIconMenu: View {
    let systemImage: String
    let help: LocalizedStringKey
    let items: () -> [PanelMenuItem]
    @State private var anchor = MenuAnchor()

    var body: some View {
        Button {
            PanelMenuItem.popUp(items(), under: anchor.view)
        } label: {
            Image(systemName: systemImage)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .pointerStyle(.link)
        .background(MenuAnchorView(anchor: anchor))
        .help(help)
        .accessibilityLabel(help)
    }
}

enum PanelMenuItem {
    case action(String, systemImage: String? = nil, checked: Bool = false, @MainActor () -> Void)
    case separator

    @MainActor
    static func popUp(_ items: [PanelMenuItem], under view: NSView?) {
        let menu = NSMenu()
        for item in items {
            switch item {
            case .separator:
                menu.addItem(.separator())
            case let .action(title, systemImage, checked, handler):
                let menuItem = ClosureMenuItem(title: title, handler: handler)
                if let systemImage { menuItem.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil) }
                menuItem.state = checked ? .on : .off
                menu.addItem(menuItem)
            }
        }
        if let view {
            // AppKit views are not flipped: y below zero is just under the button.
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -6), in: view)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }
}

/// The AppKit view behind a SwiftUI button, so a menu can be positioned against it.
@MainActor
private final class MenuAnchor {
    weak var view: NSView?
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { anchor.view = nsView }
}

@MainActor
private final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}

/// The footer's refresh control: a native spinner in place of the icon while reloading. The label
/// has a fixed frame so the button keeps its size between the two.
struct RefreshButton: View {
    let feedback: RefreshFeedback
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if feedback == .spinning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .frame(width: 16, height: 16)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .pointerStyle(.link)
        .help("Refresh")
        .accessibilityLabel(feedback == .spinning ? Text("Refreshing") : Text("Refresh"))
    }
}
