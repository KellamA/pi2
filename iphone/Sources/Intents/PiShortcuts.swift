
import AppIntents

/// The phrases Siri knows and the Shortcuts app offers without the person making a shortcut (docs/design/iphone.md,
/// "What a phone adds": "Ask pi² to …", "What needs me in pi²", "Stop pi² in <project>"). Every phrase names the app;
/// those naming a project are kept in step with the session's projects (`IntentSessions`).
struct PiShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskOrchestratorIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) a question",
                "Ask \(.applicationName) in \(\.$project)",
                "Ask the orchestrator in \(.applicationName)",
                "Message \(\.$project) in \(.applicationName)",
            ],
            shortTitle: "Ask an Orchestrator",
            systemImageName: "bubble.left.and.text.bubble.right"
        )
        AppShortcut(
            intent: WhatNeedsMeIntent(),
            phrases: [
                "What needs me in \(.applicationName)",
                "What’s waiting for me in \(.applicationName)",
                "What needs me in \(\.$project) in \(.applicationName)",
            ],
            shortTitle: "What Needs Me",
            systemImageName: "tray.full"
        )
        AppShortcut(
            intent: StopProjectIntent(),
            phrases: [
                "Stop \(.applicationName) in \(\.$project)",
                "Stop \(\.$project) in \(.applicationName)",
                "Stop a project in \(.applicationName)",
            ],
            shortTitle: "Stop a Project",
            systemImageName: "stop.circle"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .orange
}
