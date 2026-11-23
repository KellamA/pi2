import SwiftUI
import WidgetKit

/// pi²'s widgets (docs/iphone.md 12.2, P31), an empty shell for now: one placeholder widget that says it is not built
/// yet. #699 fills it with Needs you, Who is working and Today's spending, read from the app's store, `privacySensitive`
/// on the Lock Screen and in StandBy; #700 (P30) adds the Live Activity and the Dynamic Island in `LiveActivity/`, and
/// its widget to this bundle. What the widgets share with the app goes in `Shared/`, which is built into both; how the
/// extensions are put together is "The extensions" in docs/iphone-app.md.
@main
struct PiWidgets: WidgetBundle {
    var body: some Widget {
        WidgetsPlaceholder()
    }
}

/// Says the widgets are not built yet. #699 replaces it with its own.
struct WidgetsPlaceholder: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.pi2.ios.widgets.placeholder", provider: WidgetsPlaceholderTimeline()) { _ in
            Text("pi²'s widgets are not built yet (#699).")
                .font(.footnote)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("pi²")
        .description("Not built yet: #699.")
    }
}

struct WidgetsPlaceholderEntry: TimelineEntry {
    let date: Date
}

/// One entry, never refreshed.
struct WidgetsPlaceholderTimeline: TimelineProvider {
    func placeholder(in context: Context) -> WidgetsPlaceholderEntry {
        WidgetsPlaceholderEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (WidgetsPlaceholderEntry) -> Void) {
        completion(WidgetsPlaceholderEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetsPlaceholderEntry>) -> Void) {
        completion(Timeline(entries: [WidgetsPlaceholderEntry(date: .now)], policy: .never))
    }
}
