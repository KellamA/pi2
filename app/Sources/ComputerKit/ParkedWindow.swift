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

    /// Whether `window` is among the app element's windows, which is what the accessibility server lists to another
    /// app. Read in-process, asking the app element what the server would ask it for another app. Its children are
    /// not only windows — a menu bar is one too — so each child is checked, not the list cast whole.
    package static func isListed(_ window: NSWindow) -> Bool {
        let children: [Any] = NSApp?.accessibilityChildren() ?? []
        return children.contains { ($0 as? NSWindow) === window }
    }

    /// Join `window` to the app's accessibility window list, and put it back where it was: it rises only within its
    /// own level, where it stays behind every ordinary window, and a parked window's pixels do not change. The app is
    /// marked as wanting enhanced accessibility for the raise, as an assistive app's arrival does, so it has a scene
    /// for the raise to register in — a test copy has none of its own until a reader connects — and the mark is put
    /// back as it was afterwards: it changes how an app lays out and animates, and a copy is pictured as it is.
    /// Returns whether the window is listed now; false, raising nothing, for a window that is not parked.
    @discardableResult
    package static func expose(_ window: NSWindow) -> Bool {
        guard isParked(window) else { return false }
        let wasEnhanced = enhancedMark
        if wasEnhanced != true { NSApp?.accessibilitySetValue(true, forAttribute: enhanced) }
        window.orderFrontRegardless()
        window.orderBack(nil)
        if wasEnhanced != true { NSApp?.accessibilitySetValue(false, forAttribute: enhanced) }
        return isListed(window)
    }
}
