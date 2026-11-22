
import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Takes a picture of one window, wherever it is: behind other windows or on another desktop.
package enum WindowCapture {
    /// Whether macOS lets this process see other apps' windows. Asking is silent; nothing here ever shows the prompt.
    static var permitted: Bool { CGPreflightScreenCaptureAccess() }

    struct Shot {
        let jpeg: Data
        /// Pixels per point: a point `p` in the window is at `p * scale` in the picture.
        let scale: CGFloat
        let windowID: CGWindowID
    }

    /// Keep the picture, controls and input on the same window, even when it isn't at layer zero.
    static func window(pid: pid_t, frame: CGRect, id: CGWindowID?) async -> SCWindow? {
        guard permitted, let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return nil }
        let own = content.windows.filter { $0.owningApplication?.processID == pid }
        return own.first {
            if let id { return $0.windowID == id }
            let rect = $0.frame
            return abs(rect.minX - frame.minX) < 3 && abs(rect.minY - frame.minY) < 3 && abs(rect.width - frame.width) < 3 && abs(rect.height - frame.height) < 3
        }
    }

    /// How a window of `frame` is pictured: no larger than `limit` pixels on its longer side, enough to read and
    /// small enough to be cheap to send, and of that window alone. The controls are given in `frame`, so the
    /// picture has to be exactly it for a point read off the picture to be the point clicked (#798).
    package static func configuration(for frame: CGRect, limit: CGFloat = 1280) -> SCStreamConfiguration {
        let scale = min(2, limit / max(frame.width, 1), limit / max(frame.height, 1))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((frame.width * scale).rounded()))
        configuration.height = max(1, Int((frame.height * scale).rounded()))
        configuration.showsCursor = false
        // Without this the picture includes the window's shadow, and every position in it would be off by its width.
        configuration.ignoreShadowsSingleWindow = true
        // ScreenCaptureKit draws a window together with the windows attached to it: a sheet with the window it is
        // over, at that window's size, scaled into the sheet's (#793), or, for a parked test copy, not at all. The
        // window alone is what the controls are measured against.
        configuration.includeChildWindows = false
        return configuration
    }

    /// Whether a picture that came back `size` pixels is the window of `frame` at one scale on both axes, as the
    /// controls' positions take it; anything else would put them somewhere else in it.
    package static func fits(_ size: CGSize, frame: CGRect) -> Bool {
        guard frame.width >= 1, frame.height >= 1, size.width >= 1, size.height >= 1 else { return false }
        let scale = size.width / frame.width
        return abs(frame.height * scale - size.height) <= 1
    }

    static func capture(_ window: SCWindow, frame: CGRect, limit: CGFloat = 1280) async -> Shot? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration(for: frame, limit: limit)),
              fits(CGSize(width: image.width, height: image.height), frame: frame) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.72]) else { return nil }
        return Shot(jpeg: jpeg, scale: CGFloat(image.width) / max(frame.width, 1), windowID: window.windowID)
    }
}
