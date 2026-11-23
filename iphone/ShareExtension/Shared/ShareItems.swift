import Foundation
import PDFKit
import UIKit
import UniformTypeIdentifiers

/// One shared item as it was read, before its picture is scaled: what `ShareItemLoader` makes of an `NSItemProvider`.
enum ShareRaw: Equatable, Sendable {
    /// A web page's address (Safari's share), with the page's title when the app gave one.
    case link(URL, title: String?)
    /// Text shared as text (a selection, a note).
    case text(String)
    /// A photo's bytes, as the app gave them.
    case picture(name: String, data: Data)
    /// A file's text: a text file, or the text of a PDF.
    case file(name: String, text: String)
    /// What could not be read, in the person's words.
    case problem(String)
}

/// What was shared, ready to go: links and texts as they are, pictures scaled (`SharePictureReader`), and what could not
/// be read, each in a line of its own on the page.
struct ShareContent: Equatable, Sendable {
    enum Piece: Equatable, Sendable {
        case link(URL, title: String?)
        case text(String)
        case picture(SharePicture)
        case file(name: String, text: String)
        case problem(String)
    }

    var pieces: [Piece]

    /// Whether anything can be sent.
    var hasContent: Bool {
        pieces.contains { if case .problem = $0 { false } else { true } }
    }

    var problems: [String] {
        pieces.compactMap { if case .problem(let why) = $0 { why } else { nil } }
    }

    /// The pieces ready: each picture prepared within its share of the phone's line. Run off the main thread.
    static func prepare(_ raw: [ShareRaw]) -> ShareContent {
        let pictures = raw.filter { if case .picture = $0 { true } else { false } }.count
        let texts = raw.reduce(0) { total, piece in
            switch piece {
            case .text(let text), .file(_, let text): total + text.utf8.count
            default: total
            }
        }
        // Base64 makes a picture a third larger on the line; what is left after the texts is shared out between them.
        let left = max(0, ShareLimits.messageBytes - texts - 64 * 1024)
        let budget = pictures == 0 ? SharePictureReader.budget : min(SharePictureReader.budget, left / pictures * 3 / 4)
        var attachments = 0
        var pieces: [Piece] = []
        for piece in raw {
            let attaches: Bool
            switch piece {
            case .picture, .file: attaches = true
            case .text(let text): attaches = !ShareMessage.inline(text)
            case .link, .problem: attaches = false
            }
            if attaches {
                attachments += 1
                if attachments > ShareLimits.attachments {
                    pieces.append(.problem("A message carries at most \(ShareLimits.attachments) attachments; the rest were left out."))
                    continue
                }
            }
            switch piece {
            case .link(let url, let title): pieces.append(.link(url, title: title))
            case .text(let text): pieces.append(.text(text))
            case .file(let name, let text): pieces.append(.file(name: name, text: text))
            case .problem(let why): pieces.append(.problem(why))
            case .picture(let name, let data):
                do {
                    pieces.append(.picture(try SharePictureReader.prepare(data, name: name, budget: budget)))
                } catch {
                    pieces.append(.problem(error.localizedDescription))
                }
            }
        }
        // Said once, however many attachments it was.
        var seen = Set<String>()
        pieces = pieces.filter { if case .problem(let why) = $0 { seen.insert(why).inserted } else { true } }
        return ShareContent(pieces: pieces)
    }
}

/// Reads what another app shared (the extension context's items) into `ShareRaw`: a link, text, a photo, or a file,
/// the kinds the extension's activation rule offers pi² for (`Info.plist`). A video or a sound is refused, and so is a
/// file that is neither a picture, a PDF with text, nor text.
@MainActor
enum ShareItemLoader {
    /// The most bytes read of a photo as shared, before it is scaled; a larger one is refused before it is read.
    static let largestPhoto = 100 * 1024 * 1024
    static let largestPDF = 50 * 1024 * 1024
    /// A text file larger than this cannot hold under 400,000 characters of text worth sending.
    static let largestText = ShareLimits.textCharacters * 4

    static func load(_ items: [NSExtensionItem]) async -> [ShareRaw] {
        var raw: [ShareRaw] = []
        for item in items {
            let title = (item.attributedTitle ?? item.attributedContentText)?.string.trimmingCharacters(in: .whitespacesAndNewlines)
            raw += await load(item.attachments ?? [], title: title?.isEmpty == false ? title : nil)
        }
        return raw
    }

    /// Each provider read in turn; `title` names a link when the item holds one.
    static func load(_ providers: [NSItemProvider], title: String? = nil) async -> [ShareRaw] {
        var raw: [ShareRaw] = []
        for provider in providers {
            var piece = await load(provider)
            if case .link(let url, nil) = piece, let title { piece = .link(url, title: title) }
            // Safari can give the page's address twice, as a link and as text.
            if case .text(let text) = piece, raw.contains(where: { if case .link(let url, _) = $0 { url.absoluteString == text } else { false } }) {
                continue
            }
            raw.append(piece)
        }
        return raw
    }

    static func load(_ provider: NSItemProvider) async -> ShareRaw {
        let types = provider.registeredContentTypes
        let suggested = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = suggested?.isEmpty == false ? suggested : nil
        if types.contains(where: { $0.conforms(to: .audiovisualContent) }) {
            return .problem("pi² does not send videos or sound. Share a photo, a link, text or a file.")
        }
        if let type = types.first(where: { $0.conforms(to: .image) && !$0.conforms(to: .svg) }) {
            do {
                return .picture(name: name ?? "Photo", data: try await contents(of: provider, as: type, atMost: largestPhoto))
            } catch {
                return .problem(error.localizedDescription)
            }
        }
        if types.contains(where: { $0.conforms(to: .fileURL) }) {
            guard let url = await object(URL.self, from: provider), url.isFileURL else {
                return .problem("This file could not be read.")
            }
            return read(file: url)
        }
        if types.contains(where: { $0.conforms(to: .url) }), let url = await object(URL.self, from: provider) {
            return url.isFileURL ? read(file: url) : .link(url, title: nil)
        }
        if name == nil, types.contains(where: { $0.conforms(to: .plainText) }), let text = await object(String.self, from: provider) {
            return checked(text, name: nil)
        }
        guard let type = types.first(where: { $0.conforms(to: .data) || $0.conforms(to: .content) }) ?? types.first else {
            return .problem("What was shared could not be read.")
        }
        let limit = type.conforms(to: .pdf) ? largestPDF : largestText
        do {
            let data = try await contents(of: provider, as: type, atMost: limit)
            return classify(data, name: name, type: type)
        } catch {
            return .problem(error.localizedDescription)
        }
    }

    // MARK: - What a file holds

    /// A file the app gave by its address.
    static func read(file url: URL) -> ShareRaw {
        let name = url.lastPathComponent
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension)
        let isImage = type.map { $0.conforms(to: .image) && !$0.conforms(to: .svg) } ?? false
        let limit = isImage ? largestPhoto : type?.conforms(to: .pdf) == true ? largestPDF : largestText
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > limit {
            return .problem(tooLarge(name, bytes: size, isText: !isImage && type?.conforms(to: .pdf) != true))
        }
        guard let data = try? Data(contentsOf: url) else { return .problem("“\(name)” could not be read.") }
        return classify(data, name: name, type: type)
    }

    /// The bytes of a file, by what they are: a picture, a PDF's text, or text.
    nonisolated static func classify(_ data: Data, name: String?, type: UTType?) -> ShareRaw {
        let shown = name ?? "The shared file"
        if let type, type.conforms(to: .image), !type.conforms(to: .svg) {
            return .picture(name: name ?? "Photo", data: data)
        }
        if let type, type.conforms(to: .pdf) {
            guard let document = PDFDocument(data: data) else { return .problem("“\(shown)” could not be read as a PDF.") }
            let text = (document.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 20 else {
                return .problem("“\(shown)” has no text pi² can read: it may be a scan. Share its pages as photos instead.")
            }
            return checked(text, name: name ?? "Document.pdf")
        }
        if let type, type.conforms(to: .rtf),
           let text = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string {
            return checked(text, name: name ?? "Document.rtf")
        }
        guard let text = Self.text(data) else {
            return .problem("pi² sends pictures, PDFs and text, and “\(shown)” is none of them.")
        }
        return checked(text, name: name)
    }

    /// Text in UTF-8, or UTF-16 that says so in its first bytes; nil for anything else (zero bytes, which text does not
    /// have, as the Mac's `AttachmentReader` checks).
    nonisolated static func text(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) }
        guard !data.prefix(8192).contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Text, if it is not too long: as text, or as a file's when it has a name.
    nonisolated static func checked(_ text: String, name: String?) -> ShareRaw {
        let characters = text.utf16.count
        guard characters <= ShareLimits.textCharacters else {
            return .problem("“\(name ?? "The shared text")” is too long: it has \(characters.formatted()) characters, and an attached text can have at most \(ShareLimits.textCharacters.formatted()). Share a shorter part of it.")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .problem("“\(name ?? "The shared text")” has no text in it.")
        }
        return name.map { .file(name: $0, text: text) } ?? .text(text)
    }

    nonisolated static func tooLarge(_ name: String, bytes: Int, isText: Bool) -> String {
        let size = bytes.formatted(.byteCount(style: .file))
        return isText
            ? "“\(name)” is too large to send as text (\(size)). Share a shorter part of it."
            : "“\(name)” is too large to read here (\(size))."
    }

    // MARK: - Reading a provider

    private struct TooLarge: Error {
        let bytes: Int
    }

    /// The provider's bytes as `type`, refused above `limit` before they are read when the app gives a file.
    private static func contents(of provider: NSItemProvider, as type: UTType, atMost limit: Int) async throws -> Data {
        let name = provider.suggestedName ?? (type.conforms(to: .image) ? "The photo" : "The shared file")
        do {
            return try await withCheckedThrowingContinuation { continuation in
                _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
                    guard let url else {
                        continuation.resume(throwing: error ?? ShareError("“\(name)” could not be read."))
                        return
                    }
                    if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > limit {
                        continuation.resume(throwing: TooLarge(bytes: size))
                        return
                    }
                    do {
                        continuation.resume(returning: try Data(contentsOf: url))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch let large as TooLarge {
            throw ShareError(tooLarge(name, bytes: large.bytes, isText: !type.conforms(to: .image) && !type.conforms(to: .pdf)))
        } catch {
            // Not every app gives a file: some give the bytes alone.
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                _ = provider.loadDataRepresentation(for: type) { data, error in
                    if let data {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: error ?? ShareError("“\(name)” could not be read."))
                    }
                }
            }
            guard data.count <= limit else {
                throw ShareError(tooLarge(name, bytes: data.count, isText: !type.conforms(to: .image) && !type.conforms(to: .pdf)))
            }
            return data
        }
    }

    private static func object<T: _ObjectiveCBridgeable & Sendable>(_ kind: T.Type, from provider: NSItemProvider) async -> T?
        where T._ObjectiveCType: NSItemProviderReading {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: kind) { object, _ in
                continuation.resume(returning: object)
            }
        }
    }
}
