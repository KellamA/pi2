// What the projects screens' pop-up menus come out as in a native menu (#597).
//
// A SwiftUI `Menu` is drawn by AppKit: for an app built for macOS 15, as pi² is, it is a pull-down `NSPopUpButton`
// whose menu SwiftUI fills, from the menu's content, just before AppKit shows it. Each row becomes an `NSMenuItem`,
// which holds a title and at most one image, and a label made of anything else is not drawn as it was made: the Give to
// menu's rows, an avatar beside a name, each came out as the avatar's letter, and nobody saw it, since a pop-up menu
// cannot be opened in a test copy parked behind the person's windows. So this makes each menu as the app does, with
// MenuKit's rows (the ones the app's menus are built with) or, for the menus whose rows are only fixed words, with
// `Button` and the same words, in a window of its own that is never shown. Then it asks SwiftUI to fill the menu as
// AppKit asks it before showing one (`popUpButtonCell:willShowMenu:`, sent to the menu's delegate), without showing
// anything or taking the keyboard, reads each item's title and image as AppKit holds them, and fails on a title that is
// empty, a single letter, or not the name the row stands for, on an agent's row without its avatar, and on a chosen row
// without its tick.
//
// `--menu-pictures <folder>` also draws the rows as read, in dark and in light, into that folder: each item's title
// and image as AppKit holds them, laid out as a menu lays them out, not a capture of the menu macOS would draw.

import AppKit
import MenuKit
import ObjectiveC
import PiStyle
import SwiftUI

// MARK: - Filling a menu in-process

/// The menus handed to NSMenu to pop up since the last `take()`. Only touched on the main thread, where AppKit calls the
/// replaced methods.
enum PoppedUp {
    nonisolated(unsafe) static var menus: [NSMenu] = []

    static func keep(_ object: AnyObject?, _ other: AnyObject? = nil) {
        if let menu = object as? NSMenu { menus.append(menu) } else if let menu = other as? NSMenu { menus.append(menu) }
    }

    static func take() -> [NSMenu] {
        defer { menus = [] }
        return menus
    }
}

/// Replaces, in this process only, every method through which NSMenu shows a pop-up or context menu, public and
/// private, with one that keeps the menu and shows nothing. A menu with a button style of its own, as From a Template
/// has, is not an NSPopUpButton: SwiftUI makes its NSMenu when it is pressed and hands it to one of these (on macOS 26,
/// `_popUpMenuRelativeToRect:inView:width:flags:selectedItemIndexProvider:`). The others are replaced too, so that a
/// later SwiftUI that takes another way still opens nothing on the screen; the check then says it saw no menu.
@MainActor
func keepMenusOffScreen() {
    typealias Point = CGPoint
    typealias Rect = CGRect
    func replace(_ cls: AnyClass, _ name: String, _ block: Any) {
        guard let method = class_getInstanceMethod(cls, NSSelectorFromString(name)) else { return }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }
    let menu: AnyClass = NSMenu.self
    let meta: AnyClass = object_getClass(NSMenu.self)!
    replace(menu, "popUpMenuPositioningItem:atLocation:inView:",
            { (m: AnyObject, _: AnyObject?, _: Point, _: AnyObject?) -> Bool in PoppedUp.keep(m); return false }
                as @convention(block) (AnyObject, AnyObject?, Point, AnyObject?) -> Bool)
    replace(menu, "popUpMenuPositioningItem:atLocation:inView:appearance:",
            { (m: AnyObject, _: AnyObject?, _: Point, _: AnyObject?, _: AnyObject?) -> Bool in PoppedUp.keep(m); return false }
                as @convention(block) (AnyObject, AnyObject?, Point, AnyObject?, AnyObject?) -> Bool)
    replace(menu, "_popUpMenuPositioningItem:atLocation:inView:completionBlock:",
            { (m: AnyObject, _: AnyObject?, _: Point, _: AnyObject?, _: AnyObject?) in PoppedUp.keep(m) }
                as @convention(block) (AnyObject, AnyObject?, Point, AnyObject?, AnyObject?) -> Void)
    replace(menu, "_popUpMenuRelativeToRect:inView:preferredEdge:",
            { (m: AnyObject, _: Rect, _: AnyObject?, _: UInt) -> Bool in PoppedUp.keep(m); return false }
                as @convention(block) (AnyObject, Rect, AnyObject?, UInt) -> Bool)
    replace(menu, "_popUpMenuRelativeToRect:inView:preferredEdge:flags:options:",
            { (m: AnyObject, _: Rect, _: AnyObject?, _: UInt, _: UInt, _: AnyObject?) -> Bool in PoppedUp.keep(m); return false }
                as @convention(block) (AnyObject, Rect, AnyObject?, UInt, UInt, AnyObject?) -> Bool)
    replace(menu, "_popUpMenuRelativeToRect:inView:width:flags:selectedItemIndexProvider:",
            { (m: AnyObject, _: Rect, _: AnyObject?, _: Double, _: UInt, _: AnyObject?) in PoppedUp.keep(m) }
                as @convention(block) (AnyObject, Rect, AnyObject?, Double, UInt, AnyObject?) -> Void)
    replace(menu, "_popUpMenuAtLocation:view:selectedItemIndexProvider:minimumWidth:font:flags:options:",
            { (m: AnyObject, _: Point, _: AnyObject?, _: AnyObject?, _: Double, _: AnyObject?, _: UInt, _: AnyObject?) in PoppedUp.keep(m) }
                as @convention(block) (AnyObject, Point, AnyObject?, AnyObject?, Double, AnyObject?, UInt, AnyObject?) -> Void)
    for name in ["_popUpMenuWithEvent:forView:", "_popUpMenuWithContext:forView:"] {
        replace(menu, name, { (m: AnyObject, _: AnyObject?, _: AnyObject?) in PoppedUp.keep(m) }
            as @convention(block) (AnyObject, AnyObject?, AnyObject?) -> Void)
    }
    for cls in [menu, meta] {
        for name in ["_popUpContextMenu:withEvent:forView:", "_popUpContextMenu:withContext:forView:", "popUpContextMenu:withEvent:forView:"] {
            replace(cls, name, { (m: AnyObject, a: AnyObject?, _: AnyObject?, _: AnyObject?) in PoppedUp.keep(m, a) }
                as @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?) -> Void)
        }
        for name in ["_popUpContextMenu:withEvent:forView:withFont:", "_popUpContextMenu:withContext:forView:withFont:",
                     "popUpContextMenu:withEvent:forView:withFont:", "_popUpContextMenu:withEvent:forView:completionBlock:",
                     "_popUpContextMenu:withContext:forView:completionBlock:"] {
            replace(cls, name, { (m: AnyObject, a: AnyObject?, _: AnyObject?, _: AnyObject?, _: AnyObject?) in PoppedUp.keep(m, a) }
                as @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?, AnyObject?) -> Void)
        }
        for name in ["_popUpContextMenu:withEvent:forView:withFont:completionBlock:", "_popUpContextMenu:withContext:forView:withFont:completionBlock:"] {
            replace(cls, name, { (m: AnyObject, a: AnyObject?, _: AnyObject?, _: AnyObject?, _: AnyObject?, _: AnyObject?) in PoppedUp.keep(m, a) }
                as @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?, AnyObject?, AnyObject?) -> Void)
        }
    }
}

/// An accessibility method of an element, read as the accessibility server would for another app.
@MainActor
private func read(_ object: NSObject, _ name: String) -> Any? {
    let selector = NSSelectorFromString(name)
    guard object.responds(to: selector) else { return nil }
    return object.perform(selector)?.takeUnretainedValue()
}

@MainActor
private func elements(under object: NSObject) -> [NSObject] {
    [object] + ((read(object, "accessibilityChildren") as? [NSObject]) ?? []).flatMap { elements(under: $0) }
}

/// What the accessibility server does for another app's `AXPress`.
@MainActor
private func press(_ object: NSObject) -> Bool {
    let selector = NSSelectorFromString("accessibilityPerformPress")
    guard object.responds(to: selector) else { return false }
    typealias Press = @convention(c) (AnyObject, Selector) -> Bool
    return unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector)
}

/// A pop-up menu's button, made as the app's are: the menu style and small size most of the projects screens give
/// them, or pi²'s own secondary button style, which the Agents tab's From a Template has.
private struct MenuButton<Items: View>: View {
    enum Style { case menu, piSecondary }
    let label: String
    var style = Style.menu
    @ViewBuilder let items: () -> Items

    var body: some View {
        switch style {
        case .menu:
            Menu { items() } label: { Text(label) }
                .menuStyle(.button)
                .controlSize(.small)
                .fixedSize()
        case .piSecondary:
            Menu { items() } label: { Label(label, systemImage: "doc.on.doc") }
                .buttonStyle(PiButtonStyle(kind: .secondary))
                .controlSize(.small)
        }
    }
}

/// Makes the menu in a window that is never shown and gives back its items as SwiftUI fills them for AppKit to show,
/// or why there are none.
@MainActor
func opened<Content: View>(_ content: Content) async -> Result<[NSMenuItem], Missing> {
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 320, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = NSHostingView(rootView: content)
    window.layoutIfNeeded()
    window.displayIfNeeded()
    await settle()
    guard let host = window.contentView else { return .failure(Missing("the window has no content")) }
    // A menu of the menu style is a pull-down NSPopUpButton, whose menu SwiftUI fills when AppKit says it is about to
    // show it: ask it as AppKit does, and nothing is shown.
    if let button = views(in: host).compactMap({ $0 as? NSPopUpButton }).first {
        guard let cell = button.cell as? NSPopUpButtonCell, let menu = cell.menu else {
            return .failure(Missing("the menu's NSPopUpButton has no menu"))
        }
        let willShow = NSSelectorFromString("popUpButtonCell:willShowMenu:")
        guard let filler = menu.delegate as? NSObject, filler.responds(to: willShow) else {
            return .failure(Missing("the menu's delegate does not fill it as AppKit is about to show it: SwiftUI fills its menus another way now"))
        }
        filler.perform(willShow, with: cell, with: menu)
        // A pull-down's first item is its own title, which the menu never shows as a row.
        return .success(Array(menu.items.dropFirst(cell.pullsDown ? 1 : 0)))
    }
    // Any other menu is SwiftUI's own button, which makes its NSMenu when pressed and hands it to NSMenu to pop up:
    // press it through accessibility, as VoiceOver would, with the pop-up kept off the screen.
    keepMenusOffScreen()
    _ = PoppedUp.take()
    // SwiftUI builds the elements, and allows the press, in its own time: on a busy machine (CI) the first press can
    // come too soon. So keep trying for up to ten seconds, as pi2-computer-check waits for its elements.
    var found = false, pressed = false
    let deadline = Date().addingTimeInterval(10)
    while !pressed, Date() < deadline {
        if let button = elements(under: host).first(where: { read($0, "accessibilityRole") as? String == "AXMenuButton" }) {
            found = true
            pressed = press(button)
        }
        if !pressed { try? await Task.sleep(for: .milliseconds(50)) }
    }
    guard found else {
        return .failure(Missing("the menu is neither an NSPopUpButton nor a menu button among the window's accessibility elements: SwiftUI draws its menus another way now"))
    }
    guard pressed else { return .failure(Missing("the menu's button did not take a press in ten seconds", pressless: true)) }
    for _ in 0..<20 where PoppedUp.menus.isEmpty { await settle() }
    guard let menu = PoppedUp.take().first else {
        return .failure(Missing("no NSMenu was handed to NSMenu to pop up when the menu's button was pressed: SwiftUI shows its menus another way now"))
    }
    return .success(menu.items)
}

struct Missing: Error {
    let why: String
    /// The menu's button was found but would not take a press: the machine's, not the menu's.
    var pressless = false
    init(_ why: String, pressless: Bool = false) {
        self.why = why
        self.pressless = pressless
    }
}

// MARK: - Reading it

/// One item as AppKit holds it.
struct ReadItem {
    var title: String
    var image: NSImage?
    var separator = false
    var header = false
    var submenu: [ReadItem]?

    /// How the item reads, for a failure's detail: `"Atlas" [image 16×16]`.
    var described: String {
        if separator { return "—" }
        var text = (header ? "heading " : "") + "\"\(title)\""
        if let image { text += " [image \(Int(image.size.width))×\(Int(image.size.height))\(image.isTemplate ? ", template" : "")]" }
        if let submenu { text += " { " + submenu.map(\.described).joined(separator: ", ") + " }" }
        return text
    }
}

@MainActor
func read(_ items: [NSMenuItem]) -> [ReadItem] {
    items.map { item in
        ReadItem(title: item.title, image: item.image, separator: item.isSeparatorItem, header: item.isSectionHeader,
                 submenu: item.submenu.map { read($0.items) })
    }
}

/// The rows a person chooses from: no separators or headings, and a submenu's rows in place of its title.
func rows(_ items: [ReadItem]) -> [ReadItem] {
    items.flatMap { item -> [ReadItem] in
        if item.separator || item.header { return [] }
        return item.submenu.map(rows) ?? [item]
    }
}

/// What is wrong with the rows read, against the names they stand for, in order; empty when nothing is.
func problems(_ items: [ReadItem], names: [String], avatars: Bool = false, ticked: Set<String> = []) -> [String] {
    let read = rows(items)
    var found: [String] = []
    if read.map(\.title) != names {
        found.append("the rows are \(read.map { "\"\($0.title)\"" }.joined(separator: ", ")), not \(names.map { "\"\($0)\"" }.joined(separator: ", "))")
    }
    for item in read {
        if item.title.trimmingCharacters(in: .whitespaces).isEmpty { found.append("a row has no title: \(item.described)") }
        if item.title.count == 1 { found.append("a row's title is one letter: \(item.described)") }
        if avatars {
            if let image = item.image {
                if image.size != NSSize(width: AvatarImage.menuSize, height: AvatarImage.menuSize) || image.isTemplate {
                    found.append("\"\(item.title)\" has an image that is not its avatar at the menu's size: \(item.described)")
                }
            } else {
                found.append("\"\(item.title)\" has no avatar: \(item.described)")
            }
        } else if ticked.contains(item.title) != (item.image != nil) {
            found.append(ticked.contains(item.title) ? "\"\(item.title)\" is chosen but shows no tick: \(item.described)"
                : "\"\(item.title)\" is not chosen but shows an image: \(item.described)")
        }
    }
    return found
}

// MARK: - Pictures of the rows as read

/// Draws the rows as read: each item's image and title, the way a menu lays them out, in the appearance given.
@MainActor
func picture(of items: [ReadItem], heading: String, dark: Bool) -> NSImage {
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
    let font = NSFont.menuFont(ofSize: 13)
    let lines = items.flatMap { item -> [ReadItem] in
        guard let submenu = item.submenu else { return [item] }
        return [ReadItem(title: item.title + " ▸", image: item.image)] + submenu.map { var sub = $0; sub.title = "    " + sub.title; return sub }
    }
    let rowHeight: CGFloat = 22, inset: CGFloat = 6, imageColumn: CGFloat = 26
    let widest = lines.map { ($0.title as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
    let caption = "\(heading), as AppKit holds its items" as NSString
    let captionFont = NSFont.systemFont(ofSize: 11)
    let width = max(widest + imageColumn + 3 * inset + 20, caption.size(withAttributes: [.font: captionFont]).width + 2 * inset)
    let menuHeight = CGFloat(lines.count) * rowHeight + 2 * inset
    let size = NSSize(width: width + 2 * inset, height: menuHeight + 28)
    return NSImage(size: size, flipped: true) { _ in
        appearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: size).fill()
            caption.draw(at: NSPoint(x: inset, y: 6), withAttributes: [.font: captionFont, .foregroundColor: NSColor.secondaryLabelColor])
            let box = NSRect(x: inset, y: 24, width: width, height: menuHeight)
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
            NSColor.separatorColor.setStroke()
            NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).stroke()
            for (index, item) in lines.enumerated() {
                let top = box.minY + inset + CGFloat(index) * rowHeight
                if item.separator {
                    NSColor.separatorColor.setFill()
                    NSRect(x: box.minX + inset, y: top + rowHeight / 2, width: box.width - 2 * inset, height: 1).fill()
                    continue
                }
                if let image = item.image {
                    let fit = min(1, 16 / max(image.size.width, image.size.height))
                    let drawn = NSSize(width: image.size.width * fit, height: image.size.height * fit)
                    let rect = NSRect(x: box.minX + inset + (imageColumn - drawn.width) / 2 - 2, y: top + (rowHeight - drawn.height) / 2,
                                      width: drawn.width, height: drawn.height)
                    if image.isTemplate {
                        let tinted = NSImage(size: image.size, flipped: false) { bounds in
                            image.draw(in: bounds)
                            NSColor.labelColor.set()
                            bounds.fill(using: .sourceAtop)
                            return true
                        }
                        tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    } else {
                        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    }
                }
                let attributes: [NSAttributedString.Key: Any] = item.header
                    ? [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]
                    : [.font: font, .foregroundColor: NSColor.labelColor]
                let text = item.title as NSString
                let height = text.size(withAttributes: attributes).height
                text.draw(at: NSPoint(x: box.minX + inset + imageColumn, y: top + (rowHeight - height) / 2), withAttributes: attributes)
            }
        }
        return true
    }
}

@MainActor
func save(_ image: NSImage, to url: URL) {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: url)
}

// MARK: - The menus

/// The avatar as the app's views draw it, which is what the Give to menu's rows held before #597.
private struct OldAvatar: View {
    let name: String
    var body: some View {
        RoundedRectangle(cornerRadius: 16 * 0.32, style: .continuous)
            .fill(Color(nsColor: NSColor(srgbRed: 0xB9 / 255, green: 0xA6 / 255, blue: 0xFF / 255, alpha: 1)))
            .frame(width: 16, height: 16)
            .overlay {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: 8, weight: .bold, design: .rounded))
            }
            .accessibilityHidden(true)
    }
}

/// Agents named as the owner's were when the fault was seen, all beginning alike, and one that does not.
let checkedAgents = ["Pi Squared Worker", "Pi Squared Worker (Sonnet)", "Pi Squared Worker 2", "Pi Squared Worker 3", "Pi Squared Worker 4", "Atlas"]
private let agentHexes: [UInt32] = [0xB9A6FF, 0x9FC5FF, 0x7FD8C4, 0xA8E39A, 0xF5D77A, 0xFFB37A]
private let agentColors: [NSColor] = agentHexes.map(color)

private func color(_ hex: UInt32) -> NSColor {
    let red = CGFloat((hex >> 16) & 0xFF) / 255
    let green = CGFloat((hex >> 8) & 0xFF) / 255
    let blue = CGFloat(hex & 0xFF) / 255
    return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
}

/// An agent as the app's menus make one (`MenuChoice(agent:)` in the app): its name and its avatar drawn for a menu.
@MainActor
private func agentChoices() -> [MenuChoice] {
    checkedAgents.enumerated().map { index, name in
        MenuChoice(id: "a\(index)", title: name, image: AvatarImage.image(name: name, color: agentColors[index % agentColors.count]))
    }
}

/// Each menu of the projects screens, with what its rows stand for.
@MainActor
private func checkedMenus() -> [(name: String, slug: String, menu: AnyView, names: [String], avatars: Bool, ticked: Set<String>)] {
    let models = MenuChoiceGroup(id: "anthropic", title: "Anthropic", choices: ["Claude Opus 4.5", "Claude Sonnet 4.5", "Claude Haiku 4.5"].enumerated().map {
        MenuChoice(id: "anthropic/\($0.offset)", title: $0.element, ticked: $0.offset == 1)
    })
    // More than twelve, which makes a submenu of its own.
    let many = MenuChoiceGroup(id: "openrouter", title: "OpenRouter", choices: (1...14).map { MenuChoice(id: "openrouter/\($0)", title: "Model \($0) (added by hand)") })
    let binds = ["Orchestrator", "Every agent"]
    let projects = ["Demo project", "pi2", "A project with a long name for its column"]
    return [
        ("the Work tab's Give to menu", "give-to", AnyView(MenuButton(label: "Give to") { MenuChoices(agentChoices()) { _ in } }), checkedAgents, true, []),
        ("the Agents tab's From a Template menu", "from-a-template", AnyView(MenuButton(label: "From a Template", style: .piSecondary) { MenuChoices(agentChoices()) { _ in } }), checkedAgents, true, []),
        ("the hub bar's and Settings tab's model menu", "model", AnyView(MenuButton(label: "Orchestrator · Claude Sonnet 4.5") {
            GroupedMenuChoices([models, many]) { _ in }
            Divider()
            Button("Connect More Providers…") {}
        }), models.choices.map(\.title) + many.choices.map(\.title) + ["Connect More Providers…"], false, ["Claude Sonnet 4.5"]),
        ("the Rules tab's whom-it-binds menu", "binds", AnyView(MenuButton(label: "Every agent") {
            MenuChoices(binds.map { MenuChoice(id: $0, title: $0, ticked: $0 == "Every agent") }) { _ in }
        }), binds, false, ["Every agent"]),
        ("the Dashboard's Projects… menu", "projects", AnyView(MenuButton(label: "Projects…") {
            MenuChoices(projects.map { MenuChoice(id: $0, title: $0, ticked: $0 != "pi2") }) { _ in }
        }), projects, false, ["Demo project", "A project with a long name for its column"]),
        // Fixed words, made with Button as the app makes them.
        ("the Work tab's Classify menu", "classify", AnyView(MenuButton(label: "Classify") {
            Button("Local model") {}
            Button("Cloud model") {}
            Button("Not classified") {}
        }), ["Local model", "Cloud model", "Not classified"], false, []),
        ("the Work tab's Close menu", "close", AnyView(MenuButton(label: "Close") {
            Button("Close as Done") {}
            Button("Close as Dropped") {}
        }), ["Close as Done", "Close as Dropped"], false, []),
    ]
}

@MainActor
func menuCheck(pictures: URL?) async {
    // What an assistive app asks of an app it connects to; SwiftUI builds its accessibility elements, the menu buttons
    // the check presses among them, once it is set. Set before any of the check's windows is made, as
    // pi2-computer-check sets it, and through the selector, since the attribute API it belongs to is deprecated.
    let enhance = NSSelectorFromString("accessibilitySetValue:forAttribute:")
    _ = NSApp.perform(enhance, with: NSNumber(value: true), with: "AXEnhancedUserInterface")
    defer { _ = NSApp.perform(enhance, with: NSNumber(value: false), with: "AXEnhancedUserInterface") }
    // The rows as they were: an avatar beside the name in a stack. What they come out as is the reason for all this.
    let before = await opened(MenuButton(label: "Give to") {
        ForEach(checkedAgents, id: \.self) { name in
            Button {} label: { HStack(spacing: 6) { OldAvatar(name: name); Text(name) } }
        }
    })
    switch before {
    case .success(let before):
        let items = read(before)
        let found = problems(items, names: checkedAgents, avatars: true)
        print(found.isEmpty
            ? "note  the rows the Give to menu had before #597 now come out whole, so that comparison shows nothing here"
            : "ok    before #597, the Give to menu's rows came out as \(rows(items).map { "\"\($0.title)\"" }.joined(separator: ", ")), which this check fails")
        if let pictures {
            for dark in [true, false] {
                save(picture(of: items, heading: "Give to before #597", dark: dark), to: pictures.appendingPathComponent("give-to-before-\(dark ? "dark" : "light").png"))
            }
        }
    case .failure(let missing):
        print("note  the Give to menu as it was before #597 could not be read: \(missing.why)")
    }

    await sourceCheck()

    for (name, slug, menu, names, avatars, ticked) in checkedMenus() {
        await group("\(name) shows each row's whole name\(avatars ? ", with its avatar" : "")") {
            var items: [ReadItem] = []
            switch await opened(menu) {
            case .success(let opened): items = read(opened)
            case .failure(let missing) where missing.pressless && slug == "from-a-template":
                // A menu with a button style of its own can only be pressed through accessibility, and a machine
                // whose accessibility server never lets it be pressed (it happened on CI) would fail here for nothing
                // the app did. Its rows are the same MenuChoices as Give to's, so read them in a menu-style menu instead.
                print("note  \(name): \(missing.why), so its rows are read in a menu of the menu style")
                switch await opened(MenuButton(label: "From a Template") { MenuChoices(agentChoices()) { _ in } }) {
                case .success(let opened): items = read(opened)
                case .failure(let again):
                    check("its menu is made and filled as AppKit is about to show it", false, again.why)
                    return
                }
            case .failure(let missing):
                check("its menu is made and filled as AppKit is about to show it", false, missing.why)
                return
            }
            let found = problems(items, names: names, avatars: avatars, ticked: ticked)
            check("each row is the name it stands for", found.isEmpty, (found + ["items: " + items.map(\.described).joined(separator: ", ")]).joined(separator: "\n      "))
            if let pictures {
                for dark in [true, false] {
                    save(picture(of: items, heading: name.prefix(1).uppercased() + name.dropFirst(), dark: dark),
                         to: pictures.appendingPathComponent("\(slug)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }
}

// MARK: - The app's own menus, read from its sources

/// The content of every menu in the app's sources (a `Menu`'s rows and a `.contextMenu(previewAs:)`'s), as file, line
/// and text. The check above makes the rows as the app does with MenuKit; this keeps the app from making a row of a
/// menu any other way that a native menu cannot draw.
func menuContents(in folder: URL) -> [(file: String, line: Int, text: String)] {
    let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    var found: [(String, Int, String)] = []
    for file in files.filter({ $0.pathExtension == "swift" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
        let text = Array(source.unicodeScalars)
        let starts = ["Menu {", "Menu(\"", ".contextMenu(previewAs:"]
        var index = 0
        while index < text.count {
            guard let start = starts.first(where: { index + $0.unicodeScalars.count <= text.count && String(String.UnicodeScalarView(text[index..<index + $0.unicodeScalars.count])) == $0 }),
                  index == 0 || !CharacterSet.alphanumerics.contains(text[index - 1]) || start.hasPrefix(".") else {
                index += 1
                continue
            }
            // The menu's content: the first block in braces after it, matched brace for brace.
            guard let open = text[index...].firstIndex(of: "{") else { break }
            var depth = 0, end = open
            for at in open..<text.count {
                if text[at] == "{" { depth += 1 } else if text[at] == "}" { depth -= 1; if depth == 0 { end = at; break } }
            }
            let line = text[..<index].filter { $0 == "\n" }.count + 1
            found.append((file.lastPathComponent, line, String(String.UnicodeScalarView(text[(open + 1)..<end]))))
            index = open + 1
        }
    }
    return found
}

/// What in a menu's content a native menu does not draw as written: a stack, a shape or an avatar made of them.
let undrawable = ["HStack", "VStack", "ZStack", "AgentAvatar(", "RoundedRectangle(", "Circle(", "Capsule(", ".overlay"]

@MainActor
func sourceCheck() async {
    // This file is in Sources/pi2-window-check; the app's are beside it in Sources/pi2.
    let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("pi2")
    await group("no menu in the app's sources makes a row a native menu cannot draw") {
        let menus = menuContents(in: folder)
        check("the app's menus are found in its sources", menus.count >= 20, "\(menus.count) found in \(folder.path)")
        for menu in menus {
            let wrong = undrawable.filter { menu.text.contains($0) }
            check("\(menu.file):\(menu.line): a row is made with \(wrong.joined(separator: ", "))", wrong.isEmpty,
                  "a native menu draws a row as one text and one picture: use MenuKit's MenuRow, with the picture drawn first (AvatarImage)")
        }
    }
}
