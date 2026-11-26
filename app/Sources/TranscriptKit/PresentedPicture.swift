
#if os(macOS)
import AppKit
import ImageIO

/// A presented picture's bytes made into an image, by the kind the engine says it is and only so, and never larger in
/// memory than it is shown (#1001's security read):
///
/// - PNG, JPEG, GIF and WebP by ImageIO, and only when ImageIO reads the bytes as that very kind
///   (`CGImageSourceGetType`): a BMP said to be a GIF, an SVG said to be a PNG, a PDF said to be a JPEG make nothing.
/// - An SVG by AppKit's SVG representation alone (`_NSSVGImageRep`, CoreSVG), which draws shapes and runs nothing; only
///   when its first byte is `<` and that is the one representation `NSImage` made.
/// - A thumbnail (the strip, the card under Needs you) is made by ImageIO at the size it is drawn
///   (`CGImageSourceCreateThumbnailAtIndex`), never from the whole picture decoded; an SVG's is drawn into a bitmap of
///   that size.
/// - The picture shown is decoded whole only up to `largest` pixels (4,096 × 4,096, 64 MB); above that it is shown made
///   smaller to 4,096 a side, and "100%" (⌘1) decodes the real one on request.
public enum PresentedPicture {
    /// The kinds a picture is presented as, and the type ImageIO must read each one's bytes as.
    public static let raster: [String: String] = [
        "image/png": "public.png", "image/jpeg": "public.jpeg", "image/gif": "com.compuserve.gif", "image/webp": "org.webmproject.webp",
    ]
    public static let svg = "image/svg+xml"
    /// The most pixels a picture is decoded to unless "100%" is asked: 4,096 × 4,096, 64 MB.
    public static let largest = 4096 * 4096
    /// The longest side of a picture shown made smaller.
    public static let smaller = 4096

    /// A decoded raster picture: the image, the picture's own size, and whether it is shown made smaller.
    public struct Decoded: @unchecked Sendable {
        public let image: CGImage
        public let pixels: CGSize
        public let smaller: Bool
        /// An animated GIF within the bound, which is shown by AppKit from its bytes so that it moves.
        public let animated: Bool
    }

    /// ImageIO's reading of the bytes, if it reads them as the kind said.
    public static func source(_ data: Data, mimeType: String) -> CGImageSource? {
        guard let type = raster[mimeType], let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == type, CGImageSourceGetCount(source) > 0 else { return nil }
        return source
    }

    public static func pixels(_ source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    /// The raster picture to show: whole up to `largest` pixels, or `full`; else made smaller.
    public static func decode(_ data: Data, mimeType: String, full: Bool) -> Decoded? {
        guard let source = source(data, mimeType: mimeType), let pixels = pixels(source) else { return nil }
        let smaller = !full && pixels.width * pixels.height > CGFloat(largest)
        let made = smaller ? thumbnail(source, longest: Self.smaller)
            : CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        // Decoded now, off the main thread (`kCGImageSourceShouldCacheImmediately`), so that it is not decoded again as
        // it is first drawn. Not drawn again into a context of its own: a copy made so and shown in an image view was
        // measured kept for good, 64 MB a time, as each next picture was shown.
        guard let image = made else { return nil }
        return Decoded(image: image, pixels: pixels, smaller: smaller, animated: !smaller && mimeType == "image/gif" && CGImageSourceGetCount(source) > 1)
    }

    /// A small picture of the item, `longest` pixels on its longest side at most: for raster bytes by ImageIO, for an SVG
    /// drawn into a bitmap of that size.
    public static func thumbnail(_ data: Data, mimeType: String, longest: Int) -> CGImage? {
        if mimeType == svg {
            guard let image = svgImage(data) else { return nil }
            return draw(image, longest: longest)
        }
        return source(data, mimeType: mimeType).flatMap { thumbnail($0, longest: longest) }
    }

    private static func thumbnail(_ source: CGImageSource, longest: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: longest,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }

    /// An SVG as AppKit draws it, if that is what the bytes are.
    public static func svgImage(_ data: Data) -> NSImage? {
        guard data.first(where: { ![0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF].contains($0) }) == UInt8(ascii: "<"),
              let image = NSImage(data: data), image.isValid,
              image.representations.count == 1, String(describing: type(of: image.representations[0])).contains("SVG") else { return nil }
        return image
    }

    /// An image drawn into a bitmap no longer than `longest` on a side.
    private static func draw(_ image: NSImage, longest: Int) -> CGImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(CGFloat(longest) / max(size.width, size.height), 4)
        let width = max(Int(size.width * scale), 1), height = max(Int(size.height * scale), 1)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    /// Kept for the card's and the window's callers that want an image of a whole small picture.
    public static func image(_ cgImage: CGImage) -> NSImage {
        NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
#endif
