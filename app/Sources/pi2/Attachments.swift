import AppKit
import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// Pictures and files sent with a message: turning a file into something a message can carry, the chips in the
// composer, the ways in (paste, drop, the paperclip), and how a sent message shows what it carried.

// MARK: - What a message can carry

/// The engine's limits on a message's attachments. They are checked here first, so a file that cannot go says so on
/// its chip instead of when the message is sent.
enum AttachmentLimits {
    static let count = 10
    static let imageBytes = 5 * 1024 * 1024
    /// Pictures are scaled down until their longer side is at most this many pixels.
    static let imageSide = 2000
    /// Counted as the engine counts them, in UTF-16 units.
    static let textCharacters = 400_000
    static let totalTextCharacters = 1_500_000
    /// A paste longer than either of these becomes an attachment instead of flooding the text field.
    static let pastedCharacters = 4_000
    static let pastedLines = 60
    /// A PDF with no text in it is attached as pictures of this many of its first pages.
    static let scannedPages = 5
}

/// What the engine keeps about an attachment of a sent message.
struct AttachmentNote: Codable, Equatable {
    let name: String
    /// "image" or "text".
    let kind: String
    /// In bytes.
    let size: Int
}

enum AttachmentContent: Equatable, Sendable {
    case image(data: Data, mimeType: String)
    case text(String)
}

/// A file or picture turned into what a message can carry.
struct PreparedAttachment: Sendable {
    let name: String
    let content: AttachmentContent
    /// A small PNG of a picture, for its chip.
    var thumbnail: Data?
}

/// Why something could not be attached, in words for its chip. The chip shows the name, so the message leaves it out.
struct AttachmentError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }

    static func tooLong(_ characters: Int) -> AttachmentError {
        AttachmentError("Too long: it has \(characters.formatted()) characters, and an attached text can have at most \(AttachmentLimits.textCharacters.formatted()). Attach a shorter part of it.")
    }
}

// MARK: - Reading files

/// Turns files and pasted data into attachments. Nothing here touches the interface, and it is run off the main
/// thread: reading a long PDF or scaling a large photo takes a moment.
enum AttachmentReader {
    /// Word, OpenDocument and web pages, which AppKit can read the text out of.
    private static let documentTypes = ["org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc", "org.oasis-open.opendocument.text"].compactMap { UTType($0) }

    /// One file as attachments: usually one, but a scanned PDF becomes a picture for each of its first pages.
    static func read(_ url: URL) throws -> [PreparedAttachment] {
        let name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey, .isPackageKey])
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
        if let type {
            // Before the folder check: an RTFD document is a folder.
            if type.conforms(to: .rtf) || type.conforms(to: .rtfd) || documentTypes.contains(where: { type.conforms(to: $0) }) {
                return [try document(url, name: name, usesWebKit: false)]
            }
            if type.conforms(to: .html) || type.conforms(to: .webArchive) { return [try document(url, name: name, usesWebKit: true)] }
        }
        if values?.isDirectory == true {
            if values?.isPackage == true { throw unsupported(type) }
            throw AttachmentError("Folders cannot be attached. Attach the files inside it.")
        }
        if let type {
            if type.conforms(to: .pdf) { return try pdf(url, name: name) }
            // An SVG is a picture written as text, and no model takes it as a picture; it goes as its text.
            if type.conforms(to: .image), !type.conforms(to: .svg) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw AttachmentError("This picture could not be read.") }
                return [try picture(source, name: name)]
            }
        }
        return [try plainText(url, name: name, type: type)]
    }

    /// Text that was pasted, too long for the text field.
    static func pasted(_ text: String, name: String) throws -> PreparedAttachment {
        let characters = text.utf16.count
        if characters > AttachmentLimits.textCharacters { throw AttachmentError.tooLong(characters) }
        return PreparedAttachment(name: name, content: .text(text))
    }

    /// A picture from its encoded bytes, as the pasteboard or a drag gives it.
    static func picture(data: Data, name: String) throws -> PreparedAttachment {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw AttachmentError("This picture could not be read.") }
        return try picture(source, name: name)
    }

    // MARK: Text

    private static func plainText(_ url: URL, name: String, type: UTType?) throws -> PreparedAttachment {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw AttachmentError("This file could not be opened.") }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 8192)) ?? Data()
        // UTF-16 text is full of zero bytes too, but says what it is in its first two.
        let utf16 = head.starts(with: [0xFF, 0xFE]) || head.starts(with: [0xFE, 0xFF])
        // A zero byte means it is not text: an archive, a spreadsheet, audio, a program.
        if !utf16, head.contains(0) { throw unsupported(type) }
        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
        // A character takes at most four bytes, so a file this large is over the limit whatever is in it.
        if size > AttachmentLimits.textCharacters * 4 {
            let large = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            throw AttachmentError("Too long: this file is \(large), and an attached text can have at most \(AttachmentLimits.textCharacters.formatted()) characters. Attach a shorter part of it.")
        }
        guard let data = try? Data(contentsOf: url) else { throw AttachmentError("This file could not be read.") }
        if !utf16, data.contains(0) { throw unsupported(type) }
        guard var text = decode(data, utf16: utf16) else { throw AttachmentError("This file is not text in an encoding pi² can read. Save it as UTF-8 and attach it again.") }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw AttachmentError("This file is empty.") }
        if text.utf16.count > AttachmentLimits.textCharacters { throw AttachmentError.tooLong(text.utf16.count) }
        return PreparedAttachment(name: name, content: .text(text))
    }

    /// UTF-8 unless the file says otherwise; older files in a one-byte encoding are read as what they most likely are.
    private static func decode(_ data: Data, utf16: Bool) -> String? {
        if utf16 { return String(data: data, encoding: .utf16) }
        if let text = String(data: data, encoding: .utf8) { return text }
        var converted: NSString?
        let guessed = NSString.stringEncoding(for: data, encodingOptions: [.allowLossyKey: false], convertedString: &converted, usedLossyConversion: nil)
        return guessed == 0 ? nil : converted as String?
    }

    private static func document(_ url: URL, name: String, usesWebKit: Bool) throws -> PreparedAttachment {
        let raw: String
        do {
            // AppKit reads web pages with WebKit, which only works on the main thread; everything else is read here.
            if usesWebKit, !Thread.isMainThread {
                raw = try DispatchQueue.main.sync { try NSAttributedString(url: url, options: [:], documentAttributes: nil).string }
            } else {
                raw = try NSAttributedString(url: url, options: [:], documentAttributes: nil).string
            }
        } catch {
            throw AttachmentError("This document could not be read: \(error.localizedDescription)")
        }
        // Pictures inside the document leave a placeholder character behind.
        let text = raw.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw AttachmentError("This document has no text in it.") }
        if text.utf16.count > AttachmentLimits.textCharacters { throw AttachmentError.tooLong(text.utf16.count) }
        return PreparedAttachment(name: name, content: .text(text))
    }

    private static func unsupported(_ type: UTType?) -> AttachmentError {
        // "data" is what macOS calls a file it knows nothing about, which says nothing.
        let known = type.flatMap { $0.isDynamic || $0 == .data || $0 == .item ? nil : $0.localizedDescription }
        let kind = known.map { " (\($0))" } ?? ""
        let advice: String
        if let type, type.conforms(to: .spreadsheet) {
            advice = "Export it as CSV or PDF and attach that."
        } else if let type, type.conforms(to: .presentation) || type.identifier.hasPrefix("com.apple.iwork") {
            advice = "Export it as PDF and attach that."
        } else if let type, type.conforms(to: .archive) {
            advice = "Attach the files inside it."
        } else {
            advice = "pi² can take pictures, PDFs, Word documents and text files."
        }
        return AttachmentError("This kind of file\(kind) cannot be attached yet. \(advice)")
    }

    // MARK: PDF

    private static func pdf(_ url: URL, name: String) throws -> [PreparedAttachment] {
        guard let document = PDFDocument(url: url) else { throw AttachmentError("This PDF could not be opened.") }
        if document.isLocked { throw AttachmentError("This PDF is protected with a password. Save a copy without the password and attach that.") }
        guard document.pageCount > 0 else { throw AttachmentError("This PDF has no pages.") }
        var pages: [String] = []
        var characters = 0
        var letters = 0
        for index in 0..<document.pageCount {
            let text = (document.page(at: index)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            // Page numbers let the model say where in the document something is.
            let page = document.pageCount > 1 ? "[Page \(index + 1)]\n\(text)" : text
            characters += page.utf16.count + 2
            if characters > AttachmentLimits.textCharacters {
                throw AttachmentError("Too long: its text is over \(AttachmentLimits.textCharacters.formatted()) characters, the most an attached text can have. Attach a part of it.")
            }
            if letters < 20 { letters += text.unicodeScalars.count(where: { !$0.properties.isWhitespace }) }
            pages.append(page)
        }
        if letters >= 20 { return [PreparedAttachment(name: name, content: .text(pages.joined(separator: "\n\n")))] }
        // No text to speak of: a scan, or pages that are pictures. The model can still read those as pictures.
        let count = min(document.pageCount, AttachmentLimits.scannedPages)
        return try (0..<count).map { index in
            guard let page = document.page(at: index), let image = render(page) else {
                throw AttachmentError("This PDF has no text in it, and its pages could not be turned into pictures.")
            }
            return try picture(image, name: document.pageCount == 1 ? name : "\(name), page \(index + 1) of \(document.pageCount)")
        }
    }

    /// A page as a picture, about as large as a picture may be so that small print stays readable.
    private static func render(_ page: PDFPage) -> CGImage? {
        let box = page.bounds(for: .cropBox)
        let turned = page.rotation % 180 != 0
        let size = turned ? CGSize(width: box.height, height: box.width) : box.size
        guard size.width >= 1, size.height >= 1 else { return nil }
        let scale = CGFloat(AttachmentLimits.imageSide) / max(size.width, size.height)
        let width = max(1, Int((size.width * scale).rounded())), height = max(1, Int((size.height * scale).rounded()))
        guard let context = bitmap(width: width, height: height, opaque: true) else { return nil }
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }

    // MARK: Pictures

    private static func picture(_ source: CGImageSource, name: String) throws -> PreparedAttachment {
        // Decoded at the size it will be sent at, turned the way its metadata says it should be seen.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: AttachmentLimits.imageSide,
        ]
        guard CGImageSourceGetCount(source) > 0, let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw AttachmentError("This picture could not be read.")
        }
        return try picture(image, name: name)
    }

    /// Encode a picture for sending: PNG when part of it is see-through or it is small (sharp edges and small text
    /// survive), JPEG otherwise. Always drawn afresh, which also leaves behind whatever the file said about where and
    /// with what it was taken.
    private static func picture(_ image: CGImage, name: String) throws -> PreparedAttachment {
        let failed = AttachmentError("This picture could not be prepared for sending.")
        let side = max(image.width, image.height)
        let scale = side > AttachmentLimits.imageSide ? CGFloat(AttachmentLimits.imageSide) / CGFloat(side) : 1
        // A little under the engine's limit.
        let budget = AttachmentLimits.imageBytes - 64 * 1024
        let hasAlpha = ![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        if hasAlpha, let context = draw(image, scale: scale, opaque: false), isSeeThrough(context), let kept = context.makeImage(),
           let png = encode(kept, as: .png), png.count <= budget {
            return PreparedAttachment(name: name, content: .image(data: png, mimeType: "image/png"), thumbnail: thumbnail(kept))
        }
        guard var flat = draw(image, scale: scale, opaque: true)?.makeImage() else { throw failed }
        if flat.width * flat.height <= 640_000, let png = encode(flat, as: .png), png.count <= budget {
            return PreparedAttachment(name: name, content: .image(data: png, mimeType: "image/png"), thumbnail: thumbnail(flat))
        }
        // At this size the first try all but always fits; the rest is for the picture that does not.
        for _ in 0..<6 {
            for quality in [0.85, 0.7, 0.5] {
                if let jpeg = encode(flat, as: .jpeg, quality: quality), jpeg.count <= budget {
                    return PreparedAttachment(name: name, content: .image(data: jpeg, mimeType: "image/jpeg"), thumbnail: thumbnail(flat))
                }
            }
            guard let smaller = draw(flat, scale: 0.7, opaque: true)?.makeImage() else { break }
            flat = smaller
        }
        throw failed
    }

    private static func bitmap(width: Int, height: Int, opaque: Bool) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue)
        else { return nil }
        if opaque {
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.interpolationQuality = .high
        return context
    }

    /// The picture as plain 8-bit sRGB whatever it came as, on white when `opaque`.
    private static func draw(_ image: CGImage, scale: CGFloat, opaque: Bool) -> CGContext? {
        let width = max(1, Int((CGFloat(image.width) * scale).rounded())), height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = bitmap(width: width, height: height, opaque: opaque) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }

    /// Whether any pixel lets what is behind it show. Many pictures have room for that and never use it.
    private static func isSeeThrough(_ context: CGContext) -> Bool {
        guard let data = context.data else { return false }
        let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * context.height)
        for row in 0..<context.height {
            var offset = row * context.bytesPerRow + 3
            for _ in 0..<context.width {
                if bytes[offset] != 255 { return true }
                offset += 4
            }
        }
        return false
    }

    private static func encode(_ image: CGImage, as type: UTType, quality: Double? = nil) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let properties: [CFString: Any] = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] } ?? [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func thumbnail(_ image: CGImage) -> Data? {
        let scale = min(1, 192 / CGFloat(max(image.width, image.height)))
        return draw(image, scale: scale, opaque: false)?.makeImage().flatMap { encode($0, as: .png) }
    }
}

// MARK: - The composer's attachments

/// The pictures and files waiting to go with the message being written.
@MainActor
@Observable
final class ComposerAttachments {
    struct Draft: Identifiable {
        enum State {
            case reading
            case ready(AttachmentContent)
            /// It could not be used, and why.
            case failed(String)
        }

        let id: UUID
        var name: String
        var state: State
        var thumbnail: NSImage?

        var content: AttachmentContent? {
            if case .ready(let content) = state { return content }
            return nil
        }
        var isPicture: Bool {
            if case .image = content { return true }
            return false
        }
        /// The size of what will be sent, in bytes.
        var size: Int {
            switch content {
            case .image(let data, _): data.count
            case .text(let text): text.utf8.count
            case nil: 0
            }
        }
        /// As the engine's `submit` takes it; nil until it is ready.
        var payload: [String: Any]? {
            switch content {
            case .image(let data, let mimeType): ["kind": "image", "name": name, "mimeType": mimeType, "data": data.base64EncodedString()]
            case .text(let text): ["kind": "text", "name": name, "text": text]
            case nil: nil
            }
        }
    }

    private(set) var items: [Draft] = []

    var isEmpty: Bool { items.isEmpty }
    var isReading: Bool {
        items.contains { item in
            if case .reading = item.state { return true }
            return false
        }
    }
    var ready: [Draft] { items.filter { $0.content != nil } }

    /// Why the message cannot go as it stands, for the person to read; nil when it can.
    /// `blindModel` is the conversation's model when it is known not to take pictures.
    func problem(blindModel: String?) -> String? {
        let ready = ready
        if let blindModel, ready.contains(where: \.isPicture) { return "\(blindModel) cannot see pictures. Choose a model that can, or remove them." }
        if ready.count > AttachmentLimits.count {
            return "A message can carry at most \(AttachmentLimits.count) attachments. Remove \(ready.count - AttachmentLimits.count) to send it."
        }
        let characters = ready.reduce(0) { total, item in
            if case .text(let text) = item.content { return total + text.utf16.count }
            return total
        }
        if characters > AttachmentLimits.totalTextCharacters {
            return "The attached texts add up to \(characters.formatted()) characters, and a message can carry at most \(AttachmentLimits.totalTextCharacters.formatted()). Remove some to send it."
        }
        return nil
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    /// Hands over what is ready to send and empties the composer. Anything that could not be used goes too: its chip
    /// said so, and the message goes without it.
    func takeReady() -> [Draft] {
        let taken = ready
        items = []
        return taken
    }

    /// Puts back what a refused message carried.
    func restore(_ drafts: [Draft]) {
        items.insert(contentsOf: drafts, at: 0)
    }

    // MARK: Ways in

    func add(files urls: [URL]) {
        for url in urls {
            read(named: url.lastPathComponent) { try AttachmentReader.read(url) }
        }
    }

    func add(picture data: Data, name: String) {
        read(named: name) { [try AttachmentReader.picture(data: data, name: name)] }
    }

    func add(pastedText text: String) {
        let earlier = items.count { $0.name.hasPrefix("Pasted text") }
        let name = earlier == 0 ? "Pasted text" : "Pasted text \(earlier + 1)"
        read(named: name) { [try AttachmentReader.pasted(text, name: name)] }
    }

    /// Shows a chip at once and fills it in when the work, done off the main thread, is finished.
    private func read(named name: String, _ work: @escaping @Sendable () throws -> [PreparedAttachment]) {
        let id = UUID()
        items.append(Draft(id: id, name: name, state: .reading))
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try work() } }.value
            // Removed while it was being read: nothing to fill in.
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            switch result {
            case .failure(let error):
                items[index].state = .failed(error.localizedDescription)
            case .success(let prepared):
                let drafts = prepared.enumerated().map { offset, one in
                    Draft(id: offset == 0 ? id : UUID(), name: one.name, state: .ready(one.content), thumbnail: one.thumbnail.flatMap { NSImage(data: $0) })
                }
                items.replaceSubrange(index...index, with: drafts)
            }
        }
    }

    /// The paperclip: pick files to attach.
    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        panel.message = "Choose pictures or files to send with your message."
        if panel.runModal() == .OK { add(files: panel.urls) }
    }

    /// Files or pictures dropped on the conversation.
    func add(dropped providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in self.add(files: [url]) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                // A picture dragged out of a web page or another app, with no file behind it.
                let name = provider.suggestedName ?? "Dropped picture"
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in self.add(picture: data, name: name) }
                }
            }
        }
    }

    /// ⌘V in the composer. Takes copied files, a copied picture, or a very long text as attachments and says so;
    /// returns false for ordinary text, which the text field then pastes itself.
    func paste(from pasteboard: NSPasteboard = .general) -> Bool {
        // Files copied in Finder. Checked first: Finder also puts their names on the pasteboard as text.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            add(files: urls)
            return true
        }
        let text = pasteboard.string(forType: .string) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A copied picture. Text that comes with a picture of itself (cells of a spreadsheet, styled text) is pasted
        // as text; a web address beside a picture is where a browser says the picture came from.
        let isAddress = !trimmed.isEmpty && !trimmed.contains(where: \.isWhitespace) && URL(string: trimmed)?.scheme != nil
        if trimmed.isEmpty || isAddress, let picture = Self.picture(on: pasteboard) {
            let earlier = items.count { $0.name.hasPrefix("Pasted picture") }
            add(picture: picture, name: earlier == 0 ? "Pasted picture" : "Pasted picture \(earlier + 1)")
            return true
        }
        let lines = text.utf8.count { $0 == 0x0A } + 1
        if text.utf16.count > AttachmentLimits.pastedCharacters || lines > AttachmentLimits.pastedLines {
            add(pastedText: text)
            return true
        }
        return false
    }

    /// A picture on the pasteboard, as the bytes of whichever form of it is there.
    private static func picture(on pasteboard: NSPasteboard) -> Data? {
        let types = [NSPasteboard.PasteboardType.png, .init("public.jpeg"), .tiff, .init("public.heic"), .init("com.compuserve.gif"), .init("org.webmproject.webp")]
        if let type = pasteboard.availableType(from: types), let data = pasteboard.data(forType: type) { return data }
        // Anything else AppKit can draw, such as a copied piece of a PDF.
        if NSImage.canInit(with: pasteboard), let image = NSImage(pasteboard: pasteboard) { return image.tiffRepresentation }
        return nil
    }
}

extension QueuedInput {
    /// One line for a message waiting in the queue: what was typed, or what it carries when nothing was.
    var summary: String {
        let carried = attachments ?? []
        if carried.isEmpty { return text }
        let names = carried.count == 1 ? carried[0].name : "\(carried.count) attachments"
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? names : "\(text) · \(names)"
    }
}

// MARK: - Chips

/// A file's chip: an icon, its name, and a line under it (its size, or why it could not be used).
struct FileChip<Trailing: View>: View {
    let name: String
    let detail: String
    var failed = false
    var reading = false
    @ViewBuilder var trailing: Trailing

    private var icon: String {
        if name.hasPrefix("Pasted text") { return "doc.on.clipboard" }
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "tif", "bmp": return "photo"
        default: return "doc.text"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if reading { Spinner() } else { Image(systemName: failed ? "exclamationmark.triangle" : icon) }
            }
            .font(.system(size: 14))
            .foregroundStyle(failed ? Theme.bad : Theme.acc)
            .frame(width: 18)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.tx).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.system(size: 11)).foregroundStyle(failed ? Theme.bad : Theme.tx3).lineLimit(failed ? 3 : 1)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: failed ? 260 : 200, alignment: .leading)
            .accessibilityElement(children: .combine)
            trailing
        }
        .padding(.leading, 9).padding(.trailing, 7).padding(.vertical, 6)
        .panel(radius: 8, fill: Theme.card, border: failed ? Theme.bad.opacity(0.45) : Theme.line2)
        .help(failed ? "\(name): \(detail)" : name)
    }
}

extension FileChip where Trailing == EmptyView {
    init(name: String, detail: String) {
        self.init(name: name, detail: detail) { EmptyView() }
    }
}

enum AttachmentFormat {
    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// One attachment in the composer, with the way to take it out again.
private struct DraftChip: View {
    let item: ComposerAttachments.Draft
    /// The conversation's model, when it cannot see pictures.
    let blindModel: String?
    let remove: () -> Void

    private var removeButton: some View {
        Button("Remove", systemImage: "xmark", action: remove)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.tx3)
            .help("Remove \(item.name)")
            .accessibilityLabel("Remove \(item.name)")
    }

    var body: some View {
        switch item.state {
        case .reading:
            FileChip(name: item.name, detail: "Reading…", reading: true) { removeButton }
        case .failed(let why):
            FileChip(name: item.name, detail: why, failed: true) { removeButton }
        case .ready(.text):
            FileChip(name: item.name, detail: AttachmentFormat.size(item.size)) { removeButton }
        case .ready(.image):
            picture
        }
    }

    private var picture: some View {
        let unseen = blindModel != nil
        return HStack(spacing: 6) {
            Group {
                if let thumbnail = item.thumbnail {
                    Image(nsImage: thumbnail).resizable().interpolation(.high).scaledToFill()
                } else {
                    Image(systemName: "photo").foregroundStyle(Theme.tx3)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(.rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(unseen ? Theme.warn.opacity(0.8) : Theme.line2))
            .overlay(alignment: .bottomTrailing) {
                if unseen {
                    Image(systemName: "eye.slash.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.warn)
                        .padding(2.5)
                        .background(Theme.panel, in: .circle)
                        .padding(1.5)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(unseen ? "Picture \(item.name). \(blindModel ?? "This model") cannot see pictures." : "Picture \(item.name), \(AttachmentFormat.size(item.size))")
            removeButton
        }
        .padding(.leading, 4).padding(.trailing, 7).padding(.vertical, 4)
        .panel(radius: 8, fill: Theme.card, border: unseen ? Theme.warn.opacity(0.45) : Theme.line2)
        .help(unseen ? "\(item.name): \(blindModel ?? "This model") cannot see pictures." : "\(item.name) · \(AttachmentFormat.size(item.size))")
    }
}

/// The row of chips above the composer's text field, with a line under it when the message cannot go as it stands.
struct AttachmentStrip: View {
    let attachments: ComposerAttachments
    let blindModel: String?

    var body: some View {
        if !attachments.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                FlowLayout(spacing: 6) {
                    ForEach(attachments.items) { item in
                        DraftChip(item: item, blindModel: blindModel) { attachments.remove(item.id) }
                    }
                }
                if let problem = attachments.problem(blindModel: blindModel) {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Attachments")
        }
    }
}

/// What a sent message carried: its pictures, which are fetched when they are shown, and its files.
struct SentAttachments: View {
    let engine: EngineClient
    let conversationID: Int
    let item: Item

    var body: some View {
        let notes = item.attachments ?? []
        let pictures = item.images ?? 0
        let pictureNames = notes.filter { $0.kind == "image" }.map(\.name)
        let files = notes.filter { $0.kind != "image" }
        if pictures > 0 {
            FlowLayout(spacing: 6, trailing: true) {
                ForEach(0..<pictures, id: \.self) { index in
                    let name = index < pictureNames.count ? pictureNames[index] : "Picture \(index + 1)"
                    ScreenshotView(engine: engine, conversationID: conversationID, entryID: item.id, index: index, caption: name, label: "Picture you attached: \(name)", thumbnailHeight: 96)
                }
            }
        }
        if !files.isEmpty {
            FlowLayout(spacing: 6, trailing: true) {
                ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                    FileChip(name: file.name, detail: AttachmentFormat.size(file.size))
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Attached file \(file.name), \(AttachmentFormat.size(file.size))")
                }
            }
        }
    }
}

/// Shown over the conversation while something that can be attached is dragged across it.
struct DropHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(Theme.acc.opacity(0.10))
            .strokeBorder(Theme.acc, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            .overlay {
                Label("Drop to attach", systemImage: "paperclip")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.acc)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Theme.panel, in: .capsule)
            }
            .padding(10)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Paste

/// Lets the composer take pictures and files off the pasteboard on ⌘V. A text field pastes only text and takes the
/// key for itself, so this looks at the pasteboard first, and lets the key through whenever there is nothing to
/// attach: ordinary pasting, undo and everything else about editing text stay the text field's own.
///
/// It also keeps a file dropped on the text itself from being typed in as its path: see `dragging`.
struct PasteCatcher: NSViewRepresentable {
    /// Whether the composer has the keyboard.
    let active: Bool
    /// Whether files or pictures are being dragged over the conversation.
    var dragging = false
    /// Attaches what is on the pasteboard if it is something to attach, and says whether it did.
    let paste: () -> Bool

    func makeNSView(context: Context) -> Catcher { Catcher() }

    func updateNSView(_ view: Catcher, context: Context) {
        view.active = active
        view.paste = paste
        view.dragging = dragging
    }

    static func dismantleNSView(_ view: Catcher, coordinator: ()) {
        view.stopWatching()
    }

    /// Sits behind the text field, in its place.
    final class Catcher: NSView {
        var active = false
        var paste: () -> Bool = { false }
        /// The text field's own editor takes drags too, and would take a file dropped on the text and insert its
        /// path, where a drop anywhere else on the conversation attaches it. So while files or pictures are being
        /// dragged over the conversation the editor is told to take no drags, and the drop reaches the conversation.
        /// Dragging text into the field is not affected: that is not a drag the conversation takes.
        var dragging = false {
            didSet {
                guard dragging != oldValue else { return }
                if dragging { suspendEditorDrops() } else { resumeEditorDrops() }
            }
        }
        private var monitor: Any?
        private var suspended: [(editor: NSTextView, types: [NSPasteboard.PasteboardType])] = []

        // Watching only while in a window ties the monitor to the conversation that is on screen.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stopWatching() } else { startWatching() }
        }

        private func suspendEditorDrops() {
            guard let root = window?.contentView else { return }
            let place = convert(bounds, to: nil)
            var editors: [NSTextView] = []
            func find(in view: NSView) {
                if let editor = view as? NSTextView, editor.isFieldEditor, editor.convert(editor.bounds, to: nil).intersects(place) { editors.append(editor) }
                for child in view.subviews { find(in: child) }
            }
            find(in: root)
            for editor in editors where !editor.registeredDraggedTypes.isEmpty {
                suspended.append((editor, editor.registeredDraggedTypes))
                editor.unregisterDraggedTypes()
            }
        }

        private func resumeEditorDrops() {
            for (editor, types) in suspended { editor.registerForDraggedTypes(types) }
            suspended = []
        }

        private func startWatching() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
                let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
                // ⌘V by its letter, or by the key's place on a layout whose letters are not Latin.
                let isV = key == "v" || (event.keyCode == 9 && !(key.unicodeScalars.first?.isASCII ?? false))
                guard modifiers == .command, isV else { return event }
                let windowNumber = event.windowNumber
                let taken = MainActor.assumeIsolated { self?.take(inWindow: windowNumber) ?? false }
                return taken ? nil : event
            }
        }

        func stopWatching() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            resumeEditorDrops()
        }

        /// Only for a key typed in this view's own window, while it is the one being typed in and the composer has
        /// the keyboard: a paste into a sheet, Settings or Quick Ask is none of the composer's business.
        private func take(inWindow windowNumber: Int) -> Bool {
            guard active, let window, window.windowNumber == windowNumber, window.isKeyWindow, window.attachedSheet == nil else { return false }
            return paste()
        }
    }
}

// MARK: - Layout

/// Lays its children out in rows, starting a new row when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    /// Rows hug the trailing edge, as a sent message does.
    var trailing = false

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(in width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, subview) in subviews.enumerated() {
            // The width it would like, held to the row's; then its height at that width, since text in it may wrap.
            let wanted = min(subview.sizeThatFits(.unspecified).width, width)
            var size = subview.sizeThatFits(ProposedViewSize(width: wanted, height: nil))
            size.width = min(size.width, width)
            if !row.items.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append((index, size))
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(in: proposal.width ?? .infinity, subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(in: bounds.width, subviews) {
            var x = trailing ? bounds.maxX - row.width : bounds.minX
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
    }
}
