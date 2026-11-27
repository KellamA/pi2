import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The steps that turn a photo's bytes into a picture a message can carry, shared by the conversation's composer
/// (`ConversationPictureReader`) and the share sheet (`SharePictureReader`): drawn afresh (which leaves behind where
/// and with what it was taken), at most `side` pixels on its longer side and under `budget` bytes, as the Mac's
/// `AttachmentReader` prepares one. Small pictures (a screenshot's text) stay sharp as PNG; photos go as JPEG, made
/// smaller round by round until they fit. Run off the main thread: a large photo takes a moment.
enum PictureReader {
    /// A picture made ready, before its caller's own shape (`ConversationPicture`, `SharePicture`).
    struct Picture: Equatable, Sendable {
        let name: String
        let data: Data
        let mimeType: String
        let width: Int
        let height: Int
        /// A small PNG for its chip.
        let thumbnail: Data
    }

    /// Which step could not be done, for the caller's own error in the person's words.
    enum Failure: Error {
        case unreadable
        case unpreparable
    }

    /// The conversation's present values, the defaults: the engine's limits on a message's picture (the Mac's
    /// `AttachmentLimits`), the budget a little under the engine's 5 MB, six rounds of making it smaller, and a
    /// 160-pixel PNG for its chip.
    enum Conversation {
        static let side = 2000
        static let budget = 5 * 1024 * 1024 - 64 * 1024
        static let rounds = 6
        static let thumbnailSide = 160
    }

    static func prepare(_ data: Data, name: String, side: Int = Conversation.side, budget: Int = Conversation.budget,
                        rounds: Int = Conversation.rounds, thumbnailSide: Int = Conversation.thumbnailSide) throws -> Picture {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            throw Failure.unreadable
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw Failure.unreadable
        }
        return try prepare(image, name: name, side: side, budget: budget, rounds: rounds, thumbnailSide: thumbnailSide)
    }

    static func prepare(_ image: CGImage, name: String, side: Int = Conversation.side, budget: Int = Conversation.budget,
                        rounds: Int = Conversation.rounds, thumbnailSide: Int = Conversation.thumbnailSide) throws -> Picture {
        let longest = max(image.width, image.height)
        let scale = longest > side ? CGFloat(side) / CGFloat(longest) : 1
        guard var flat = draw(image, scale: scale) else { throw Failure.unpreparable }
        if flat.width * flat.height <= 640_000, let png = encode(flat, as: .png), png.count <= budget {
            return Picture(name: name, data: png, mimeType: "image/png", width: flat.width, height: flat.height, thumbnail: thumbnail(flat, side: thumbnailSide))
        }
        for _ in 0..<rounds {
            for quality in [0.85, 0.7, 0.5] {
                if let jpeg = encode(flat, as: .jpeg, quality: quality), jpeg.count <= budget {
                    return Picture(name: name, data: jpeg, mimeType: "image/jpeg", width: flat.width, height: flat.height, thumbnail: thumbnail(flat, side: thumbnailSide))
                }
            }
            guard let smaller = draw(flat, scale: 0.7) else { break }
            flat = smaller
        }
        throw Failure.unpreparable
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

    private static func thumbnail(_ image: CGImage, side: Int) -> Data {
        let scale = min(1, CGFloat(side) / CGFloat(max(image.width, image.height)))
        guard let small = draw(image, scale: scale) else { return Data() }
        return encode(small, as: .png) ?? Data()
    }
}
