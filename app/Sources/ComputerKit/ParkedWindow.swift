import AppKit

/// How a parked window joins its app's accessibility window list, which macOS leaves it out of until it has been
/// front once (#579): every copy `scripts/test-copy` starts parks its main window behind every ordinary window and
/// mostly off screen, and such a window is absent from `kAXWindows`, from every focused-window attribute, and from a
/// hit test at its off-screen position — so the tool that works a copy could read none of its controls, and said so.
///
/// Ordering the window front within its own level joins it: a parked window (level -1) rises above nothing any person
/// can see, and once a window has been front it stays in the list after `orderBack` puts it back, wherever it is
/// parked. The copy does this itself, over the control folder `scripts/test-copy` gives it.
@MainActor
package enum ParkedWindow {
    /// Whether `window` is among the app element's windows, which is what the accessibility server lists to another
    /// app. Read in-process, asking the app element what the server would ask it for another app. Its children are
    /// not only windows — a menu bar is one too — so each child is checked, not the list cast whole.
    package static func isListed(_ window: NSWindow) -> Bool {
        let children: [Any] = NSApp?.accessibilityChildren() ?? []
        return children.contains { ($0 as? NSWindow) === window }
    }

    /// Join `window` to the app's accessibility window list, and put it back where it was: it rises only within its
    /// own level, where it stays behind every ordinary window, and a parked window's pixels do not change. The app is
    /// marked as wanting enhanced accessibility first, as an assistive app's arrival does, so it has a scene for the
    /// raise to register in — a test copy has none of its own until a reader connects, and its own report would be
    /// empty without one. Returns whether the window is listed now.
    @discardableResult
    package static func expose(_ window: NSWindow) -> Bool {
        NSApp?.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        window.orderFrontRegardless()
        window.orderBack(nil)
        return isListed(window)
    }
}
