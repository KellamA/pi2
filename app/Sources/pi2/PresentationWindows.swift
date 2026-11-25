import Foundation
import PiModels

/// Where a presentation's window is asked for (docs/design/presenting.md, "The window, in the app"): the transcript's
/// Expand and a click on an item call `show`, which records which version and item were asked for and has the app's
/// scene open the window, or bring it forward. The window reads `asked[ref]` for the version and item to show, also when
/// it is open already.
@MainActor
final class PresentationWindows: ObservableObject {
    static let shared = PresentationWindows()

    /// What was last asked of a presentation's window: a version and an item (nil: the newest, the first), and when.
    struct Shown: Equatable {
        let version: Int?
        let item: Int?
        let at: Date
    }

    @Published private(set) var asked: [PresentationRef: Shown] = [:]

    /// Opens the window for a presentation, or brings it forward; set by the app's scene (`openWindow(value:)`).
    var open: ((PresentationRef) -> Void)?

    /// Opens, or brings forward, the window of `ref` at that version and item.
    func show(_ ref: PresentationRef, version: Int?, item: Int?) {
        asked[ref] = Shown(version: version, item: item, at: Date())
        open?(ref)
    }
}
