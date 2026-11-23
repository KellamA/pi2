import Foundation
import WidgetKit
import os

/// The app's side of the widgets' file: `App/` gives it a new `WidgetsSnapshot` whenever what the client holds changes,
/// and it writes the file a moment later, only when the snapshot is not the one written last, then asks WidgetKit to
/// draw the widgets again. The engine sends many lines a second while an agent works; the widgets need not be drawn for
/// each, and WidgetKit counts the reloads an app asks for while it is not in the foreground.
@MainActor
final class WidgetsPublisher {
    /// How long a change waits before it is written, so that a burst of events is one write.
    static let delay: Duration = .seconds(2)

    private let file: WidgetsFile
    private let reload: @MainActor () -> Void
    private var written: WidgetsSnapshot?
    private var pending: WidgetsSnapshot?
    private var task: Task<Void, Never>?
    private let log = Logger(subsystem: "dev.pi2.ios", category: "widgets")

    init(file: WidgetsFile = .standard, reload: @escaping @MainActor () -> Void = { WidgetCenter.shared.reloadAllTimelines() }) {
        self.file = file
        self.reload = reload
    }

    /// Takes the latest snapshot; it is written after `delay`, or at `flush()`.
    func update(_ snapshot: WidgetsSnapshot) {
        pending = snapshot
        guard task == nil else { return }
        task = Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Writes what waits now: when the app leaves the foreground, so that the widgets show the phone's last state.
    func flush() {
        task?.cancel()
        task = nil
        guard let snapshot = pending else { return }
        pending = nil
        // The time alone moving on is no reason to draw the widgets again, unless their "Updated" would be well behind.
        guard written.map({ !Self.same($0, snapshot) }) ?? true else { return }
        do {
            try file.write(snapshot)
            written = snapshot
            reload()
        } catch {
            log.error("The widgets' file could not be written: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes the file and draws the widgets with nothing: when the store is wiped, the phone is unpaired, or the demo
    /// starts, whose values are not the Mac's.
    func clear() {
        task?.cancel()
        task = nil
        pending = nil
        written = nil
        file.remove()
        reload()
    }

    /// How far behind the file's "Updated" may fall while nothing else changes.
    static let staleAfter: TimeInterval = 15 * 60

    private static func same(_ a: WidgetsSnapshot, _ b: WidgetsSnapshot) -> Bool {
        guard abs(b.heardAt.timeIntervalSince(a.heardAt)) < staleAfter else { return false }
        var a = a
        a.heardAt = b.heardAt
        return a == b
    }
}
