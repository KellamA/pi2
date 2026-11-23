import Foundation
import PiModels

/// A folder the Mac offers for a new project, as `projects.folders` answers it (docs/iphone.md 4.2; #698's engine part,
/// `engine/src/folders.ts`). A phone cannot browse the Mac's disk, so it chooses from these: the folders of the Mac's
/// projects' repositories and the folders used recently (docs/design/iphone.md, "What stays on the Mac, and why").
///
/// The answer this screen reads: `{ folders: [{ path, name, where?, project?, repository? }] }`, in the order to show.
/// - `path`: the folder's real path on the Mac, which `projects.create` is given back as it is.
/// - `name`: what to call it, usually its last component.
/// - `where`: where it is, for the line under its name, with the home folder as `~` (`~/Developer`).
/// - `project`: the name of a project that already has this folder, which the engine would refuse a second of; the row
///   says so and cannot be chosen.
/// - `repository`: `owner/name` of the GitHub repository it is a checkout of, when it is one.
struct NewProjectFolder: Decodable, Identifiable, Equatable, Sendable {
    let path: String
    let name: String
    var `where`: String? = nil
    var project: String? = nil
    var repository: String? = nil

    var id: String { path }

    private struct Answer: Decodable {
        let folders: [NewProjectFolder]
    }

    /// The folders in an answer of `projects.folders`.
    static func list(_ answer: JSONValue) throws -> [NewProjectFolder] {
        try JSONDecoder().decode(Answer.self, from: JSONEncoder().encode(answer)).folders
    }

    /// The line under its name: where it is, and what it is.
    var detail: String {
        [project.map { "Already the folder of \($0)" }, repository, `where`].compactMap(\.self).joined(separator: " · ")
    }
}

/// What the new project's form has chosen, and what `projects.create` is sent for it.
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
