import AppKit
import SwiftUI
import TranscriptKit

extension TranscriptPage {
    /// The page loaded ahead for the next pane that opens (#441), from the first pane on.
    @MainActor static let spare: SparePage? = folder.map { SparePage(folder: $0) }
}

/// pi²'s palette from `Theme`, resolved for one appearance as CSS colours for the page.
enum TranscriptPalette {
    @MainActor
    static func colors(for appearance: NSAppearance) -> [String: String] {
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let named: [(String, Color)] = [
            ("window", Theme.window), ("panel", Theme.panel), ("card", Theme.card), ("card2", Theme.card2),
            ("line", Theme.line), ("line2", Theme.line2), ("tx", Theme.tx), ("tx2", Theme.tx2), ("tx3", Theme.tx3),
            ("acc", Theme.acc), ("ok", Theme.ok), ("warn", Theme.warn), ("bad", Theme.bad), ("on-acc", Theme.onAcc),
        ]
        var result = ["appearance": isDark ? "dark" : "light"]
        appearance.performAsCurrentDrawingAppearance {
            for (name, color) in named {
                if let css = css(color) { result[name] = css }
            }
        }
        return result
    }

    /// A colour as CSS `rgb()` or `rgba()`, resolved in the current drawing appearance.
    static func css(_ color: Color) -> String? {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        let r = Int((rgb.redComponent * 255).rounded()), g = Int((rgb.greenComponent * 255).rounded()), b = Int((rgb.blueComponent * 255).rounded())
        let alpha = rgb.alphaComponent
        return alpha >= 0.999 ? "rgb(\(r), \(g), \(b))" : String(format: "rgba(%d, %d, %d, %.3f)", r, g, b, alpha)
    }
}
