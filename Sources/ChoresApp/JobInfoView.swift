import AppKit
import ChoresKit
import SwiftUI

/// Everything a job says about itself: category, version history, requirements, project, links,
/// permissions and notes. Shown on the Bilgi tab of the window and of the menu page.
struct JobInfoView: View {
    let job: JobSnapshot
    let store: JobStore
    var compact = false

    private var bodyFont: Font { compact ? .caption : .callout }

    var body: some View {
        if let definition = job.definition {
            VStack(alignment: .leading, spacing: compact ? 12 : 16) {
                badges(definition)
                if !definition.summary.isEmpty {
                    Text(definition.summary).font(bodyFont)
                }
                if let requires = definition.requires, !requires.isEmpty {
                    section("Requirements") {
                        ForEach(requires, id: \.self) { command in
                            let missing = job.missingRequirements.contains(command)
                            Label(command, systemImage: missing ? "xmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(missing ? Color.orange : Color.secondary)
                                .help(missing ? String(localized: "Not found on the job's PATH") : String(localized: "Found"))
                        }
                    }
                }
                if definition.projectURL != nil || !(definition.links ?? []).isEmpty {
                    section("Links") {
                        if let project = definition.projectURL {
                            linkButton(String(localized: "Project: \(project.lastPathComponent)"), systemImage: "folder", url: project)
                        }
                        ForEach(Array((definition.links ?? []).enumerated()), id: \.offset) { _, link in
                            if let url = link.resolvedURL {
                                linkButton(link.title, systemImage: url.isFileURL ? "folder" : "link", url: url)
                            }
                        }
                    }
                }
                if let changelog = definition.changelog, !changelog.isEmpty {
                    section("Version History") {
                        ForEach(Array(changelog.prefix(compact ? 3 : 20).enumerated()), id: \.offset) { _, entry in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(verbatim: "v\(entry.version)").fontWeight(.semibold).monospacedDigit()
                                    if let date = entry.date { Text(date).foregroundStyle(.secondary).monospacedDigit() }
                                }
                                ForEach(Array(entry.notes.enumerated()), id: \.offset) { _, note in
                                    Text(verbatim: "• \(note)").foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if let permissions = definition.permissions {
                    section("Permissions") {
                        Text(permissions).foregroundStyle(.secondary)
                    }
                }
                if let notes = definition.notes, !notes.isEmpty {
                    section("Notes") {
                        ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                            Text(verbatim: "• \(note)").foregroundStyle(.secondary)
                        }
                    }
                }
                section("Setup") {
                    Text(verbatim: "id: \(job.id)").textSelection(.enabled)
                    Text(store.paths.jobDirectory(job.id).path).textSelection(.enabled).foregroundStyle(.secondary)
                    if let createdAt = definition.createdAt {
                        Text(verbatim: "\(definition.createdBy ?? "?") · \(Fmt.absolute(createdAt))").foregroundStyle(.secondary)
                    }
                }
            }
            .font(bodyFont)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Label(job.definitionError ?? String(localized: "Could not read job.json"), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(bodyFont)
        }
    }

    private func badges(_ definition: JobDefinition) -> some View {
        HStack(spacing: 6) {
            if let category = definition.category {
                Text(Fmt.category(category))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.fill.tertiary, in: .capsule)
            }
            if let version = definition.version {
                Text(verbatim: "v\(version)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.fill.tertiary, in: .capsule)
            }
        }
    }

    private func section(_ title: LocalizedStringResource, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: title).uppercased(with: Fmt.locale))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            content()
        }
    }

    private func linkButton(_ title: String, systemImage: String, url: URL) -> some View {
        Button {
            if url.isFileURL {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                NSWorkspace.shared.open(url)
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.link)
        .pointerStyle(.link)
        .help(url.isFileURL ? url.path : url.absoluteString)
    }
}
