import AppKit
import SwiftUI

/// A presented picture's bytes made into an image, by the kind the engine says it is and only so: PNG, JPEG, GIF and
/// WebP by ImageIO (`NSBitmapImageRep`), and an SVG by AppKit's SVG representation alone, which draws shapes and runs
/// nothing. Bytes that are not what they are said to be (a PDF said to be an SVG, an SVG said to be a PNG) make no
/// image, rather than whatever `NSImage` would make of them.
enum PresentedPicture {
    static let raster: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    static func image(_ data: Data, mimeType: String) -> NSImage? {
        if raster.contains(mimeType) {
            guard let rep = NSBitmapImageRep(data: data), rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return nil }
            let image = NSImage(size: rep.size)
            image.addRepresentation(rep)
            return image
        }
        guard mimeType == "image/svg+xml", data.first(where: { ![0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF].contains($0) }) == UInt8(ascii: "<"),
              let image = NSImage(data: data), image.isValid,
              image.representations.count == 1, String(describing: type(of: image.representations[0])).contains("SVG") else { return nil }
        return image
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
        let size = pixels.map { CGSize(width: max($0.width / scale, 1), height: max($0.height / scale, 1)) } ?? image.size
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
