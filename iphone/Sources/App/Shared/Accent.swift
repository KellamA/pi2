import SwiftUI
import UIKit

extension Color {
    /// pi²'s accent, the Mac's (`Theme.acc` in app/Sources/PiStyle): a violet-blue, lighter in dark mode. The app's root
    /// sets it as the tint, so every button, link and toggle takes it with nothing set on a screen of its own.
    static let pi2Accent = Color(uiColor: UIColor { traits in
        let hex: UInt32 = traits.userInterfaceStyle == .dark ? 0x8B93FF : 0x5B62E8
        return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    })
}
