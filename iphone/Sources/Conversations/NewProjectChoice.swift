import Foundation
import PiModels

/// What the new project's form has chosen among the folders the Mac offers (`NewProjectFolder`, in PiModels), and what `projects.create` is sent for it.
struct NewProjectChoice: Equatable {
    /// The folder chosen among those offered; nil for a project with no folder.
    var folder: NewProjectFolder?
    /// The name typed; empty for the engine's own (the folder's name, or "No folder").
    var name = ""
    /// The template its orchestrator is a copy of; nil for pi²'s default orchestrator.
    var template: String?

    /// The name to send, or nil to let the engine name it.
    var sentName: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The engine names a project after its folder, or "No folder" (`projects.create`); the field shows it greyed.
    var suggestedName: String { folder?.name ?? "No folder" }

    /// Why it cannot be made as chosen, or nil.
    var refusal: String? {
        if let project = folder?.project { return "That folder is already the folder of \(project)." }
        if (sentName?.count ?? 0) > 80 { return "A project's name is at most 80 characters." }
        return nil
    }
}
