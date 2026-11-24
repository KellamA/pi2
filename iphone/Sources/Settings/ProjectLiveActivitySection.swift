import PiModels
import SwiftUI

/// A project's Live Activity switch (docs/iphone-app.md, "The Live Activity"; #700): off by default; on, the project's
/// numbers on the Lock Screen and in the Dynamic Island. The phone keeps which projects it follows (`PhoneSurfaces`'s
/// `activities`); turning it on starts the activity at once, in the foreground, as iOS requires, and a refusal shows
/// under it with the switch back off. Unavailable while iOS has pi²'s Live Activities off, and in the demo.
struct ProjectLiveActivitySection: View {
    let project: ProjectRow

    @Environment(AppSession.self) private var session
    @Environment(PhoneSurfaces.self) private var surfaces: PhoneSurfaces?

    static let line = "Shows how many agents are working, what needs you and what finished on the Lock Screen and in the Dynamic Island. pi²’s relay updates it while pi² is closed, so it can read these three numbers; never the project’s name or anything else."
    static let demo = "Not in the demo: a Live Activity follows a project of your Mac."

    var body: some View {
        if let following = surfaces?.activities {
            Section {
                Toggle("Live Activity", isOn: Binding(
                    get: { following.isOn(project.id) },
                    set: { on in
                        Task {
                            if on { await following.turnOn(project) } else { await following.turnOff(project.id) }
                        }
                    }
                ))
                .disabled(!available(following) || following.turning.contains(project.id))
                SettingsProblem(text: following.problems[project.id])
            } header: {
                Text("Lock Screen")
            } footer: {
                Text(footer(following))
            }
            #if DEBUG
            .task {
                if available(following), !following.isOn(project.id), SettingsSamples.shouldPress("live-activity") {
                    await following.turnOn(project)
                }
            }
            #endif
        }
    }

    private func available(_ following: ProjectActivityFollowing) -> Bool {
        following.allowed && session.connection != .demo && session.connection != .notPaired
    }

    private func footer(_ following: ProjectActivityFollowing) -> String {
        if session.connection == .demo { return Self.demo }
        if !following.allowed { return ProjectActivityRefusal.notAllowed.words }
        return Self.line
    }
}
