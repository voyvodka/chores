import AppKit
import ChoresKit
import ServiceManagement
import SwiftUI
import UserNotifications

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        // No-UI switches for install.sh: (un)register the scheduler agent embedded in the bundle.
        if args.contains("--register-scheduler") || args.contains("--unregister-scheduler") {
            let registering = args.contains("--register-scheduler")
            let agent = SMAppService.agent(plistName: "\(ChoresPaths.schedulerLabel).plist")
            do {
                if registering { try agent.register() } else { try agent.unregister() }
                print("scheduler agent status: \(agent.status.rawValue)")
            } catch {
                print("scheduler agent error: \(error) (status \(agent.status.rawValue))")
                // Unregistering an agent that is not registered is expected; failing to register is not.
                if registering { exit(1) }
            }
            return
        }
        // Removes this executable's own login item and exits; used to clean up a registration made by
        // a development build.
        if args.contains("--unregister-login-item") {
            let status = (try? SMAppService.mainApp.unregister()) != nil ? "removed" : "nothing to remove"
            print("login item for \(Bundle.main.executablePath ?? "?"): \(status)")
            return
        }
        if let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count {
            MainActor.assumeIsolated { Snapshot.render(to: URL(fileURLWithPath: args[index + 1])) }
            return
        }
        ChoresApp.main()
    }
}

struct ChoresApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = JobsModel.shared

    var body: some Scene {
        // No `isInserted:` binding: with one, Cmd-dragging the icon out removes it for good and the
        // app has no other way back.
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Chores", id: MainWindow.id) {
            MainWindow(model: model)
        }
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 900, height: 640)

        Settings {
            SettingsView(model: model)
        }

        // The menu panel hosted in a normal window, for screenshots: Liquid Glass only renders in a
        // real on-screen window, and the menu-bar panel cannot be opened programmatically.
        Window("Menu Preview", id: "menu-preview") {
            MenuContent(model: model)
        }
        .defaultLaunchBehavior(.suppressed)
        .windowResizability(.contentSize)
        .commandsRemoved()
    }
}

private struct MenuBarLabel: View {
    let model: JobsModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Image(systemName: model.anyRunning ? "arrow.triangle.2.circlepath" : model.attention.menuBarSymbol)
            // Without it VoiceOver reads the symbol's own name, "Checklist With Checkmarks".
            .accessibilityLabel(accessibilityLabel)
            .onAppear {
                model.start()
                // Lets scripts and screenshots open the window without clicking the menu bar.
                if CommandLine.arguments.contains("--show-window") {
                    openWindow(id: MainWindow.id)
                }
                if CommandLine.arguments.contains("--show-menu-preview") {
                    openWindow(id: "menu-preview")
                }
                if CommandLine.arguments.contains("--show-settings") {
                    openSettings()
                }
            }
            // The label is the one view that always exists, so it opens the window on behalf of
            // AppKit code such as the notification delegate, which has no `openWindow`.
            // `initial` covers a notification click that relaunched the app and set the request
            // before this label first rendered.
            .onChange(of: model.windowRequest, initial: true) {
                guard model.windowRequest != nil else { return }
                openWindow(id: MainWindow.id)
                NSApp.activate()
            }
    }

    private var accessibilityLabel: String {
        let status = switch model.attention {
        case .ok: String(localized: "no problems")
        case .warn: String(localized: "warnings")
        case .fail: String(localized: "errors")
        }
        return model.anyRunning ? String(localized: "Chores, a job is running, \(status)") : String(localized: "Chores, \(status)")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Outside the installed bundle UNUserNotificationCenter aborts the process.
        guard JobsModel.isInstalledBundle else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let jobID = response.notification.request.content.userInfo["jobID"] as? String
        await MainActor.run { JobsModel.shared.requestWindow(for: jobID) }
    }
}
