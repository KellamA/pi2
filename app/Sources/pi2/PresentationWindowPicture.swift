import AppKit
import ImageIO
import SwiftUI

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
enum PresentedPicture {
    /// The kinds a picture is presented as, and the type ImageIO must read each one's bytes as.
    static let raster: [String: String] = [
        "image/png": "public.png", "image/jpeg": "public.jpeg", "image/gif": "com.compuserve.gif", "image/webp": "org.webmproject.webp",
    ]
    static let svg = "image/svg+xml"
    /// The most pixels a picture is decoded to unless "100%" is asked: 4,096 × 4,096, 64 MB.
    static let largest = 4096 * 4096
    /// The longest side of a picture shown made smaller.
    static let smaller = 4096

    /// A decoded raster picture: the image, the picture's own size, and whether it is shown made smaller.
    struct Decoded: @unchecked Sendable {
        let image: CGImage
        let pixels: CGSize
        let smaller: Bool
        /// An animated GIF within the bound, which is shown by AppKit from its bytes so that it moves.
        let animated: Bool
    }

    /// ImageIO's reading of the bytes, if it reads them as the kind said.
    static func source(_ data: Data, mimeType: String) -> CGImageSource? {
        guard let type = raster[mimeType], let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == type, CGImageSourceGetCount(source) > 0 else { return nil }
        return source
    }

    static func pixels(_ source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    /// The raster picture to show: whole up to `largest` pixels, or `full`; else made smaller.
    static func decode(_ data: Data, mimeType: String, full: Bool) -> Decoded? {
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
    static func thumbnail(_ data: Data, mimeType: String, longest: Int) -> CGImage? {
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
    static func svgImage(_ data: Data) -> NSImage? {
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
    static func image(_ cgImage: CGImage) -> NSImage {
        NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

/// How a picture is sized in its window: fit to the stage, at its actual size (one of its pixels to one of the screen's),
/// or at a magnification the person chose (a pinch, ⌘+ or ⌘−).
enum PictureZoom: Hashable {
    case fit
    case actual
    case scale(CGFloat)
}

/// What is behind a picture, for one with transparency.
enum PictureBackground: String, CaseIterable {
    case light, dark, chequered
}

/// A presented picture, drawn natively: an `NSImageView` in a scroll view that magnifies (docs/design/presenting.md, "The
/// window, in the app"). The picture is made from the bytes `presented.picture` sent by `PresentedPicture`: a raster
/// picture by ImageIO, an SVG by AppKit's own SVG image representation (`_NSSVGImageRep`, CoreSVG), which draws the
/// shapes and runs nothing: no script, and no load of any address, whether `http:`, `file:` or another picture's (an
/// `<image href>`, `<use href>` or CSS `@import` of one is left undrawn). It never goes near a web view.
struct PictureStage: NSViewRepresentable {
    let image: NSImage
    /// The picture's pixels, to size it at actual size; nil for an SVG without a stated size (its points are used).
    let pixels: CGSize?
    @Binding var zoom: PictureZoom
    let background: PictureBackground
    /// The magnification the picture is drawn at, as it changes: for ⌘+ and ⌘− to go on from.
    let magnified: (CGFloat) -> Void

    func makeNSView(context: Context) -> PictureScrollView {
        let view = PictureScrollView()
        view.onPinched = { scale in zoom = .scale(scale) }
        view.onMagnified = magnified
        return view
    }

    func updateNSView(_ view: PictureScrollView, context: Context) {
        view.onPinched = { scale in zoom = .scale(scale) }
        view.onMagnified = magnified
        view.show(image, pixels: pixels)
        view.paint(background)
        view.apply(zoom)
    }
}

/// The scroll view behind `PictureStage`: keeps the picture centred while it is smaller than the stage, fits it again as
/// the window changes size while it is fitted, and says when a pinch changed its magnification.
final class PictureScrollView: NSScrollView {
    private let imageView = NSImageView()
    private var shown: NSImage?
    private var zoom: PictureZoom = .fit
    var onPinched: (CGFloat) -> Void = { _ in }
    var onMagnified: (CGFloat) -> Void = { _ in }
    private var reported: CGFloat = 0

    override var magnification: CGFloat {
        didSet { report() }
    }

    /// Says the magnification after the view's update, never during it.
    private func report() {
        guard abs(magnification - reported) > 0.0001 else { return }
        reported = magnification
        let value = magnification
        DispatchQueue.main.async { [weak self] in self?.onMagnified(value) }
    }

    static let smallest: CGFloat = 0.05
    static let largest: CGFloat = 16

    init() {
        super.init(frame: .zero)
        contentView = CentringClipView()
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        allowsMagnification = true
        minMagnification = Self.smallest
        maxMagnification = Self.largest
        borderType = .noBorder
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageFrameStyle = .none
        imageView.isEditable = false
        imageView.animates = true
        // Nothing dropped on it changes what is shown, and nothing is dragged out of it as a file.
        imageView.unregisterDraggedTypes()
        documentView = imageView
        // Observed by selector, which AppKit lets go of with the view.
        NotificationCenter.default.addObserver(self, selector: #selector(pinched), name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    @objc private func pinched(_ notification: Notification) {
        zoom = .scale(magnification)
        report()
        onPinched(magnification)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ image: NSImage, pixels: CGSize?) {
        guard image !== shown else { return }
        shown = image
        imageView.image = image
        // Actual size: one pixel of the picture to one of the screen's, so a screenshot taken at 2× shows as it was.
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        // An SVG is drawn at its stated size, but never larger than 4,096 points a side before magnification: it is drawn
        // again as it is magnified, and a stated size of 16,000 would ask for a layer of that size at once.
        let stated = image.size
        let fitted = max(stated.width, stated.height) > 4096 ? stated.applying(.init(scaleX: 4096 / max(stated.width, stated.height), y: 4096 / max(stated.width, stated.height))) : stated
        let size = pixels.map { CGSize(width: max($0.width / scale, 1), height: max($0.height / scale, 1)) } ?? fitted
        imageView.frame = CGRect(origin: .zero, size: size)
        apply(zoom, force: true)
    }

    func paint(_ background: PictureBackground) {
        drawsBackground = true
        switch background {
        case .light: backgroundColor = NSColor(white: 0.93, alpha: 1)
        case .dark: backgroundColor = NSColor(white: 0.11, alpha: 1)
        case .chequered: backgroundColor = Self.chequer
        }
        contentView.backgroundColor = backgroundColor
        contentView.drawsBackground = true
    }

    func apply(_ zoom: PictureZoom, force: Bool = false) {
        guard force || zoom != self.zoom else { return }
        self.zoom = zoom
        switch zoom {
        case .fit: magnification = fitting
        case .actual: magnification = 1
        case .scale(let scale): magnification = min(max(scale, Self.smallest), Self.largest)
        }
    }

    /// The magnification that shows the whole picture in the stage, never larger than twice its actual size.
    private var fitting: CGFloat {
        let size = imageView.frame.size
        let room = contentView.frame.size
        guard size.width > 0, size.height > 0, room.width > 0, room.height > 0 else { return 1 }
        let inset: CGFloat = 24
        let scale = min((room.width - inset * 2) / size.width, (room.height - inset * 2) / size.height)
        return min(max(scale, Self.smallest), 2)
    }

    override func tile() {
        super.tile()
        if zoom == .fit {
            let fit = fitting
            if abs(magnification - fit) > 0.001 { magnification = fit }
        }
    }

    /// A grey chequer, for a picture's transparent parts.
    private static let chequer: NSColor = {
        let side: CGFloat = 8
        let image = NSImage(size: NSSize(width: side * 2, height: side * 2), flipped: false) { rect in
            NSColor(white: 0.86, alpha: 1).setFill()
            rect.fill()
            NSColor(white: 0.70, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: side, height: side).fill()
            NSRect(x: side, y: side, width: side, height: side).fill()
            return true
        }
        return NSColor(patternImage: image)
    }()
}

/// Keeps the document in the middle while it is smaller than the view, as Preview does.
final class CentringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}
