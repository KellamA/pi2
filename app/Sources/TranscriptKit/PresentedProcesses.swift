
import Foundation

/// How many presented pages may have a web content process of their own at once, in the whole app: offscreen drawings
/// and live windows together (docs/design/presenting.md, "How a page is drawn"). A page is drawn only with a place taken
/// here first, and the place is given back only once its view has ended and its process is seen to be gone
/// (`PresentedPageView.end`). A process that could not be seen to end keeps its place, so that pages an agent presents in
/// a loop can never add processes without end, whatever their scripts do.
@MainActor
public final class PresentedProcesses {
    /// Eight: three drawings at once (the app's `PresentedDrawing`), and five live pages in windows. Each is a web
    /// content process of some tens of MB, and one spinning at full speed costs a core.
    public static let shared = PresentedProcesses(most: 8)

    public let most: Int
    /// Places taken by pages being drawn or shown, and by processes that did not end when asked.
    public private(set) var taken = 0
    /// Of those, the processes that could not be seen to end.
    public private(set) var stuck = 0

    public init(most: Int) {
        self.most = most
    }

    /// A place for one page's process, if one is free.
    public func take() -> Place? {
        guard taken < most else { return nil }
        taken += 1
        return Place(owner: self)
    }

    /// What is said when no place is free.
    public var refusal: String {
        "pi² already has \(most) pages drawn or open\(stuck > 0 ? ", \(stuck) of whose processes did not end" : ""); close a presentation's window and try again"
    }

    /// One page's place. `end` ends its view's process and gives the place back once the process is gone; a place whose
    /// view was never made is given back with `release`.
    @MainActor
    public final class Place {
        private weak var owner: PresentedProcesses?
        private var held = true

        init(owner: PresentedProcesses) {
            self.owner = owner
        }

        /// Ends `view`'s process and gives the place back once it is gone; if it is not seen to go, the place stays
        /// taken, counted as stuck. Says whether it went.
        @discardableResult
        public func end(_ view: PresentedPageView) async -> Bool {
            let gone = await view.end()
            if gone { release() } else { markStuck() }
            return gone
        }

        /// Gives the place back: for a view that was never made.
        public func release() {
            guard held else { return }
            held = false
            owner?.taken -= 1
        }

        private func markStuck() {
            guard held else { return }
            held = false
            owner?.stuck += 1
        }
    }
}
