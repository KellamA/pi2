import Foundation
import Observation
import UIKit

/// A picture made ready to go with a message: drawn afresh (which leaves behind where and with what it was taken), at
/// most 2,000 pixels on its longer side and under the engine's 5 MB, as the Mac's `AttachmentReader` prepares one.
struct ConversationPicture: Equatable, Sendable {
    let name: String
    let data: Data
    let mimeType: String
    /// A small PNG for its chip.
    let thumbnail: Data

    /// As `submit` takes it, and as the Mac sends it (`PreparedAttachment.payload`).
    var payload: [String: Any] {
        ["kind": "image", "name": name, "mimeType": mimeType, "data": data.base64EncodedString()]
    }
}

/// The engine's limits on a message's pictures (the Mac's `AttachmentLimits`).
enum ConversationPictureLimits {
    static let count = 10
    static let bytes = 5 * 1024 * 1024
    static let side = 2000
}

struct ConversationPictureError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// Turns a photo's data into a picture a message can carry. Run off the main thread: a large photo takes a moment.
/// The shared steps are `PictureReader` (`Common/`); this keeps the composer's names, its own error in the person's
/// words, and a picture without the share's width and height.
enum ConversationPictureReader {
    static func prepare(_ data: Data, name: String) throws -> ConversationPicture {
        do {
            let made = try PictureReader.prepare(data, name: name)
            return ConversationPicture(name: made.name, data: made.data, mimeType: made.mimeType, thumbnail: made.thumbnail)
        } catch let failure as PictureReader.Failure {
            throw error(failure)
        }
    }

    static func prepare(_ image: CGImage, name: String) throws -> ConversationPicture {
        do {
            let made = try PictureReader.prepare(image, name: name)
            return ConversationPicture(name: made.name, data: made.data, mimeType: made.mimeType, thumbnail: made.thumbnail)
        } catch let failure as PictureReader.Failure {
            throw error(failure)
        }
    }

    private static func error(_ failure: PictureReader.Failure) -> ConversationPictureError {
        switch failure {
        case .unreadable: ConversationPictureError(message: "This picture could not be read.")
        case .unpreparable: ConversationPictureError(message: "This picture could not be prepared for sending.")
        }
    }
}

/// The pictures waiting to go with the next message of one conversation, while the phone shows it. Kept in memory only
/// (the phone's store is #692's), one list for each conversation, so that going to another screen and back keeps them.
@MainActor
@Observable
final class ConversationPictures {
    struct Entry: Identifiable, Equatable {
        enum Content: Equatable {
            case reading
            case ready(ConversationPicture)
            case failed(String)
        }

        let id = UUID()
        var name: String
        var content: Content
    }

    private(set) var entries: [Entry] = []

    private static var byConversation: [Int: ConversationPictures] = [:]

    static func of(_ conversation: Int) -> ConversationPictures {
        if let pictures = byConversation[conversation] { return pictures }
        let pictures = ConversationPictures()
        byConversation[conversation] = pictures
        return pictures
    }

    var ready: [ConversationPicture] {
        entries.compactMap { if case .ready(let picture) = $0.content { picture } else { nil } }
    }

    var isReading: Bool { entries.contains { $0.content == .reading } }
    var isFull: Bool { entries.count >= ConversationPictureLimits.count }

    /// Adds a photo's data, prepared off the main thread.
    func add(_ data: Data, name: String) {
        guard !isFull else { return }
        let entry = Entry(name: name, content: .reading)
        entries.append(entry)
        let entryID = entry.id
        Task.detached(priority: .userInitiated) {
            let content: Entry.Content
            do {
                content = .ready(try ConversationPictureReader.prepare(data, name: name))
            } catch {
                content = .failed(error.localizedDescription)
            }
            await MainActor.run { [weak self] in self?.settle(entryID, content) }
        }
    }

    /// Adds a photo the camera took.
    func add(_ image: UIImage, name: String) {
        guard let data = image.jpegData(compressionQuality: 0.95) else { return }
        add(data, name: name)
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    /// The ready pictures, taken out to be sent.
    func takeReady() -> [ConversationPicture] {
        let taken = ready
        entries.removeAll { if case .ready = $0.content { true } else { false } }
        return taken
    }

    /// Pictures whose message was refused, back in front of the others.
    func restore(_ pictures: [ConversationPicture]) {
        entries.insert(contentsOf: pictures.map { Entry(name: $0.name, content: .ready($0)) }, at: 0)
    }

    private func settle(_ id: UUID, _ content: Entry.Content) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].content = content
    }
}
