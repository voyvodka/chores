import AppKit
import ChoresKit
import SwiftUI

/// The Settings window (⌘, or ⋯ › Settings…).
struct SettingsView: View {
    let model: JobsModel
    /// `--settings-tab <name>` opens another tab, for screenshots.
    @State private var tab: String = {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--settings-tab"), index + 1 < args.count else { return "general" }
        return args[index + 1]
    }()

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") {
                GeneralSettings(model: model)
            }
            Tab("Updates", systemImage: "arrow.triangle.2.circlepath", value: "updates") {
                UpdateSettings(updater: Updater.shared)
            }
            Tab("About", systemImage: "info.circle", value: "about") {
                AboutSettings(model: model)
            }
        }
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            guard !JobsModel.isSnapshot else { return }
            model.refreshLoginItemStatus()
            // An accessory app's window opens behind the frontmost app unless the app activates.
            NSApp.activate()
        }
    }
}

private struct GeneralSettings: View {
    let model: JobsModel
    @State private var language = LanguageChoice.saved
    /// The language this process loaded its strings in; a different pick needs a relaunch.
    private let launchedWith = LanguageChoice.saved
    @AppStorage(AppSettings.showDisabledInMenu) private var showDisabled = false

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $language) {
                    Text("System").tag(LanguageChoice.system)
                    Text(verbatim: "English").tag(LanguageChoice.english)
                    Text(verbatim: "Türkçe").tag(LanguageChoice.turkish)
                }
                .pointerStyle(.link)
                .onChange(of: language) { LanguageChoice.save(language) }
                if language != launchedWith {
                    HStack {
                        Text("Chores restarts to show the new language.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart Now") { LanguageChoice.relaunch() }
                            .pointerStyle(.link)
                            .disabled(!JobsModel.isInstalledBundle)
                    }
                }
            }
            Section {
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin },
                                                      set: { model.setLaunchAtLogin($0) }))
                    .pointerStyle(.link)
                if let error = model.loginItemError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                Toggle("Show turned-off jobs in the menu", isOn: $showDisabled)
                    .pointerStyle(.link)
            }
            Section {
                LabeledContent("Notifications") {
                    Button("Open Notification Settings…") {
                        let id = Bundle.main.bundleIdentifier ?? ChoresPaths.appBundleIdentifier
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .pointerStyle(.link)
                }
            } footer: {
                Text("Each job decides which runs notify (its notify setting); macOS decides how they look.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct UpdateSettings: View {
    @Bindable var updater: Updater

    var body: some View {
        Form {
            if updater.isAvailable {
                Section {
                    Toggle("Install updates automatically", isOn: $updater.automatic)
                        .pointerStyle(.link)
                    LabeledContent("Installed", value: updater.installed?.tag ?? AppInfo.describe ?? "—")
                    LabeledContent("Status") {
                        Text(status)
                            .foregroundStyle(isProblem ? Color.orange : Color.secondary)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                    if let lastCheck = updater.lastCheck {
                        LabeledContent("Last checked", value: Fmt.relative(lastCheck))
                    }
                    HStack {
                        if FileManager.default.fileExists(atPath: updater.logURL.path) {
                            Button("Show Log") { NSWorkspace.shared.open(updater.logURL) }
                                .pointerStyle(.link)
                        }
                        Spacer()
                        if let tag = installableTag {
                            Button("Install \(tag)") { updater.install(tag, automatically: false) }
                                .pointerStyle(.link)
                        }
                        Button("Check Now") { Task { await updater.check(installing: false) } }
                            .pointerStyle(.link)
                            .disabled(isBusy)
                    }
                } footer: {
                    Text("Chores checks once a day for a newer release tag, builds it on this Mac and installs it. A running job postpones the install until it ends.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Text("Updates work in the installed Chores.app built from a git checkout with scripts/install.sh.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var status: String {
        switch updater.state {
        case .idle: String(localized: "Not checked yet")
        case .checking: String(localized: "Checking…")
        case .upToDate: String(localized: "Up to date")
        case let .available(tag): String(localized: "\(tag) is available")
        case let .installing(tag): String(localized: "Installing \(tag)…")
        case let .failed(message): message
        }
    }

    private var isProblem: Bool {
        if case .failed = updater.state { return true }
        return false
    }

    private var isBusy: Bool {
        switch updater.state {
        case .checking, .installing: true
        default: false
        }
    }

    /// A release found but not installed: automatic installs are off, a job postponed it, or it failed.
    private var installableTag: String? {
        if case let .available(tag) = updater.state { return tag }
        return nil
    }
}

private struct AboutSettings: View {
    let model: JobsModel

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    // The app has no icon of its own yet; the menu-bar symbol stands in for it.
                    Image(systemName: "checklist")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Color.accentColor.gradient, in: .rect(cornerRadius: 13))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "Chores").font(.title2.weight(.semibold))
                        Text("Version \(AppInfo.version)")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                if let describe = AppInfo.describe {
                    LabeledContent("Build", value: describe)
                        .textSelection(.enabled)
                }
                LabeledContent("Scheduler") {
                    Label(model.schedulerRunning ? String(localized: "Running") : String(localized: "Not running"),
                          systemImage: model.schedulerRunning ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.schedulerRunning ? Color.green : Color.orange)
                }
                LabeledContent("Jobs folder") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.paths.jobsDirectory])
                    }
                    .pointerStyle(.link)
                }
                LabeledContent("Runner") {
                    Text(verbatim: model.runner.path)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Section {
                if let url = AppInfo.repositoryWebURL {
                    LabeledContent("Source") {
                        Link(url.host().map { "\($0)\(url.path())" } ?? url.absoluteString, destination: url)
                            .pointerStyle(.link)
                    }
                }
                LabeledContent("License", value: "MIT")
            }
        }
        .formStyle(.grouped)
    }
}
