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

    static func all(of pid: pid_t) -> [Self] {
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
}
