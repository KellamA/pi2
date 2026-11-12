import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Takes a picture of one window, wherever it is: behind other windows or on another desktop.
enum WindowCapture {
    /// Whether macOS lets this process see other apps' windows. Asking is silent; nothing here ever shows the prompt.
    static var permitted: Bool { CGPreflightScreenCaptureAccess() }

    struct Shot {
        let jpeg: Data
        /// Pixels per point: a point `p` in the window is at `p * scale` in the picture.
        let scale: CGFloat
        let windowID: CGWindowID
    }

    /// The window of `pid` whose frame matches `frame` (as accessibility reports it), for capture and for clicks.
    static func window(pid: pid_t, frame: CGRect) async -> SCWindow? {
        guard permitted, let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return nil }
        let own = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 1 }
        let close: (CGRect, CGRect) -> Bool = { a, b in
            abs(a.minX - b.minX) < 3 && abs(a.minY - b.minY) < 3 && abs(a.width - b.width) < 3 && abs(a.height - b.height) < 3
        }
        return own.first { close($0.frame, frame) } ?? own.filter(\.isOnScreen).max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// A picture no larger than `limit` pixels on its longer side: enough to read, small enough to be cheap to send.
    static func capture(_ window: SCWindow, frame: CGRect, limit: CGFloat = 1280) async -> Shot? {
        let scale = min(2, limit / max(frame.width, 1), limit / max(frame.height, 1))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((frame.width * scale).rounded()))
        configuration.height = max(1, Int((frame.height * scale).rounded()))
        configuration.showsCursor = false
        // Without this the picture includes the window's shadow, and every position in it would be off by its width.
        configuration.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: window)
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.72]) else { return nil }
        return Shot(jpeg: jpeg, scale: CGFloat(image.width) / max(frame.width, 1), windowID: window.windowID)
    }
}
