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

    /// Pictures fetched, and why one could not be, by version and item.
    private(set) var pictures: [ItemKey: NSImage] = [:]
    private(set) var pictureProblems: [ItemKey: String] = [:]
    private var fetching: Set<ItemKey> = []

    var zoom: PictureZoom = .fit
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
        if current?.kind == .picture { zoom = .fit }
        refreshPage()
    }

    // MARK: Pictures

    /// Fetches the picture of an item once, from a view's task: a picture's own bytes, or a page's snapshot (for the
    /// strip) once it is drawn. A raster picture is decoded by ImageIO and an SVG by AppKit's SVG representation, which
    /// runs nothing and loads nothing (`PictureStage`).
    func load(_ key: ItemKey) async {
        guard pictures[key] == nil, !fetching.contains(key), pictureProblems[key] == nil else { return }
        guard let entry = record?.version(key.version)?.items[safe: key.item] else { return }
        if entry.kind == .page, entry.snapshot?.isDrawn != true { return }
        fetching.insert(key)
        defer { fetching.remove(key) }
        do {
            let bytes = try await feed.picture(key.version, key.item)
            // Only the kinds a picture is presented as are made into one; anything else is not drawn at all.
            guard Self.drawable.contains(bytes.mimeType), let image = NSImage(data: bytes.data), image.isValid else {
                pictureProblems[key] = "This picture could not be read."
                return
            }
            pictures[key] = image
        } catch {
            pictureProblems[key] = PresentationText.plain(error.localizedDescription, limit: PresentationText.caption)
        }
    }

    static let drawable: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp", "image/svg+xml"]

    // MARK: Pages

    /// Whether the version shown has the network allowed for its pages: the person's, per version.
    var networkAllowed: Bool { version?.network.allowed == true }

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
        Task { [weak self] in
            do {
                let view = try await PresentedPageView.makeLive(page: page, source: source, network: wanted.network)
                guard let self, self.pageKey == wanted else {
                    view.close()
                    return
                }
                view.onBlockedNavigation = { [weak self] url in self?.blocked(url) }
                view.onProcessEnded = { [weak self] in self?.pageStopped = true }
                self.pageView = view
            } catch {
                if let self, self.pageKey == wanted { self.pageProblem = "The page could not be drawn: \(error.localizedDescription)" }
            }
        }
    }

    private func dropPage() {
        pageView?.close()
        pageView = nil
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

    /// Lets go of the page's view as the window closes.
    func close() {
        dropPage()
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
