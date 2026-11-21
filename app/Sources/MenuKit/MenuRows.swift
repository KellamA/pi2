import AppKit
import SwiftUI

// The rows of the app's pop-up menus (#597).
//
// A SwiftUI `Menu` is drawn as a native menu, and each of its rows becomes an `NSMenuItem`, which holds one line of text
// and at most one picture. A row's label made of anything else does not come out as drawn: the Work tab's Give to menu
// once put each agent's avatar beside its name in an `HStack`, and every row came out as the avatar's letter alone, so
// five agents all called "Pi Squared Worker …" each showed "P". So every pop-up menu of the projects screens builds its
// rows here, from a text and an image already drawn, and pi2-window-check reads what AppKit makes of them.

/// One row of a pop-up menu: what it says, the picture before it if any, and whether it is the one chosen now.
package struct MenuChoice: Identifiable {
    package let id: String
    package let title: String
    package var image: NSImage?
    /// Shown with a tick, as the chosen model or a watched project is.
    package var ticked: Bool

    package init(id: String, title: String, image: NSImage? = nil, ticked: Bool = false) {
        self.id = id
        self.title = title
        self.image = image
        self.ticked = ticked
    }
}

/// A group of rows under a heading, such as one provider's models.
package struct MenuChoiceGroup: Identifiable {
    package let id: String
    package let title: String
    package let choices: [MenuChoice]

    package init(id: String, title: String, choices: [MenuChoice]) {
        self.id = id
        self.title = title
        self.choices = choices
    }
}

/// The label of one row, in the only forms a native menu draws whole: a text, or a text with one image before it.
package struct MenuRow: View {
    let choice: MenuChoice

    package init(_ choice: MenuChoice) { self.choice = choice }

    package var body: some View {
        if let image = choice.image {
            Label { Text(choice.title) } icon: { Image(nsImage: image) }
        } else if choice.ticked {
            Label(choice.title, systemImage: "checkmark")
        } else {
            Text(choice.title)
        }
    }
}

/// The rows of a menu, each a button that chooses it.
package struct MenuChoices: View {
    let choices: [MenuChoice]
    let choose: (MenuChoice) -> Void

    package init(_ choices: [MenuChoice], choose: @escaping (MenuChoice) -> Void) {
        self.choices = choices
        self.choose = choose
    }

    package var body: some View {
        ForEach(choices) { choice in
            Button { choose(choice) } label: { MenuRow(choice) }
        }
    }
}

/// Rows in groups, each under its heading: a group longer than `submenuOver` is a submenu of its own, so that a provider
/// with a hundred models does not make the menu taller than the screen.
package struct GroupedMenuChoices: View {
    let groups: [MenuChoiceGroup]
    var submenuOver = 12
    let choose: (MenuChoice) -> Void

    package init(_ groups: [MenuChoiceGroup], submenuOver: Int = 12, choose: @escaping (MenuChoice) -> Void) {
        self.groups = groups
        self.submenuOver = submenuOver
        self.choose = choose
    }

    package var body: some View {
        ForEach(groups) { group in
            if group.choices.count > submenuOver {
                Menu(group.title) { MenuChoices(group.choices, choose: choose) }
            } else if !group.choices.isEmpty {
                Section(group.title) { MenuChoices(group.choices, choose: choose) }
            }
        }
    }
}

/// An agent's avatar as a picture for a menu row: the rounded square in its colour with its initial, as `AgentAvatar`
/// draws it in the app's own views. A native menu cannot draw a SwiftUI view, so it is drawn once into an image for
/// each name, colour and size, and the image kept for the next time a menu opens.
@MainActor
package enum AvatarImage {
    /// The size a menu row's picture is drawn at, in points: the size of the pictures macOS puts in its own menus.
    nonisolated package static let menuSize: CGFloat = 16

    private static var made: [String: NSImage] = [:]

    package static func image(name: String, color: NSColor, size: CGFloat = menuSize) -> NSImage {
        let initial = String(name.prefix(1)).uppercased()
        let rgb = color.usingColorSpace(.sRGB)
        let key = "\(initial)|\(rgb.map { "\($0.redComponent),\($0.greenComponent),\($0.blueComponent)" } ?? "\(color)")|\(size)"
        if let image = made[key] { return image }
        let image = draw(initial: initial.isEmpty ? "?" : initial, color: color, size: size)
        made[key] = image
        return image
    }

    private static func draw(initial: String, color: NSColor, size: CGFloat) -> NSImage {
        let base = NSFont.systemFont(ofSize: size * 0.5, weight: .bold)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size * 0.5) } ?? base
        let letter = NSAttributedString(string: initial, attributes: [
            .font: font,
            .foregroundColor: NSColor(srgbRed: 0x15 / 255, green: 0x16 / 255, blue: 0x1C / 255, alpha: 1),
        ])
        // Drawn by AppKit at each scale the image is shown at, and kept, so the square and the letter are sharp on any
        // screen; the colours are fixed ones, the same in light and dark, as the avatar's are.
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: size * 0.32, yRadius: size * 0.32).fill()
            // The capital's middle on the square's: the point drawn at is the line's lower corner, below the baseline.
            let width = letter.size().width
            letter.draw(at: NSPoint(x: rect.midX - width / 2, y: rect.midY - font.capHeight / 2 + font.descender))
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = nil
        return image
    }
}
