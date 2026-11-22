
import SwiftUI

/// The connection bar: which Mac, and how this iPhone reaches it (docs/design/iphone.md, "The projects list" and "The
/// phone when the Mac is asleep or out of reach"). It reads the session and nothing else, so any screen can show it as
/// it is: `HomeConnectionBar()`. Tapping it says what can be done from here.
struct HomeConnectionBar: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .footnote) private var dot: CGFloat = 8
    #if DEBUG
    @State private var explaining = HomeDebugLaunch.explains
    #else
    @State private var explaining = false
    #endif

    var body: some View {
        let reading = Reading(session.connection, mac: session.macName)
        Button { explaining = true } label: {
            // The dot on the first line, about the middle of its letters, so that it stays by the first words when the
            // line wraps; at the largest text sizes "Why" goes under the line, which keeps the room for the words.
            let large = typeSize.isAccessibilitySize
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Group {
                    if reading.tone == .busy {
                        ProgressView().controlSize(.mini)
                    } else {
                        Circle().fill(reading.tone.color).frame(width: dot, height: dot)
                    }
                }
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + dot * 0.55 }
                .frame(minWidth: 14)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(reading.line)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    if large { trailing(reading) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !large { trailing(reading) }
            }
            .font(.footnote)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(reading.tone == .warn ? Color.orange.opacity(0.55) : Color(.separator).opacity(0.5))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(reading.line)
        .accessibilityHint("Says what can be done from here")
        .sheet(isPresented: $explaining) {
            HomeConnectionDetail(reading: reading)
        }
    }

    /// "Why" where something is wrong, else the sign that tapping says more.
    private func trailing(_ reading: Reading) -> some View {
        Group {
            if reading.tone == .warn {
                Text("Why").foregroundStyle(.tint)
            } else {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
        }
        .accessibilityHidden(true)
    }

    /// What the bar says of a state of the connection, and what tapping it explains.
    struct Reading: Equatable {
        enum Tone: Equatable {
            /// Connected, every path it needs working.
            case ok
            /// Reachable only in part, or not at all.
            case warn
            /// Reaching for the Mac.
            case busy
            /// The demo mode.
            case demo
            /// Nothing paired.
            case none

            var color: Color {
                switch self {
                case .ok: .green
                case .warn: .orange
                case .busy, .demo: .accentColor
                case .none: .secondary
                }
            }
        }

        let line: String
        let tone: Tone
        let title: String
        let explanation: String

        init(_ connection: AppSession.Connection, mac: String?, now: Date = Date()) {
            // The Mac's name, or "your Mac" in a sentence and "Your Mac" at the start of one.
            let named = mac
            let mac = named ?? String(localized: "your Mac")
            let Mac = named ?? String(localized: "Your Mac")
            switch connection {
            case .notPaired:
                line = String(localized: "No Mac paired")
                tone = .none
                title = line
                explanation = String(localized: "Pair this iPhone with pi² on a Mac to see its projects here: on the Mac, pi² › Settings › Devices › Pair an iPhone.")
            case .demo:
                line = String(localized: "Demo · no Mac")
                tone = .demo
                title = String(localized: "The demo")
                explanation = String(localized: "Made-up projects, to show what pi² does. Nothing here reaches a Mac, and nothing is sent anywhere.")
            case .connecting:
                line = String(localized: "Reaching \(mac)…")
                tone = .busy
                title = line
                explanation = String(localized: "pi² is reaching \(mac), over this network or through pi²'s relay, whichever answers first. Everything shows once it does.")
            case .connected(let path, let relayReachable):
                switch (path, relayReachable) {
                case (.home, true):
                    line = String(localized: "\(Mac) · at home")
                    tone = .ok
                    title = String(localized: "At home")
                    explanation = String(localized: "This iPhone reaches \(mac) directly, over this network. Everything pi² does on the Mac can be done from here.")
                case (.relay, _):
                    line = String(localized: "\(Mac) · through pi²'s relay")
                    tone = .ok
                    title = String(localized: "Through pi²'s relay")
                    explanation = String(localized: "This iPhone reaches \(mac) through pi²'s relay, which passes only sealed messages and can read none of them. Everything works from here, the live conversation included, on any network.")
                case (.direct, true):
                    line = String(localized: "\(Mac) · direct")
                    tone = .ok
                    title = String(localized: "Direct")
                    explanation = String(localized: "This iPhone reaches \(mac) straight at another of its addresses, such as a private network's. Everything pi² does on the Mac can be done from here.")
                case (.home, false):
                    line = String(localized: "\(Mac) · at home · relay unreachable")
                    tone = .warn
                    title = String(localized: "Relay unreachable · at home only")
                    explanation = String(localized: "Everything works here, on this network. Away from home, and for notifications while the app is closed, pi² needs its relay; it will be used again as soon as it answers.")
                case (.direct, false):
                    line = String(localized: "\(Mac) · direct · relay unreachable")
                    tone = .warn
                    title = String(localized: "Relay unreachable · direct only")
                    explanation = String(localized: "Everything works while this network reaches the Mac directly. Elsewhere, and for notifications while the app is closed, pi² needs its relay; it will be used again as soon as it answers.")
                }
            case .outOfReach(let lastSeen):
                let seen = lastSeen.map { HomeTime.lastSeen($0, now: now) }
                line = seen.map { String(localized: "\(Mac) out of reach · last seen \($0)") } ?? String(localized: "\(Mac) out of reach")
                tone = .warn
                title = String(localized: "\(Mac) out of reach")
                let shown = seen.map { String(localized: "What shows here is as this iPhone last saw it, at \($0).") }
                    ?? String(localized: "This iPhone has not heard from it yet.")
                explanation = String(localized: "\(Mac) cannot be reached: it may be asleep or off, or no network reaches it. \(shown) pi² connects again by itself as soon as the Mac can be reached.")
            }
        }
    }
}

/// What tapping the connection bar shows: what its state means, and what can be done from here.
private struct HomeConnectionDetail: View {
    let reading: HomeConnectionBar.Reading
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .headline) private var dot: CGFloat = 10

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Label {
                        Text(reading.line).font(.headline)
                    } icon: {
                        Circle().fill(reading.tone.color).frame(width: dot, height: dot)
                    }
                    Text(reading.explanation)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .navigationTitle(reading.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // Whole at once at the largest text sizes, where half the screen holds a line or two.
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
    }
}
