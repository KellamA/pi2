import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A shared photo made ready to go with a message: drawn afresh (which leaves behind where and with what it was taken),
/// at most 2,000 pixels on its longer side and under the engine's 5 MB, as the conversation's composer and the Mac's
/// `AttachmentReader` prepare one.
struct SharePicture: Equatable, Sendable {
    let name: String
    let data: Data
    let mimeType: String
    let width: Int
    let height: Int
    /// A small PNG, for the page.
    let thumbnail: Data
}

/// Turns a photo's bytes into a picture a message can carry. Run off the main thread: a large photo takes a moment.
///
/// The same steps as the composer's `ConversationPictureReader` (`Conversation/`, #687), which the share extension
/// cannot build, with one more: a byte budget below the engine's 5 MB, for a share with more than one picture to fit
/// the phone's line. The two should become one, in a folder both build.
enum SharePictureReader {
    /// The most bytes one picture may take: a little under the engine's limit.
    static let budget = ShareLimits.pictureBytes - 64 * 1024

    static func prepare(_ data: Data, name: String, budget: Int = budget) throws -> SharePicture {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            throw ShareError("“\(name)” could not be read as a picture.")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: ShareLimits.pictureSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ShareError("“\(name)” could not be read as a picture.")
        }
        return try prepare(image, name: name, budget: min(budget, Self.budget))
    }

    static func prepare(_ image: CGImage, name: String, budget: Int = budget) throws -> SharePicture {
        let failed = ShareError("“\(name)” could not be made small enough to send.")
        let side = max(image.width, image.height)
        let scale = side > ShareLimits.pictureSide ? CGFloat(ShareLimits.pictureSide) / CGFloat(side) : 1
        guard var flat = draw(image, scale: scale) else { throw failed }
        // Small pictures (a screenshot's text) stay sharp as PNG; photos go as JPEG.
        if flat.width * flat.height <= 640_000, let png = encode(flat, as: .png), png.count <= budget {
            return picture(flat, name: name, data: png, mimeType: "image/png")
        }
        for _ in 0..<8 {
            for quality in [0.85, 0.7, 0.5] {
                if let jpeg = encode(flat, as: .jpeg, quality: quality), jpeg.count <= budget {
                    return picture(flat, name: name, data: jpeg, mimeType: "image/jpeg")
                }
            }
            guard let smaller = draw(flat, scale: 0.7) else { break }
            flat = smaller
        }
        throw failed
    }

    private static func picture(_ image: CGImage, name: String, data: Data, mimeType: String) -> SharePicture {
        SharePicture(name: name, data: data, mimeType: mimeType, width: image.width, height: image.height, thumbnail: thumbnail(image))
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
        let side = 240
        let scale = min(1, CGFloat(side) / CGFloat(max(image.width, image.height)))
        guard let small = draw(image, scale: scale) else { return Data() }
        return encode(small, as: .png) ?? Data()
    }
}
