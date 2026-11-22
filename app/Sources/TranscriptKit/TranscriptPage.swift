import Foundation

/// The transcript page in the app bundle, put there by app/build.sh. A bare `swift build` has no bundle to carry it,
/// and the app shows the SwiftUI transcript instead.
public enum TranscriptPage {
    public static let folder: URL? = {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let folder = resources.appendingPathComponent("transcript", isDirectory: true)
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent("index.html").path) ? folder : nil
    }()
}
