
import PiModels
import SwiftUI

/// The templates, listed and edited as agents, from More on the projects list (docs/design/iphone.md, "Every screen and
/// function of the Mac app"): the agents of no project, which a project's agents are copied from, as the Mac's sidebar
/// lists them under Shared. A template's page opens with `openRoute(.agent(id))`.
struct BoardTemplatesView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.openRoute) private var openRoute
    @State private var problem: String?
    @State private var adding = false

    init() {}

    var body: some View {
        let data = session.boardData
        let templates = data.templates
        Group {
            if !data.connected && !data.loaded {
                BoardMissing(waiting: true, title: "", description: "")
            } else {
                List {
                    if let sample = data.sample { BoardSampleNote(what: sample) }
                    Section {
                        if templates.isEmpty {
                            Text("No templates yet. Make one with the + button.").foregroundStyle(.secondary)
                        }
                        ForEach(templates) { template in
                            BoardLinkRow(route: .agent(template.id)) {
                                BoardMarkRow {
                                    AgentMark(agent: template)
                                } words: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(template.name).font(.body.weight(.semibold))
                                        BoardAgentTags(agent: template)
                                        let model = data.shortModelName(template.model).boardOr("App default")
                                        Text(template.description.isEmpty ? model : "\(model) · \(template.description)")
                                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                            }
                            .accessibilityHint("Opens the template \(template.name)")
                        }
                    } footer: {
                        VStack(alignment: .leading, spacing: 6) {
                            if let problem { BoardProblem(problem) }
                            Text("Templates are agents kept outside any project. A project’s agents are copied from them, and changing a template changes no copy until it is updated from it, on the copy’s page.")
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Templates")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Template", systemImage: "plus") { newTemplate(data) }
                    .disabled(!data.connected || adding)
            }
        }
    }

    private func newTemplate(_ data: BoardData) {
        let name = BoardAgentDraft.uniqueName(among: data.templates)
        let engine = session.engine
        adding = true
        Task {
            switch await BoardRequests.newTemplate(engine, named: name) {
            case .success(let id): problem = nil; openRoute(.agent(id))
            case .failure(let failure): problem = "No template was made: \(failure.message)"
            }
            adding = false
        }
    }
}
