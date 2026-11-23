import Foundation
import ImageIO
import Observation
import UIKit
import UniformTypeIdentifiers

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
enum ConversationPictureReader {
    static func prepare(_ data: Data, name: String) throws -> ConversationPicture {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            throw ConversationPictureError(message: "This picture could not be read.")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: ConversationPictureLimits.side,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ConversationPictureError(message: "This picture could not be read.")
        }
        return try prepare(image, name: name)
    }

    static func prepare(_ image: CGImage, name: String) throws -> ConversationPicture {
        let failed = ConversationPictureError(message: "This picture could not be prepared for sending.")
        // A little under the engine's limit.
        let budget = ConversationPictureLimits.bytes - 64 * 1024
        let side = max(image.width, image.height)
        let scale = side > ConversationPictureLimits.side ? CGFloat(ConversationPictureLimits.side) / CGFloat(side) : 1
        guard var flat = draw(image, scale: scale) else { throw failed }
        // Small pictures (a screenshot's text) stay sharp as PNG; photos go as JPEG.
        if flat.width * flat.height <= 640_000, let png = encode(flat, as: .png), png.count <= budget {
            return ConversationPicture(name: name, data: png, mimeType: "image/png", thumbnail: thumbnail(flat))
        }
        for _ in 0..<6 {
            for quality in [0.85, 0.7, 0.5] {
                if let jpeg = encode(flat, as: .jpeg, quality: quality), jpeg.count <= budget {
                    return ConversationPicture(name: name, data: jpeg, mimeType: "image/jpeg", thumbnail: thumbnail(flat))
                }
            }
            guard let smaller = draw(flat, scale: 0.7) else { break }
            flat = smaller
        }
        throw failed
    }

    /// The picture drawn again on white, opaque, scaled.
    private static func draw(_ image: CGImage, scale: CGFloat) -> CGImage? {
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func encode(_ image: CGImage, as type: UTType, quality: Double = 1) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func thumbnail(_ image: CGImage) -> Data {
        let side = 160
        let scale = min(1, CGFloat(side) / CGFloat(max(image.width, image.height)))
        guard let small = draw(image, scale: scale) else { return Data() }
        return encode(small, as: .png) ?? Data()
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
