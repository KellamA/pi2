import EngineKit
import SwiftUI

/// The engine's refusal, or why a change could not be sent, under the control that sent it.
struct SettingsProblem: View {
    let text: String?

    var body: some View {
        if let text {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Not changed: \(text)")
        }
    }
}

/// A line at the top of a settings screen while changes cannot reach the Mac. The connection bar itself is the projects
/// list's.
struct SettingsConnectionLine: View {
    let connected: Bool
    let connection: AppSession.Connection

    /// Whether it has anything to say.
    var shows: Bool { words != nil }

    var body: some View {
        if let words {
            Label(words, systemImage: "wifi.exclamationmark")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var words: String? {
        switch connection {
        case .outOfReach:
            return "Your Mac cannot be reached: these are its settings as last seen, and a change cannot be sent until it can."
        case .connecting:
            return "Reaching your Mac: a change can be sent once it is connected."
        default:
            return connected ? nil : "Not connected to your Mac: a change cannot be sent yet."
        }
    }
}

/// The text a limit is typed as, read as the Mac reads it (ProjectSettingsTab.swift): empty for no limit.
enum SettingsLimitInput {
    /// A plan limit: a whole percent from 1 to 100, or nil for none; or why the text is not one.
    static func planShare(_ text: String) -> Result<Int?, Refusal> {
        let given = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
        if given.isEmpty { return .success(nil) }
        guard let percent = Int(given), (1...100).contains(percent) else {
            return .failure(Refusal(text: "Enter a whole number from 1 to 100, or leave it empty for no limit."))
        }
        return .success(percent)
    }

    /// A daily limit in dollars, above zero, or nil for none; or why the text is not one. A comma is read as the decimal
    /// point, as a phone's keypad may type it.
    static func dailySpend(_ text: String) -> Result<Double?, Refusal> {
        let given = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: ".")
        if given.isEmpty { return .success(nil) }
        guard let amount = Double(given), amount > 0, amount.isFinite else {
            return .failure(Refusal(text: "Enter an amount above zero, or leave it empty for no limit."))
        }
        return .success(amount)
    }

    /// How a limit is shown in its field: "80", "5", "2.5".
    static func text(_ dollars: Double?) -> String {
        dollars.map { String(format: "%g", $0) } ?? ""
    }

    struct Refusal: Error, Equatable {
        let text: String
    }
}

/// The problems of a screen, by the row that made each.
struct SettingsProblems {
    private var byRow: [String: String] = [:]

    subscript(row: String) -> String? {
        get { byRow[row] }
        set { byRow[row] = newValue }
    }
}

extension View {
    /// A picker that opens as a menu, or at the accessibility text sizes as a list of its own, where a menu's closed label
    /// would be cut to a few letters.
    @ViewBuilder
    func settingsPickerStyle(_ size: DynamicTypeSize) -> some View {
        if size.isAccessibilitySize {
            pickerStyle(.navigationLink)
        } else {
            pickerStyle(.menu)
        }
    }
}

extension SettingsRequest {
    /// Sends it through the session's client, and keeps the engine's answer for `row`: its refusal, or nothing once it
    /// took the change.
    @MainActor
    func send(through engine: EngineSession<MessageField>, row: String, into problems: Binding<SettingsProblems>) {
        Task { @MainActor in
            problems.wrappedValue[row] = await send(through: engine)
        }
    }
}
