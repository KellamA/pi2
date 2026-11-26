import AppKit
import PiModels
import SwiftUI
import TranscriptKit
import WebKit

/// The widths a page can be drawn at, in CSS pixels: a phone's, a tablet's, a desktop's, or the window's own.
enum PageWidth: String, CaseIterable {
    case phone = "Phone"
    case tablet = "Tablet"
    case desktop = "Desktop"
    case fit = "Fit"

    var points: CGFloat? {
        switch self {
        case .phone: 390
        case .tablet: 820
        case .desktop: 1280
        case .fit: nil
        }
    }
}

/// A presented page, live in its window: the `PresentedPageView` the window's model made, at the width chosen. A width
/// wider than the stage is drawn smaller rather than cut off: the view is as wide as the stage allows and zoomed out so
/// that the page lays out at the width chosen. The page fills only this area; the bar, the strip and every word about the
/// page are pi²'s own views around it.
struct PageStage: NSViewRepresentable {
    let view: PresentedPageView
    let width: PageWidth

    func makeNSView(context: Context) -> PageHolder { PageHolder() }

    func updateNSView(_ holder: PageHolder, context: Context) {
        holder.hold(view, width: width.points)
    }

    static func dismantleNSView(_ holder: PageHolder, coordinator: ()) {
        holder.hold(nil, width: nil)
    }
}

/// Holds the page's view and lays it out at its width, centred.
final class PageHolder: NSView {
    private var page: PresentedPageView?
    private var width: CGFloat?

    override var isFlipped: Bool { true }

    func hold(_ view: PresentedPageView?, width: CGFloat?) {
        if page !== view {
            page?.removeFromSuperview()
            page = view
            if let view {
                addSubview(view)
                #if PI2_DEVELOPMENT
                if ProcessInfo.processInfo.environment["PI2_DRAW_WHEN_HIDDEN"] != nil { Self.drawWhenHidden(view) }
                #endif
            }
        }
        self.width = width
        needsLayout = true
    }

    #if PI2_DEVELOPMENT
    /// As the transcript's view does (`TranscriptWebKitView`), for picturing a copy whose windows are covered: WebKit
    /// otherwise stops drawing a page nobody can see. A switch WebKit does not make public, so a development build's alone.
    private static func drawWhenHidden(_ view: WKWebView) {
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard view.responds(to: selector), let method = view.method(for: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method, to: Setter.self)(view, selector, false)
    }
    #endif

    override func layout() {
        super.layout()
        guard let page else { return }
        let room = bounds.width
        let wanted = width ?? room
        let shown = min(wanted, room)
        page.frame = NSRect(x: ((room - shown) / 2).rounded(), y: 0, width: shown, height: bounds.height)
        let zoom = wanted > 0 ? shown / wanted : 1
        if abs(page.pageZoom - zoom) > 0.001 { page.pageZoom = zoom }
    }
}

/// A page's files for its window's life: each file is fetched from the engine once (`presented.file`), then served from
/// memory, so that Reload, another width or coming back to the item fetches nothing again.
@MainActor
final class CachedPresentedFiles: PresentedFiles {
    private let source: any PresentedFiles
    private var kept: [String: Data] = [:]

    init(_ source: any PresentedFiles) {
        self.source = source
    }

    nonisolated func bytes(of file: PresentedFile) async throws -> Data {
        try await fetch(file)
    }

    private func fetch(_ file: PresentedFile) async throws -> Data {
        if let data = kept[file.path] { return data }
        let data = try await source.bytes(of: file)
        kept[file.path] = data
        return data
    }
}
