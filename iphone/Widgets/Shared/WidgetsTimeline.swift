import SwiftUI
import WidgetKit

/// A widget as WidgetKit draws it: the shared view, with its background, and private where it is drawn so.
struct WidgetsEntryView: View {
    let kind: WidgetsKind
    let entry: WidgetsEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.showsWidgetContainerBackground) private var showsBackground

    var body: some View {
        WidgetsView(kind: kind, snapshot: entry.snapshot, family: family)
            .environment(\.widgetsArePrivate, WidgetsPrivacy.isPrivate(family, showsBackground: showsBackground))
            .containerBackground(for: .widget) { WidgetsColor.background }
    }
}

struct WidgetsEntry: TimelineEntry {
    let date: Date
    /// Nil when there is nothing to draw: the widget says to open pi².
    let snapshot: WidgetsSnapshot?
}

/// Reads the widgets' file. The app asks WidgetKit to draw again whenever it writes it, so the timeline holds what the
/// file says now, and, while that is drawn, an entry with nothing at the moment it is too old to draw.
struct WidgetsTimeline: TimelineProvider {
    var file = WidgetsFile.standard

    func placeholder(in context: Context) -> WidgetsEntry {
        WidgetsEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (WidgetsEntry) -> Void) {
        completion(WidgetsEntry(date: Date(), snapshot: file.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetsEntry>) -> Void) {
        completion(Self.timeline(file.read(), now: Date()))
    }

    static func timeline(_ snapshot: WidgetsSnapshot?, now: Date) -> Timeline<WidgetsEntry> {
        var entries = [WidgetsEntry(date: now, snapshot: snapshot)]
        if let snapshot {
            entries.append(WidgetsEntry(date: snapshot.heardAt.addingTimeInterval(WidgetsSnapshot.keptFor), snapshot: nil))
        }
        return Timeline(entries: entries, policy: .never)
    }
}
