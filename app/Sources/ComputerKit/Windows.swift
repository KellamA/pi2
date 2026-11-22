import ApplicationServices
import Foundation

/// Window-server information is independent of AX focus and does not require Screen Recording (window names may).
package struct ServerWindow {
    package let id: CGWindowID
    package let pid: pid_t
    package let layer: Int
    package let frame: CGRect
    let title: String?
    let onScreen: Bool

    package init(id: CGWindowID, pid: pid_t, layer: Int, frame: CGRect, title: String? = nil, onScreen: Bool = false) {
        self.id = id
        self.pid = pid
        self.layer = layer
        self.frame = frame
        self.title = title
        self.onScreen = onScreen
    }

    package static func all(of pid: pid_t) -> [Self] {
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"] else { return nil }
            return Self(id: id, pid: pid, layer: layer, frame: CGRect(x: x, y: y, width: width, height: height),
                        title: info[kCGWindowName as String] as? String, onScreen: (info[kCGWindowIsOnscreen as String] as? Bool) == true)
        }
    }

    /// Same selection as `scripts/test-copy shot`: a parked window may have no on-screen flag and be at layer -1.
    package static func parkedCopy(in windows: [Self], pid: pid_t) -> Self? {
        windows.filter { $0.pid == pid && $0.layer <= 0 && $0.frame.width >= 100 && $0.frame.height >= 100 }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// Unlike the parked main window, a status popup must be showing. The menu bar item itself is not a window to work.
    package static func statusPopup(in windows: [Self], pid: pid_t, before: Set<CGWindowID>?, preferred: CGWindowID?) -> Self? {
        windows.filter { w in
            w.pid == pid && w.onScreen && w.frame.width >= 100 && w.frame.height >= 50
                && (before.map { !$0.contains(w.id) } ?? (w.id == preferred))
        }.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// An exact match first, allowing a little rounding in the two APIs. Never substitute an unrelated window.
    package static func matching(_ frame: CGRect, in windows: [Self], pid: pid_t) -> Self? {
        func distance(_ w: Self) -> CGFloat {
            abs(w.frame.minX - frame.minX) + abs(w.frame.minY - frame.minY) + abs(w.frame.width - frame.width) + abs(w.frame.height - frame.height)
        }
        return windows.filter { $0.pid == pid && distance($0) < 12 }.min { distance($0) < distance($1) }
    }

    /// The window-server record of a parked copy's window that accessibility gives at `frame`: the one at that frame,
    /// or else `parked`, the copy's parked main window, when it is the same size wherever the window server has it.
    /// The two disagree on where the window is while macOS moves it between Spaces, so an exact match alone turned the
    /// copy's own main window down then, and the tool read none of its controls (#748). A stale window that has
    /// closed, such as Settings, is another size and is still turned down. `matching` stays exact, for any other app.
    ///
    /// The size alone says which window it is only when nothing else could be meant (#770): give `parked` only for the
    /// window the app gives as its main window, never a stale focused window, and it is still refused when another
    /// window of the process is that size too, such as a second Background Command window, since controls read from
    /// one window would then be paired with another's picture and clicks.
    package static func backing(_ frame: CGRect, in windows: [Self], pid: pid_t, parked: Self?) -> Self? {
        if let exact = matching(frame, in: windows, pid: pid) { return exact }
        guard let parked, parked.pid == pid, sameSize(parked.frame, frame),
              !windows.contains(where: { $0.pid == pid && $0.id != parked.id && sameSize($0.frame, frame) }) else { return nil }
        return parked
    }

    package static func sameSize(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.width - b.width) + abs(a.height - b.height) < 4
    }
}

package enum WindowChoice {
    /// A focused element can outlive its window, or lack a frame. Try the next candidate rather than losing the app.
    package static func first<E>(in candidates: [E], minimized: (E) -> Bool, frame: (E) -> CGRect?) -> (E, CGRect)? {
        for candidate in candidates where !minimized(candidate) {
            if let rect = frame(candidate), rect.width > 1, rect.height > 1 { return (candidate, rect) }
        }
        return nil
    }

    /// A status item may open a window without making it the app's main window. Prefer the newly exposed one, or
    /// keep using it while it remains among the app's candidates. A closed popup must not mask the main window.
    package static func order<E: Equatable>(_ candidates: [E], beforePress: [E]?, preferred: E?) -> [E] {
        if let beforePress {
            return candidates.filter { !beforePress.contains($0) } + candidates.filter { beforePress.contains($0) }
        }
        if let preferred, candidates.contains(preferred) { return [preferred] + candidates.filter { $0 != preferred } }
        return candidates
    }

    /// The index of the smallest of `frames` that holds `point`: the listed control a click at a point lands on when a
    /// hit test cannot say. A hit test reads the screen, so it finds nothing where the window is off the screen or
    /// behind another window, which is all of a parked copy's window but its corner (#748). A frame that is empty, as a
    /// menu bar item's is, holds no point.
    package static func innermost(containing point: CGPoint, in frames: [CGRect]) -> Int? {
        frames.indices.filter { !frames[$0].isEmpty && frames[$0].contains(point) }
            .min { frames[$0].width * frames[$0].height < frames[$1].width * frames[$1].height }
    }
}

/// What a click or a context menu at a point acts on, decided in one place for the approval card and for the action,
/// so that the two cannot choose apart (#770). Generic over the element, so that `pi2-computer-check` can decide it
/// with stand-ins for what a hit test and a window's listed controls gave.
package enum AtPoint {
    /// The element worked at `point` (through accessibility where it answers to that, else by a real click at the
    /// point), or nil for a real click with nothing named.
    /// - Any app but a parked test copy: what the hit test found, as it always was, whether or not it can be pressed.
    /// - A parked copy: the same when the hit test found something in the window read; when it found nothing, or
    ///   something outside that window, the innermost listed control holding the point (#748), and else nothing. A
    ///   hit test reads the screen, which shows next to nothing of a parked copy's window.
    /// `inWindow` is asked only of a parked copy's hit, so any other app's click asks nothing more than it did.
    package static func target<E>(at point: CGPoint, hit: E?, listed: [(element: E, frame: CGRect)], parked: Bool,
                                  inWindow: (E) -> Bool) -> E? {
        guard parked else { return hit }
        if let hit, inWindow(hit) { return hit }
        return WindowChoice.innermost(containing: point, in: listed.map(\.frame)).map { listed[$0].element }
    }

    /// Whether `chosen`, what the approval card named, is still what is at the point after the wait: `target` gives
    /// it again now (`now`), and where it was a listed control, not the hit test's own find, the control is still
    /// there and still holds the point (`frameNow`, read again; nil once it is gone).
    package static func holds<E: Equatable>(_ chosen: E?, now: E?, hit: E?, at point: CGPoint, frameNow: (E) -> CGRect?) -> Bool {
        guard chosen == now else { return false }
        guard let chosen, chosen != hit else { return true }
        return frameNow(chosen)?.contains(point) == true
    }

    /// What the approval cards for actions at a point named, kept until each action comes. The action acts on that
    /// choice, and is refused when it no longer holds, rather than on whatever is at the point by then: the window can
    /// change during a long wait for approval. An action no card was shown for (Ask before each action off, or the
    /// app allowed for the conversation) finds nothing kept, and acts on what is there, as it always did.
    package struct Kept<E: Equatable> {
        private var chosen: [String: E?] = [:]

        package init() {}

        /// The choice a card names, for the action that names `key`: its conversation, app, action and point.
        package mutating func keep(_ element: E?, for key: String) { chosen[key] = .some(element) }

        /// What the action for `key` acts on: what was chosen now (`now`, with the hit test's own find `hit`) when
        /// nothing was kept for it; the card's choice when it holds; `.changed` when it does not, and the action is
        /// refused. The kept choice is used once.
        package mutating func settle(_ now: E?, hit: E?, for key: String, at point: CGPoint, frameNow: (E) -> CGRect?) -> Settled<E> {
            guard let card = chosen.removeValue(forKey: key) else { return .act(now) }
            return AtPoint.holds(card, now: now, hit: hit, at: point, frameNow: frameNow) ? .act(card) : .changed
        }
    }

    package enum Settled<E: Equatable>: Equatable {
        /// Act on this element, or with nil by a real click at the point.
        case act(E?)
        /// What the card named is gone or no longer at the point: refuse, and say to look again.
        case changed
    }

    /// What the agent is told when the window changed during the wait for approval, so the action was not taken.
    package static func changed(_ undone: String, x: Double, y: Double) -> String {
        "The window changed while this waited for approval: what is at (\(Int(x)), \(Int(y))) is not what the approval named, so \(undone). Take a screenshot to look again, then try again."
    }
}
