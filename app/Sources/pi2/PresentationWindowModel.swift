import AppKit
import Observation
import PiModels
import TranscriptKit

/// Where a presentation's window reads what it shows: the engine (`presented.list`, `conversation.presented`,
/// `presented.picture`, `presented.file`, `presented.network`), or, in a development build, a fixture of hostile texts
/// (`PresentationFixture`).
@MainActor
struct PresentationFeed {
    var list: () async throws -> [PresentationRecord]
    var updates: () -> AsyncStream<PresentationRecord>
    var picture: (_ version: Int, _ item: Int) async throws -> PresentedBytes
    var page: (_ item: PresentedItem) throws -> PresentedPage
    var files: (_ version: Int, _ item: Int) -> any PresentedFiles
    var setNetwork: (_ version: Int, _ allow: Bool) async throws -> Void

    static func engine(_ engine: EngineClient, conversation: Int, presentation: String) -> PresentationFeed {
        PresentationFeed(
            list: { try await engine.presentedList(conversation: conversation) },
            updates: { engine.presentedUpdates(conversation: conversation) },
            picture: { version, item in try await engine.presentedPicture(conversation: conversation, presentation: presentation, version: version, item: item) },
            page: { item in try engine.presentedPage(conversation: conversation, item: item) },
            files: { version, item in EnginePresentedFiles(engine: engine, conversation: conversation, presentation: presentation, version: version, item: item) },
            setNetwork: { version, allow in try await engine.presentedNetwork(conversation: conversation, presentation: presentation, version: version, allow: allow) }
        )
    }
}

/// One presentation's window: which version and item it shows, the pictures it has fetched, the page's live view, and
/// how the person has set the stage. Follows the conversation: a new version shows at once at the item that was shown.
@MainActor
@Observable
final class PresentationWindowModel {
    let ref: PresentationRef
    private let feed: PresentationFeed

    /// The presentation, once read; nil before, or when the conversation has no such presentation.
    private(set) var record: PresentationRecord?
    /// Why it could not be read.
    private(set) var problem: String?
    private(set) var loaded = false
    /// The version shown, by its number, and the item, by its place in the version.
    private(set) var versionNumber: Int?
    private(set) var item = 0

    /// The strip's small pictures, made at the size they are drawn (`PresentedPicture.thumbnail`), by version and item;
    /// and why one could not be made.
    private(set) var thumbnails: [ItemKey: NSImage] = [:]
    private(set) var pictureProblems: [ItemKey: String] = [:]
    private var fetching: Set<ItemKey> = []

    /// The one picture shown at its size, the item's alone: the one before is let go as another is shown.
    private(set) var shown: ShownPicture?
    private var showing: ItemKey?

    struct ShownPicture {
        let key: ItemKey
        let image: NSImage
        /// The picture's own size in pixels (nil for an SVG, drawn at its stated size), and whether it is shown made
        /// smaller than that.
        let pixels: CGSize?
        let smaller: Bool
    }

    var zoom: PictureZoom = .fit {
        // "100%" of a picture shown made smaller decodes the real one, on this request alone.
        didSet {
            if zoom == .actual, let shown, shown.smaller { Task { await show(shown.key, full: true) } }
        }
    }
    /// The magnification the picture is drawn at, as its view last said.
    var magnification: CGFloat = 1
    var background: PictureBackground = .light
    var width: PageWidth = .desktop
    var stripShown = true

    /// The page's live view, for the item shown; made again for another item, version, network or Reload.
    private(set) var pageView: PresentedPageView?
    private var pageKey: PageKey?
    private(set) var pageProblem: String?
    /// A page's address it tried to leave for, briefly, and that its process ended twice.
    private(set) var blockedLink: String?
    private(set) var pageStopped = false
    private var reloads = 0
    /// A page's files, fetched once each for the window's life.
    private var files: [ItemKey: CachedPresentedFiles] = [:]

    /// When `PresentationWindows` was last asked for this window, so that the same ask is applied once.
    private var appliedAsk: Date?

    struct ItemKey: Hashable {
        let version: Int
        let item: Int
    }

    private struct PageKey: Equatable {
        let item: ItemKey
        let network: Bool
        let reload: Int
    }

    init(ref: PresentationRef, feed: PresentationFeed) {
        self.ref = ref
        self.feed = feed
    }

    // MARK: What is shown

    var versions: [PresentedVersion] { (record?.versions ?? []).sorted { $0.version < $1.version } }
    var version: PresentedVersion? { versionNumber.flatMap { record?.version($0) } ?? record?.latest }
    var items: [PresentedItem] { version?.items ?? [] }
    var current: PresentedItem? { items.indices.contains(item) ? items[item] : nil }
    var key: ItemKey? { version.map { ItemKey(version: $0.version, item: item) } }
    /// Where the version shown is among them, from 1, and how many there are.
    var place: (Int, Int)? {
        guard let version, let index = versions.firstIndex(where: { $0.version == version.version }) else { return nil }
        return (index + 1, versions.count)
    }

    // MARK: Reading and following

    /// Reads the presentation once, then follows the conversation's changes until the window goes.
    func run(asked: PresentationWindows.Shown?) async {
        await reload(asked: asked)
        for await changed in feed.updates() where changed.id == ref.presentation {
            take(changed)
        }
    }

    /// Reads the list again: at first, and after the engine has started again, when events may have been missed.
    func reload(asked: PresentationWindows.Shown?) async {
        do {
            let list = try await feed.list()
            problem = nil
            if let found = list.first(where: { $0.id == ref.presentation }) {
                take(found)
            } else {
                record = nil
                problem = "This conversation has no presentation \(ref.presentation) any more."
            }
        } catch {
            problem = error.localizedDescription
        }
        loaded = true
        // The newest ask, which may have come while the list was read.
        if let asked = PresentationWindows.shared.asked[ref] ?? asked { apply(asked) }
    }

    /// A record as the engine sent it. A newer version shows at once, at the item that was shown; anything else (a page
    /// drawn, the network switched, a question answered) changes what is shown in place.
    func take(_ changed: PresentationRecord) {
        let newestBefore = record?.latest?.version
        record = changed
        if let newest = changed.latest?.version, let before = newestBefore, newest > before {
            versionNumber = newest
        } else if versionNumber == nil || changed.version(versionNumber ?? 0) == nil {
            versionNumber = changed.latest?.version
        }
        item = min(item, max(items.count - 1, 0))
        refreshPage()
    }

    /// Shows the version and item the person asked for (Expand on a card, a click on an item), once each time asked.
    func apply(_ asked: PresentationWindows.Shown) {
        // Before the record is read, the ask waits for `reload`, which applies the newest.
        guard asked.at != appliedAsk, record != nil else { return }
        appliedAsk = asked.at
        if let number = asked.version, record?.version(number) != nil { versionNumber = number } else { versionNumber = record?.latest?.version }
        item = min(max(asked.item ?? 0, 0), max(items.count - 1, 0))
        refreshPage()
    }

    // MARK: Moving

    func step(version by: Int) {
        guard let (place, count) = place else { return }
        let next = place - 1 + by
        guard (0..<count).contains(next) else { return }
        versionNumber = versions[next].version
        item = min(item, max(items.count - 1, 0))
        refreshPage()
    }

    func step(item by: Int) {
        guard !items.isEmpty else { return }
        select(min(max(item + by, 0), items.count - 1))
    }

    func select(_ index: Int) {
        guard items.indices.contains(index), index != item else { return }
        item = index
        shown = nil
        if current?.kind == .picture { zoom = .fit }
        refreshPage()
    }

    // MARK: Pictures

    /// The thumbnail's longest side in pixels: the strip's 120 points, at a Retina screen's scale and a little over.
    nonisolated static let thumbnailPixels = 300

    /// Makes an item's thumbnail once, from a view's task: a picture's own bytes, or a page's snapshot once it is drawn,
    /// made by ImageIO at the size it is drawn, never from the whole picture decoded.
    func loadThumbnail(_ key: ItemKey) async {
        guard thumbnails[key] == nil, !fetching.contains(key), pictureProblems[key] == nil else { return }
        guard let entry = record?.version(key.version)?.items[safe: key.item] else { return }
        if entry.kind == .page, entry.snapshot?.isDrawn != true { return }
        fetching.insert(key)
        defer { fetching.remove(key) }
        do {
            let bytes = try await feed.picture(key.version, key.item)
            let made: CGImage?
            if bytes.mimeType == PresentedPicture.svg {
                made = PresentedPicture.thumbnail(bytes.data, mimeType: bytes.mimeType, longest: Self.thumbnailPixels)
            } else {
                let data = bytes.data, type = bytes.mimeType
                made = await Task.detached { PresentedPicture.thumbnail(data, mimeType: type, longest: Self.thumbnailPixels) }.value
            }
            guard let made else {
                pictureProblems[key] = "This picture could not be read."
                return
            }
            thumbnails[key] = PresentedPicture.image(made)
        } catch {
            pictureProblems[key] = PresentationText.plain(error.localizedDescription, limit: PresentationText.caption)
        }
    }

    /// Shows an item's picture at its size, from the stage's task: decoded off the main thread, whole up to
    /// `PresentedPicture.largest` pixels unless `full`, else made smaller. The picture shown before is let go first.
    func show(_ key: ItemKey, full: Bool = false) async {
        if let shown, shown.key == key, !shown.smaller || !full { return }
        if showing == key, !full { return }
        if shown?.key != key { shown = nil }
        showing = key
        pictureProblems[key] = nil
        do {
            let bytes = try await feed.picture(key.version, key.item)
            guard showing == key else { return }
            if bytes.mimeType == PresentedPicture.svg {
                guard let image = PresentedPicture.svgImage(bytes.data) else { throw PictureUnread() }
                shown = ShownPicture(key: key, image: image, pixels: nil, smaller: false)
                return
            }
            let data = bytes.data, type = bytes.mimeType
            guard let decoded = await Task.detached(operation: { PresentedPicture.decode(data, mimeType: type, full: full) }).value else { throw PictureUnread() }
            guard showing == key else { return }
            // An animated GIF within the bound moves: AppKit draws it from its bytes, one frame at a time.
            let image: NSImage
            if decoded.animated, let rep = NSBitmapImageRep(data: data) {
                image = NSImage(size: decoded.pixels)
                image.addRepresentation(rep)
            } else {
                image = PresentedPicture.image(decoded.image)
            }
            shown = ShownPicture(key: key, image: image, pixels: decoded.pixels, smaller: decoded.smaller)
        } catch is PictureUnread {
            pictureProblems[key] = "This picture could not be read."
        } catch {
            pictureProblems[key] = PresentationText.plain(error.localizedDescription, limit: PresentationText.caption)
        }
        if showing == key { showing = nil }
    }

    private struct PictureUnread: Error {}

    // MARK: Pages

    /// Whether the version shown has the network allowed for its pages: the person's, per version.
    /// Always false without the switch (`PresentedPagePolicy.networkCanBeAllowed`): the engine's record is then not read.
    var networkAllowed: Bool { PresentedPagePolicy.networkCanBeAllowed && version?.network.allowed == true }

    /// Turns the network on or off for the version shown; the record comes back changed, and the page is made again.
    func setNetwork(_ allow: Bool) async {
        guard let version else { return }
        do {
            try await feed.setNetwork(version.version, allow)
        } catch {
            pageProblem = error.localizedDescription
        }
    }

    func reloadPage() {
        reloads += 1
        refreshPage()
    }

    /// Makes the page's live view for what is shown, if that changed; closes the one before.
    private func refreshPage() {
        guard let key, let current, current.kind == .page else {
            dropPage()
            return
        }
        let wanted = PageKey(item: key, network: networkAllowed, reload: reloads)
        guard wanted != pageKey else { return }
        dropPage()
        pageKey = wanted
        let page: PresentedPage
        do {
            page = try feed.page(current)
        } catch {
            pageProblem = error.localizedDescription
            return
        }
        let source = files[key] ?? CachedPresentedFiles(feed.files(key.version, key.item))
        files[key] = source
        let before = ending
        Task { [weak self] in
            // The page shown before is ended first, its process gone and its place given back.
            await before?.value
            guard let self, self.pageKey == wanted else { return }
            // Every presented page's process has a place, the app's drawings' and windows' together; none without one.
            guard let place = PresentedProcesses.shared.take() else {
                self.pageProblem = PresentedProcesses.shared.refusal
                return
            }
            do {
                let view = try await PresentedPageView.makeLive(page: page, source: source, network: wanted.network)
                guard self.pageKey == wanted else {
                    await place.end(view)
                    return
                }
                view.onBlockedNavigation = { [weak self] url in self?.blocked(url) }
                view.onProcessEnded = { [weak self] in self?.pageStopped = true }
                self.pageView = view
                self.pagePlace = place
                #if PI2_DEVELOPMENT
                // Its process is started as it loads: said once it has one.
                Task { [weak self, weak view] in
                    for _ in 0..<100 {
                        guard let view, let self else { return }
                        let pid = Self.process(of: view)
                        if pid != "0" {
                            self.note("presentation window: page process \(pid) shown, \(PresentedProcesses.shared.taken) places taken")
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
                #endif
            } catch {
                place.release()
                if self.pageKey == wanted { self.pageProblem = "The page could not be drawn: \(error.localizedDescription)" }
            }
        }
    }

    /// The place the page shown holds among the presented pages' processes (`PresentedProcesses`).
    private var pagePlace: PresentedProcesses.Place?
    /// The ending of the pages let go, one after another; a new page waits for it.
    private var ending: Task<Void, Never>?

    /// Lets go of the page shown: its view is ended, its process seen gone and its place given back, never only closed.
    private func dropPage() {
        if let view = pageView, let place = pagePlace {
            let before = ending
            #if PI2_DEVELOPMENT
            let note = note, pid = Self.process(of: view)
            #endif
            ending = Task {
                await before?.value
                let gone = await place.end(view)
                #if PI2_DEVELOPMENT
                note("presentation window: page process \(pid) \(gone ? "ended" : "did not end"), \(PresentedProcesses.shared.taken) places taken")
                #else
                _ = gone
                #endif
            }
        }
        pageView = nil
        pagePlace = nil
        pageKey = nil
        pageProblem = nil
        pageStopped = false
        blockedLink = nil
    }

    private var blockedAt = Date.distantPast

    private func blocked(_ url: URL) {
        let host = url.host(percentEncoded: false) ?? url.scheme.map { "a \($0): address" } ?? "another address"
        blockedLink = PresentationText.plain(host, limit: PresentationText.address)
        let at = Date()
        blockedAt = at
        Task {
            try? await Task.sleep(for: .seconds(5))
            if blockedAt == at { blockedLink = nil }
        }
    }

    /// Lets go of the page's view as the window closes: it is ended, and its place given back once its process is gone.
    func close() {
        dropPage()
    }

    /// A line for app.log, in a development build: each page process shown and ended, for a copy's check.
    var note: (String) -> Void = { _ in }

    private static func process(of view: PresentedPageView) -> String {
        (view.value(forKey: "_webProcessIdentifier") as? NSNumber).map { String($0.int32Value) } ?? "?"
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
