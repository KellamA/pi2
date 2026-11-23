import EngineKit
import PiModels
import SwiftUI

/// A new project, from a folder the Mac offers (its projects' folders, recent folders), since the phone cannot browse
/// the Mac's disk (docs/design/iphone.md, "What stays on the Mac, and why"; "Choosing a project's folder: from the folders
/// the Mac offers"). Its orchestrator is a copy of a template, or of pi²'s default orchestrator, as `projects.create`
/// makes it; once made, the project's hub opens on its conversation with it.
///
/// The folders come from `projects.folders` (docs/iphone.md 4.2), which #698's engine part adds; until a Mac answers it,
/// the screen says the Mac did not offer any, and a project with no folder can still be made.
struct NewProjectView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.openRoute) private var openRoute
    @State private var folders: NewProjectFolders = .asking
    @State private var choice = NewProjectChoice()
    /// Whether the person has chosen a folder (or none) themselves; until then the first free folder offered is chosen.
    @State private var chose = false
    @State private var making = false
    @State private var problem: String?

    init() {}

    private var engine: EngineSession<MessageField> { session.engine }

    private var isSample: Bool {
        #if DEBUG
        return ConversationsSample.current?.folders != nil
        #else
        return false
        #endif
    }

    /// The templates its orchestrator may be a copy of: agents of no project, not removed, by name.
    private var templates: [AgentProfile] {
        engine.agents.filter { $0.removedAt == nil }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Group {
            if !isSample, engine.status != .connected {
                ConversationsWaiting()
            } else {
                form
            }
        }
        .navigationTitle("New project")
        .navigationBarTitleDisplayMode(.inline)
        // Asked once the Mac is connected, and again if it connects anew.
        .task(id: engine.status == .connected || isSample) {
            guard engine.status == .connected || isSample else { return }
            await ask()
            #if DEBUG
            if await ConversationsSample.take("make") { make() }
            #endif
        }
    }

    private var form: some View {
        Form {
            if isSample {
                ConversationsSampleNote()
            }
            folderSection
            Section {
                TextField("Name", text: $choice.name, prompt: Text(choice.suggestedName))
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
            } header: {
                Text("Name")
            } footer: {
                Text("Left empty, it is named after its folder.")
            }
            Section {
                Picker("Orchestrator", selection: $choice.template) {
                    Text("pi²'s orchestrator").tag(String?.none)
                    ForEach(templates) { template in
                        Text(template.name).tag(Optional(template.id))
                    }
                }
                .pickerStyle(.navigationLink)
            } header: {
                Text("Orchestrator")
            } footer: {
                Text("The project's orchestrator hands out its work. It is a copy of the template you choose, made for this project, without the template's Allow everything or its variables' values.")
            }
            Section {
                if let problem {
                    ConversationsProblemRow(message: problem) { self.problem = nil }
                }
                if let refusal = choice.refusal {
                    Text(refusal)
                        .foregroundStyle(.secondary)
                }
                Button(action: make) {
                    HStack {
                        Spacer()
                        if making { ProgressView().padding(.trailing, 6) }
                        Text("Make Project").bold()
                        Spacer()
                    }
                }
                .disabled(making || choice.refusal != nil)
            } footer: {
                Text("pi² makes the project and its orchestrator in one step, with an empty conversation with it, and opens it.")
            }
        }
    }

    @ViewBuilder private var folderSection: some View {
        Section {
            switch folders {
            case .asking:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Asking your Mac for its folders…").foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            case .refused(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Label("Your Mac did not offer its folders.", systemImage: "folder.badge.questionmark")
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Ask again") { Task { await ask() } }
                        .buttonStyle(.bordered)
                }
                .padding(.vertical, 4)
            case .offered(let offered):
                if offered.isEmpty {
                    Text("Your Mac has no folders to offer yet.").foregroundStyle(.secondary)
                }
                ForEach(offered) { folder in
                    folderRow(folder)
                }
            }
            noFolderRow
        } header: {
            Text("Folder")
        } footer: {
            Text("Your Mac offers the folders of its projects' repositories and the folders used recently. Any other folder is chosen on the Mac, in its own panel.")
        }
    }

    private func folderRow(_ folder: NewProjectFolder) -> some View {
        let chosen = choice.folder == folder
        return Button {
            choice.folder = folder
            chose = true
        } label: {
            ConversationsRowStack {
                Image(systemName: folder.repository == nil ? "folder" : "folder.badge.gearshape")
                    .foregroundStyle(folder.project == nil ? Color.pi2Accent : .secondary)
                    .accessibilityHidden(true)
            } content: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name)
                        .foregroundStyle(folder.project == nil ? .primary : .secondary)
                    if !folder.detail.isEmpty {
                        Text(folder.detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            } trailing: {
                if chosen {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.pi2Accent)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(folder.project != nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([folder.name, folder.detail.isEmpty ? nil : folder.detail].compactMap(\.self).joined(separator: ", "))
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }

    private var noFolderRow: some View {
        let chosen = choice.folder == nil
        return Button {
            choice.folder = nil
            chose = true
        } label: {
            ConversationsRowStack {
                Image(systemName: "folder.badge.minus")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            } content: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No folder")
                    Text("Its agents work where each conversation says")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } trailing: {
                if chosen {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.pi2Accent)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }

    private func ask() async {
        #if DEBUG
        if let sample = ConversationsSample.current?.folders {
            take(sample)
            return
        }
        #endif
        folders = .asking
        switch await ConversationsRequests.folders(engine) {
        case .success(let offered): take(offered)
        case .failure(let failure): folders = .refused(failure.message)
        }
    }

    private func take(_ offered: [NewProjectFolder]) {
        folders = .offered(offered)
        if !chose { choice.folder = offered.first { $0.project == nil } }
    }

    private func make() {
        guard !making else { return }
        making = true
        problem = nil
        Task {
            defer { making = false }
            switch await ConversationsRequests.createProject(engine, folder: choice.folder?.path, name: choice.sentName, template: choice.template) {
            case .success(let id):
                // The `projects` event that lists it may come after the answer, as the Mac's New Project waits for it.
                for _ in 0..<20 where !engine.projects.contains(where: { $0.id == id }) { try? await Task.sleep(for: .milliseconds(50)) }
                openRoute(.project(id))
            case .failure(let failure):
                problem = "The project was not made: \(failure.message)"
            }
        }
    }
}

/// The folders the Mac offered, while it is asked, or why it offered none.
enum NewProjectFolders: Equatable {
    case asking
    case offered([NewProjectFolder])
    case refused(String)
}
