import CryptoKit
import Foundation
import PiModels
import TranscriptKit

// The engine's requests and event for what agents presented (docs/design/presenting.md, "Events and requests for the app
// and the phone"), on the app's engine client: the records of a conversation, a picture or a page's snapshot, one file of
// a page, the person's network switch, and `conversation.presented` as it comes, for whoever follows a conversation.

/// A picture or a file as the engine answers it: its type, and its bytes.
struct PresentedBytes: Sendable {
    let mimeType: String
    let data: Data
}

extension EngineClient {
    /// Every presentation of a conversation, every version: `presented.list`. A record the app cannot read is left out.
    func presentedList(conversation: Int) async throws -> [PresentationRecord] {
        let answer = try await call("presented.list", ["id": conversation])
        return PresentationRecord.list(from: try JSONEncoder().encode(answer))
    }

    /// A picture, or a page's snapshot once it is drawn: `presented.picture`.
    func presentedPicture(conversation: Int, presentation: String, version: Int, item: Int) async throws -> PresentedBytes {
        try Self.bytes(await call("presented.picture", ["id": conversation, "presentation": presentation, "version": version, "item": item]))
    }

    /// One file of a page, by its path in the page's manifest exactly: `presented.file`.
    func presentedFile(conversation: Int, presentation: String, version: Int, item: Int, path: String) async throws -> PresentedBytes {
        try Self.bytes(await call("presented.file", ["id": conversation, "presentation": presentation, "version": version, "item": item, "path": path]))
    }

    /// The person's Allow network for one version's pages: `presented.network`. The record comes back changed in
    /// `conversation.presented`.
    func presentedNetwork(conversation: Int, presentation: String, version: Int, allow: Bool) async throws {
        _ = try await call("presented.network", ["id": conversation, "presentation": presentation, "version": version, "allow": allow])
    }

    /// Each record of `conversation` that changes, whole, as `conversation.presented` brings it, until the stream is let
    /// go. The engine sends it only to a connection that has the conversation open, so whoever follows keeps it open.
    func presentedUpdates(conversation: Int) -> AsyncStream<PresentationRecord> {
        presentedFollowers.follow(conversation)
    }

    /// The manifest of a presented page: its entry and its files, for `PresentedPageView`. The engine has no request
    /// for it, so it is read where the engine keeps it in the data folder (`presented/<conversation>/pages/<sha256>.json`),
    /// never through a link, and taken only if its SHA-256 is the one the record names: exactly what the engine kept.
    func presentedPage(conversation: Int, item: PresentedItem) throws -> PresentedPage {
        guard item.kind == .page else { throw EngineError(message: "That item is a picture, not a page.") }
        let data = try PresentedManifest.read(home: home, conversation: conversation, sha256: item.sha256)
        return try PresentedManifest.page(from: data)
    }

    private static func bytes(_ answer: JSONValue) throws -> PresentedBytes {
        guard let type = answer["mimeType"]?.stringValue, let base64 = answer["data"]?.stringValue,
              let data = Data(base64Encoded: base64) else { throw EngineError(message: "The engine's answer was not a file.") }
        return PresentedBytes(mimeType: type, data: data)
    }
}

/// Who follows which conversation's `conversation.presented`, for `presentedUpdates`.
@MainActor
final class PresentedFollowers {
    private var followers: [Int: [UUID: AsyncStream<PresentationRecord>.Continuation]] = [:]

    func follow(_ conversation: Int) -> AsyncStream<PresentationRecord> {
        let (stream, continuation) = AsyncStream<PresentationRecord>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let id = UUID()
        followers[conversation, default: [:]][id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.followers[conversation]?[id] = nil
                if self?.followers[conversation]?.isEmpty == true { self?.followers[conversation] = nil }
            }
        }
        return stream
    }

    /// One `conversation.presented` event, as sent: `{ id, record }`. A record the app cannot read is dropped.
    func take(_ line: Data) {
        struct Event: Decodable {
            let id: Int
            let record: PresentationRecord
        }
        guard let event = try? JSONDecoder().decode(Event.self, from: line), let listening = followers[event.id] else { return }
        for continuation in listening.values { continuation.yield(event.record) }
    }
}

/// A page's files for `PresentedPageView`, fetched from the engine with `presented.file`, by the manifest's path.
struct EnginePresentedFiles: PresentedFiles {
    let engine: EngineClient
    let conversation: Int
    let presentation: String
    let version: Int
    let item: Int

    func bytes(of file: PresentedFile) async throws -> Data {
        try await engine.presentedFile(conversation: conversation, presentation: presentation, version: version, item: item, path: file.path).data
    }
}

/// Reading a page's manifest where the engine keeps it.
enum PresentedManifest {
    /// Larger than any manifest of 500 files whose paths are at most 1,024 bytes.
    static let largest = 4 * 1024 * 1024

    static func read(home: URL, conversation: Int, sha256: String) throws -> Data {
        let hex = Set("0123456789abcdef".utf8)
        guard conversation >= 0, sha256.utf8.count == 64, sha256.utf8.allSatisfy({ hex.contains($0) }) else {
            throw EngineError(message: "This conversation has no such presentation.")
        }
        // Each folder from `presented` down must be a folder, not a link, as the engine requires of what it reads.
        var url = home.appendingPathComponent("presented", isDirectory: true)
        for step in [String(conversation), "pages"] {
            try folder(url)
            url = url.appendingPathComponent(step, isDirectory: true)
        }
        try folder(url)
        let file = url.appendingPathComponent("\(sha256).json")
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw EngineError(message: "The page's list of files is not there.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= largest,
              let data = try handle.read(upToCount: largest + 1), data.count <= largest else {
            throw EngineError(message: "The page's list of files cannot be read.")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256 else { throw EngineError(message: "The page's list of files has changed on disk since it was kept, so it is not drawn.") }
        return data
    }

    /// The manifest's entry and files. A file whose path or size cannot be read is left out, and so is a 404.
    static func page(from data: Data) throws -> PresentedPage {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let entry = object["entry"] as? String,
              let files = object["files"] as? [String: Any], files[entry] != nil else {
            throw EngineError(message: "The page's list of files cannot be read.")
        }
        let listed = files.compactMap { path, value -> PresentedFile? in
            guard let file = value as? [String: Any], let size = (file["bytes"] as? NSNumber)?.intValue, size >= 0,
                  let type = file["type"] as? String else { return nil }
            return PresentedFile(path: path, size: size, mimeType: type)
        }
        return PresentedPage(entry: entry, files: listed.sorted { $0.path < $1.path })
    }

    private static func folder(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw EngineError(message: "The presented files of this conversation are not there.")
        }
    }
}
