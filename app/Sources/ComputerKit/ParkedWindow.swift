import AppKit

/// How a parked window joins its app's accessibility window list, which macOS leaves it out of until it has been
/// front once (#579): every copy `scripts/test-copy` starts parks its main window behind every ordinary window and
/// mostly off screen, and such a window is absent from `kAXWindows`, from every focused-window attribute, and from a
/// hit test at its off-screen position — so the tool that works a copy could read none of its controls, and said so.
///
/// Ordering the window front within its own level joins it: a parked window (level -1) rises above nothing any person
/// can see, and once a window has been front it stays in the list after `orderBack` puts it back, wherever it is
/// parked. The copy does this itself, over the control folder `scripts/test-copy` gives it.
///
/// The list is not the only way in, though, nor a steady one (#612): on macOS 27 a copy's app element answered its
/// parked window as its main and focused window from launch, and listed it among its windows only while AppKit counted
/// it as on the active Space. So whether the tool can reach the window is asked of every attribute its search reads.
@MainActor
package enum ParkedWindow {
    /// What an assistive app sets on an app it works, to have it build its accessibility scene for good.
    private static let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")

    /// Whether `window` is parked below every ordinary window, where ordering it front cannot show it to anyone. Only
    /// `scripts/test-copy`'s launch switch parks a window (`PI2_WINDOW_BEHIND`); a copy opened by hand has an ordinary
    /// window, and raising that one would put it over the person's work for as long as it took to order it back.
    package static func isParked(_ window: NSWindow) -> Bool {
        window.level.rawValue < NSWindow.Level.normal.rawValue
    }

    /// Whether the app is marked as wanting enhanced accessibility now: a reader may have set it and left it set, and
    /// `expose` puts it back as it found it.
    package static var enhancedMark: Bool? {
        guard let value = NSApp?.accessibilityAttributeValue(enhanced) else { return nil }
        return (value as? NSNumber)?.boolValue ?? (value as? Bool)
    }

    /// Whether another app's accessibility search finds `window`: the app element answers it as its main or focused
    /// window, or lists it among its windows or children. Read in-process, asking the app element for each attribute the
    /// computer tool's search reads from another app (`windowCandidates` in `ComputerController`), which the
    /// accessibility server answers with these same methods.
    ///
    /// Not the window list alone (#612): AppKit leaves a parked window out of `kAXWindows` and `kAXChildren` whenever it
    /// does not count it as on the active Space, which came and went within minutes of a copy's launch, raise or no
    /// raise, while `kAXMainWindow` and `kAXFocusedWindow` answered it throughout and the tool read it through them.
    package static func isReachable(_ window: NSWindow) -> Bool {
        guard let app = NSApp else { return false }
        return reachable(window, main: app.accessibilityMainWindow(), focused: app.accessibilityFocusedWindow(),
                         windows: app.accessibilityWindows() ?? [], children: app.accessibilityChildren() ?? [])
    }

    /// The decision itself, from what the app element answered, so that a check can give it answers AppKit gives only
    /// in states a check cannot make, such as a window off the active Space. The children are not only windows — a
    /// menu bar is one too — so each is checked, not the list cast whole.
    package static func reachable(_ window: NSWindow, main: Any?, focused: Any?, windows: [Any], children: [Any]) -> Bool {
        ([main, focused].compactMap { $0 } + windows + children).contains { ($0 as? NSWindow) === window }
    }

    /// Why the computer tool would turn `window` down after finding it through accessibility, or nil when it would take
    /// it. In a parked copy the tool takes a window it found only when the window server has it, at the frame
    /// accessibility gives or at that size as the copy's parked window (`ServerWindow.backing`), so that a closed
    /// window's stale frame is never read (#748). Asked of the window server as the tool asks it, so that
    /// `scripts/test-copy can-click` says no where the tool would.
    package static func refusal(_ window: NSWindow) -> String? {
        let pid = ProcessInfo.processInfo.processIdentifier
        // Accessibility gives a window's frame from the top-left corner of the main screen, as the window server does.
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let frame = CGRect(x: window.frame.minX, y: top - window.frame.maxY, width: window.frame.width, height: window.frame.height)
        return refusal(id: CGWindowID(window.windowNumber), frame: frame, server: ServerWindow.all(of: pid), pid: pid)
    }

    /// The decision itself, from the window server's records, so that a check can give it records a live copy gave.
    package static func refusal(id: CGWindowID, frame: CGRect, server: [ServerWindow], pid: pid_t) -> String? {
        let parked = ServerWindow.parkedCopy(in: server, pid: pid)
        if ServerWindow.backing(frame, in: server, pid: pid, parked: parked)?.id == id { return nil }
        func place(_ rect: CGRect) -> String { "\(Int(rect.width))×\(Int(rect.height)) at (\(Int(rect.minX)), \(Int(rect.minY)))" }
        guard let own = server.first(where: { $0.id == id && $0.pid == pid }) else {
            return "the window server has no record of the main window, which accessibility gives at \(place(frame)), so the computer tool would not take it"
        }
        return "the window server has the main window at \(place(own.frame)) and accessibility gives it at \(place(frame)), so the computer tool would not take it as the same window"
    }

    /// Join `window` to the app's accessibility window list, and put it back where it was: it rises only within its
    /// own level, where it stays behind every ordinary window, and a parked window's pixels do not change. The app is
    /// marked as wanting enhanced accessibility for the raise, as an assistive app's arrival does, so it has a scene
    /// for the raise to register in — a test copy has none of its own until a reader connects — and the mark is put
    /// back as it was afterwards: it changes how an app lays out and animates, and a copy is pictured as it is.
    /// Returns whether another app's search finds the window now (`isReachable`); false, raising nothing, for a window
    /// that is not parked.
    @discardableResult
    package static func expose(_ window: NSWindow) -> Bool {
        guard isParked(window) else { return false }
        let wasEnhanced = enhancedMark
        if wasEnhanced != true { NSApp?.accessibilitySetValue(true, forAttribute: enhanced) }
        window.orderFrontRegardless()
        window.orderBack(nil)
        if wasEnhanced != true { NSApp?.accessibilitySetValue(false, forAttribute: enhanced) }
        return isReachable(window)
    }
}
