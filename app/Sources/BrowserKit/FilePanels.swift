import AppKit

/// The app's Open and Save panels, including the browser's file input. Configure AppKit only when it will be shown.
@MainActor
package enum FilePanels {
    package enum Selection { case files, folders, filesAndFolders }

    #if PI2_DEVELOPMENT
    package enum Kind { case open(Selection, multiple: Bool), save }
    /// Installed only by the app in a test copy. An empty answer means cancel, not fall through to AppKit.
    package static var testAnswer: ((_ name: String, _ kind: Kind) -> [URL])?
    #endif

    package static func open(_ name: String, selecting: Selection, multiple: Bool = false,
                             configure: (NSOpenPanel) -> Void = { _ in }) -> [URL]? {
        #if PI2_DEVELOPMENT
        if let testAnswer {
            let urls = testAnswer(name, .open(selecting, multiple: multiple))
            return urls.isEmpty ? nil : urls
        }
        #endif
        let panel = openPanel(selecting, multiple: multiple)
        configure(panel)
        return panel.runModal() == .OK ? panel.urls : nil
    }

    package static func beginOpen(_ name: String, selecting: Selection, multiple: Bool, in window: NSWindow,
                                  completion: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        #if PI2_DEVELOPMENT
        if let testAnswer {
            let urls = testAnswer(name, .open(selecting, multiple: multiple))
            completion(urls.isEmpty ? nil : urls)
            return
        }
        #endif
        let panel = openPanel(selecting, multiple: multiple)
        panel.beginSheetModal(for: window) { response in completion(response == .OK ? panel.urls : nil) }
    }

    private static func openPanel(_ selecting: Selection, multiple: Bool) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = selecting != .folders
        panel.canChooseDirectories = selecting != .files
        panel.allowsMultipleSelection = multiple
        return panel
    }

    package static func save(_ name: String, configure: (NSSavePanel) -> Void) -> URL? {
        #if PI2_DEVELOPMENT
        if let testAnswer { return testAnswer(name, .save).first }
        #endif
        let panel = NSSavePanel()
        configure(panel)
        return panel.runModal() == .OK ? panel.url : nil
    }

    package static func beginSave(_ name: String, in window: NSWindow?, configure: (NSSavePanel) -> Void,
                                  completion: @escaping @MainActor (URL?) -> Void) {
        guard let window else { completion(save(name, configure: configure)); return }
        #if PI2_DEVELOPMENT
        if let testAnswer { completion(testAnswer(name, .save).first); return }
        #endif
        let panel = NSSavePanel()
        configure(panel)
        panel.beginSheetModal(for: window) { response in completion(response == .OK ? panel.url : nil) }
    }
}
