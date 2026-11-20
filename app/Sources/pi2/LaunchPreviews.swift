import SwiftUI

extension View {
    /// `.contextMenu`, which a development build can also list without a right-click: `PI2_MENU=<label>` writes the
    /// items of the menu on the element named by one of `labels`, such as a conversation's title or number
    /// (`ContextMenuPreview`, docs/development.md). Use it for every context menu, so that each can be checked in a test
    /// copy that nobody clicks in; `scripts/test-test-copy` fails on a plain `.contextMenu`. In a release build it is
    /// `.contextMenu` and nothing more.
    func contextMenu<MenuItems: View>(previewAs labels: String..., @ViewBuilder menuItems: () -> MenuItems) -> some View {
        #if PI2_DEVELOPMENT
        contextMenu(menuItems: menuItems)
            .background {
                if let asked = ContextMenuPreview.asked, labels.contains(asked) { ContextMenuAnchor() }
            }
        #else
        contextMenu(menuItems: menuItems)
        #endif
    }
}

#if PI2_DEVELOPMENT
import AppKit

/// The command palette as `PI2_SHOW` asked a development build for it: "palette" opens it empty, "palette:<query>"
/// with that query typed, so a picture of the window shows the entries that match (docs/development.md). The main
/// window opens as it would without `PI2_SHOW`. Every entry the palette makes is listed by the same code, so one added
/// later shows up here with nothing more to do.
@MainActor
enum PaletteLaunch {
    static let asked: String? = {
        guard let value = ProcessInfo.processInfo.environment["PI2_SHOW"] else { return nil }
        if value == "palette" { return "" }
        guard value.hasPrefix("palette:") else { return nil }
        return String(value.dropFirst("palette:".count))
    }()
    /// Each happens once, so opening the palette again later shows it empty, as usual.
    private static var toOpen = asked != nil
    private static var toType = asked?.isEmpty == false
    /// A query asked for while the app runs, by `scripts/test-copy show <suffix> palette:<query>` (#553): typed the next
    /// time the palette opens, once.
    static var live: String?

    /// True the first time it is asked, when `PI2_SHOW` asked for the palette.
    static func takeOpen() -> Bool {
        defer { toOpen = false }
        return toOpen
    }

    /// The query to type into the palette, the first time it opens.
    static func takeQuery() -> String? {
        if let live { Self.live = nil; return live }
        defer { toType = false }
        return toType ? asked : nil
    }
}

/// `PI2_MENU=<label>`: what a right-click on the element labelled `<label>` would show, written to `context-menu.txt`
/// in the data folder, item by item, with the ones that cannot be chosen marked. A context menu is a pop-up that macOS
/// draws only while the app is in front, so it cannot be captured from a copy that must not take the focus; its items,
/// though, are made by the view, and can be asked for.
///
/// Each context menu made with `.contextMenu(previewAs:)` puts an anchor behind its element when its label is the one
/// asked for. This builds a right-click event at the anchor's middle without posting it anywhere, and hands it to the
/// view there with `menu(for:)`, which is how AppKit asks a view for its context menu; SwiftUI answers with the menu it
/// makes from the element's `.contextMenu`. Nothing is chosen from it and nothing appears on screen.
@MainActor
enum ContextMenuPreview {
    static let asked: String? = {
        let value = ProcessInfo.processInfo.environment["PI2_MENU"]?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty ? nil : value
    }()
    static let fileName = "context-menu.txt"
    /// The anchors of the elements labelled as asked, while they are in a window.
    fileprivate static let anchors = NSHashTable<NSView>.weakObjects()
    /// The data folder, once the app has launched and the first look has begun.
    private static var home: URL?
    private static var pending: Task<Void, Never>?

    /// The first look, once the app has launched. The page `PI2_SHOW` opened may still be filling in, so it looks for
    /// the element for a while before writing that it is not there. A row that only comes later (a conversation made
    /// through the engine's socket after launch) writes the file again when it comes on screen.
    static func start(home: URL) async {
        guard let label = asked, self.home == nil else { return }
        self.home = home
        for delay in [0, 1, 2, 4, 8] {
            try? await Task.sleep(for: .seconds(delay))
            if write() { return }
        }
        save("No element labelled “\(label)” is on screen in the app's windows, so there is no context menu to show. "
            + "A row is labelled by what it shows (a conversation's title, an agent's name) and by its conversation's "
            + "number or its agent's id; PI2_SHOW opens the page it is on. This file is written again if one comes on screen.\n")
    }

    /// An element labelled as asked has come into a window: write its menu again once it has settled.
    fileprivate static func appeared() {
        guard home != nil else { return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { _ = write() }
        }
    }

    /// Writes the menu of the element labelled as asked, if one is on screen.
    private static func write() -> Bool {
        guard let label = asked else { return false }
        // Topmost first, so that "the first" means the same from one run to the next.
        let shown = anchors.allObjects
            .filter { $0.window?.isVisible == true && !$0.isHiddenOrHasHiddenAncestor && !$0.bounds.isEmpty }
            .sorted { ($0.window?.windowNumber ?? 0, -$0.convert($0.bounds, to: nil).maxY) < ($1.window?.windowNumber ?? 0, -$1.convert($1.bounds, to: nil).maxY) }
        guard let first = shown.first else { return false }
        save(describe(label: label, anchor: first, count: shown.count))
        return true
    }

    private static func save(_ text: String) {
        guard let home else { return }
        try? Data(text.utf8).write(to: home.appendingPathComponent(fileName), options: .atomic)
    }

    private static func describe(label: String, anchor: NSView, count: Int) -> String {
        guard let window = anchor.window, let root = window.contentView?.superview ?? window.contentView else {
            return "“\(label)” is in no window, so there is no context menu to show.\n"
        }
        let frame = anchor.convert(anchor.bounds, to: nil)
        let point = NSPoint(x: frame.midX, y: frame.midY)
        let which = count == 1 ? "the element" : "the first of \(count) elements"
        let place = window.title.isEmpty ? "a window" : "the window “\(window.title)”"
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
            return "Could not make a right-click to ask for the context menu of “\(label)”.\n"
        }
        // The view under the middle of the element, or the nearest above it that has a menu there: a list answers for
        // the row at the point.
        var view = root.hitTest(point)
        var menu: NSMenu?
        while let current = view, menu == nil {
            menu = current.menu(for: event)
            view = current.superview
        }
        guard let menu else { return "“\(label)” (\(which) with that label, in \(place)) has no context menu.\n" }
        var lines = [
            "Context menu of “\(label)” (\(which) with that label, in \(place)), as a right-click there would show it.",
            "[disabled] marks an item that cannot be chosen, ✓ one that is checked; a submenu's items are indented below it.",
            "",
        ]
        list(menu, depth: 0, into: &lines)
        menu.delegate?.menuDidClose?(menu)
        return lines.joined(separator: "\n") + "\n"
    }

    private static func list(_ menu: NSMenu, depth: Int, into lines: inout [String]) {
        // A menu may fill in only when it is about to show, and decide then which items can be chosen.
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        let indent = String(repeating: "  ", count: depth)
        for item in menu.items where !item.isHidden {
            if item.isSeparatorItem {
                lines.append(indent + "———")
                continue
            }
            var line = indent + (item.state == .on ? "✓ " : "") + item.title
            if item.submenu != nil { line += " ▸" }
            if !item.isEnabled { line += "  [disabled]" }
            lines.append(line)
            if let submenu = item.submenu { list(submenu, depth: depth + 1, into: &lines) }
        }
    }
}

/// Behind an element whose context menu `PI2_MENU` asked for: says where it is. Takes no clicks.
private struct ContextMenuAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {}

    final class Anchor: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                ContextMenuPreview.anchors.remove(self)
            } else {
                ContextMenuPreview.anchors.add(self)
                ContextMenuPreview.appeared()
            }
        }
    }
}
#endif
