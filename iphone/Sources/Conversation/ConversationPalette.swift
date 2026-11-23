import SwiftUI
import UIKit

/// The colours the conversation's screen draws with beyond the system's own and the app's shared ones
/// (`UIColor.pi2Accent`, `AgentColor` in `App/Shared/`): what is written on the accent, as the Mac's `PiStyle` has it.
enum ConversationColors {
    /// What is written on the accent.
    static let onAccent = UIColor { $0.userInterfaceStyle == .dark ? rgb(0x10112A) : rgb(0xFFFFFF) }

    /// An agent's colour by the name the engine gives it, the app's shared pastels (`AgentColor`).
    static func agent(_ name: String?) -> UIColor {
        UIColor(AgentColor.color(name))
    }

    static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// The page's palette (docs/transcript.md, "Messages between the app and the page"): the system's semantic colours,
/// resolved for one appearance as CSS colours, so that the page looks like the screen around it.
enum ConversationPalette {
    static func colors(for traits: UITraitCollection) -> [String: String] {
        let named: [(String, UIColor)] = [
            ("window", .systemBackground), ("panel", .secondarySystemBackground), ("card", .secondarySystemBackground),
            ("card2", .systemGray5), ("line", .separator), ("line2", .opaqueSeparator),
            ("tx", .label), ("tx2", .secondaryLabel), ("tx3", .tertiaryLabel),
            ("acc", UIColor.pi2Accent), ("ok", .systemGreen), ("warn", .systemOrange), ("bad", .systemRed),
            ("on-acc", ConversationColors.onAccent),
        ]
        var result = ["appearance": traits.userInterfaceStyle == .dark ? "dark" : "light"]
        for (name, color) in named {
            result[name] = css(color.resolvedColor(with: traits))
        }
        return result
    }

    /// A colour as CSS `rgb()` or `rgba()`, in the form the page accepts.
    static func css(_ color: UIColor) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        // A colour outside sRGB comes in extended values; the page takes 0 to 255.
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        let a = min(max(alpha, 0), 1)
        return a >= 0.999
            ? "rgb(\(byte(red)), \(byte(green)), \(byte(blue)))"
            : String(format: "rgba(%d, %d, %d, %.3f)", byte(red), byte(green), byte(blue), a)
    }
}
