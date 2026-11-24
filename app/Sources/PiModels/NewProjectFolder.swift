import Foundation

/// A folder the Mac offers for a new project, as `projects.folders` answers it (docs/iphone.md 4.2; `engine/src/folders.ts`,
/// #698). A phone cannot browse the Mac's disk, so it chooses from these: the folders already used with pi² (its
/// projects', its agents', its recent conversations'), at most 50, never a listing of a folder's contents.
///
/// The answer: `{ folders: [{ path, name, where?, project?, repository? }] }`, in the order to show, free folders first.
/// - `path`: the folder's real path on the Mac, which `projects.create` is given back as it is.
/// - `name`: what to call it, its last component.
/// - `where`: the folder it is in, with the home folder as `~` (`~/Developer`).
/// - `project`: the name of a project that already has this folder, archived or not, which the engine would refuse a
///   second of; a screen says so and does not offer it.
/// - `repository`: `owner/name` of the GitHub repository it is a checkout of, when it is one.
public struct NewProjectFolder: Decodable, Identifiable, Equatable, Sendable {
    public let path: String
    public let name: String
    public var `where`: String?
    public var project: String?
    public var repository: String?

    public var id: String { path }

    public init(path: String, name: String, where: String? = nil, project: String? = nil, repository: String? = nil) {
        self.path = path
        self.name = name
        self.where = `where`
        self.project = project
        self.repository = repository
    }

    private struct Answer: Decodable {
        let folders: [NewProjectFolder]
    }

    /// The folders in an answer of `projects.folders`.
    public static func list(_ answer: JSONValue) throws -> [NewProjectFolder] {
        try JSONDecoder().decode(Answer.self, from: JSONEncoder().encode(answer)).folders
    }

    /// The line under its name: whose folder it is already, its repository, and where it is.
    public var detail: String {
        [project.map { "Already the folder of \($0)" }, repository, `where`].compactMap(\.self).joined(separator: " · ")
    }
}
