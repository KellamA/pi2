
import SwiftUI
import UIKit
import UserNotifications

/// This iPhone: which Mac it is paired with and how it reaches it, Face ID and Lock, its notifications as iOS has them,
/// and unpairing (docs/iphone.md 3.6, 4.5; docs/iphone-app.md, "Pairing and the connection"). Lock and Unpair are the
/// app's own (`PhoneLink`), never a request of the Mac's alone: Unpair sends `devices.forgetSelf` if the Mac is attached,
/// tells the relay, wipes the keys and the store, and the first screen says so.
struct SettingsPhoneSection: View {
    let connection: AppSession.Connection
    let macName: String?

    @Environment(PhoneLink.self) private var link: PhoneLink?
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var phase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var pairedAt: Date?
    @State private var notifications: SettingsNotifications?
    @State private var confirmingUnpair = false
    @State private var unpairing = false

    /// Whether a Mac is paired on this launch: Lock and Unpair are offered only then (not in the demo, nor a debug
    /// build's replay).
    private var paired: Bool { link?.paired == true }

    var body: some View {
        Section {
            LabeledContent("Paired with") {
                // At the accessibility sizes the value goes under its title, along the leading edge.
                VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 2) {
                    Text(Self.pairedWith(connection, macName: macName))
                    if let pairedAt, paired {
                        Text("since \(pairedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
            }
            .accessibilityElement(children: .combine)
            LabeledContent("Reached", value: Self.reached(connection))
            LabeledContent("Face ID", value: "Asked to open pi²")
            if let link, paired {
                PresenceLockButton(session: link.keyring.session)
                    .id("lock")
            }
            notificationRows
            if paired {
                Button(unpairing ? "Unpairing…" : "Unpair This iPhone", role: .destructive) { confirmingUnpair = true }
                    .disabled(unpairing)
                    .id("unpair")
            }
        } header: {
            Text("This iPhone")
        } footer: {
            Text(footer)
        }
        .task(id: phase) {
            // Read again on return to the foreground: the person may have changed them in iOS's Settings meanwhile.
            if phase == .active { await readNotifications() }
        }
        .task(id: paired) {
            pairedAt = paired ? link?.record?.pairedAt : nil
        }
        .confirmationDialog("Unpair this iPhone?", isPresented: $confirmingUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive, action: unpair)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.unpairMessage(macName: macName, attached: Self.isAttached(connection)))
        }
        #if DEBUG
        .task(id: Self.isAttached(connection)) {
            // Once attached, so that what the Mac's side saw of the session can be read after.
            guard paired, Self.isAttached(connection) else { return }
            if SettingsSamples.shouldPress("lock"), let link { link.keyring.session.end(.lockButton) }
            if SettingsSamples.shouldPress("unpair") { unpair() }
        }
        #endif
    }

    private var footer: String {
        var words = "Face ID opens pi² on this iPhone, and nothing is asked after, as you chose. pi² locks itself a minute after you leave it and when the iPhone locks."
        if paired {
            words += " Unpairing deletes what pi² keeps here and tells your Mac; a lost iPhone is cut off on the Mac (Settings › Devices › Revoke) or by erasing it with Find My."
        } else {
            words += " A lost iPhone is cut off on the Mac (Settings › Devices › Revoke) or by erasing it with Find My."
        }
        return words
    }

    // MARK: Notifications

    @ViewBuilder private var notificationRows: some View {
        if let notifications {
            LabeledContent("Notifications", value: notifications.value)
            if notifications.allowed == .allowed {
                LabeledContent("Details on the Lock Screen", value: notifications.previews)
            }
            switch notifications.action {
            case .ask:
                Button("Allow Notifications") { Task { await askForNotifications() } }
            case .openSettings:
                Button("Open pi²’s Notification Settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
            case nil:
                EmptyView()
            }
        } else {
            LabeledContent("Notifications", value: "Reading…")
                .foregroundStyle(.secondary)
        }
    }

    private func readNotifications() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notifications = SettingsNotifications(status: settings.authorizationStatus, previews: settings.showPreviewsSetting)
    }

    /// iOS's own question, asked inside the iPhone, once: after it, only iOS's Settings changes the answer.
    private func askForNotifications() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await readNotifications()
    }

    // MARK: Unpairing

    private func unpair() {
        guard let link, !unpairing else { return }
        unpairing = true
        Task {
            await link.unpairThisIPhone()
            unpairing = false
        }
    }

    // MARK: Words

    static func isAttached(_ connection: AppSession.Connection) -> Bool {
        if case .connected = connection { return true }
        return false
    }

    static func pairedWith(_ connection: AppSession.Connection, macName: String?) -> String {
        switch connection {
        case .notPaired: "No Mac"
        case .demo: "The demo"
        default: macName ?? "Your Mac"
        }
    }

    static func reached(_ connection: AppSession.Connection) -> String {
        switch connection {
        case .notPaired: "Not paired"
        case .demo: "No network: canned data"
        case .connecting: "Reaching…"
        case .connected(.home, let relay): relay ? "At home" : "At home · relay unreachable"
        case .connected(.relay, _): "Through pi²’s relay"
        case .connected(.direct, let relay): relay ? "Direct" : "Direct · relay unreachable"
        case .outOfReach(let seen?): "Out of reach since \(seen.formatted(date: .omitted, time: .shortened))"
        case .outOfReach(nil): "Out of reach"
        }
    }

    /// What the confirmation says: what goes, and whether the Mac hears of it now or only from the relay.
    static func unpairMessage(macName: String?, attached: Bool) -> String {
        let mac = macName ?? "your Mac"
        let told = attached
            ? "\(mac) is told now, and stops taking anything from this iPhone."
            : "\(mac) cannot be reached now: it hears of it through pi²’s relay when it next connects, and until then still lists this iPhone."
        return "pi² here forgets \(mac): this iPhone’s keys, what it kept of your projects, and anything still waiting to be sent. \(told) To use pi² here again, pair it again on the Mac."
    }
}

/// pi²'s notifications as iOS has them for this iPhone, in Settings' words. Read from iOS, never kept: the person changes
/// them in iOS's Settings, which pi² cannot do for them.
struct SettingsNotifications: Equatable {
    enum Allowed: Equatable { case notAsked, allowed, off }
    enum Action: Equatable { case ask, openSettings }

    let allowed: Allowed
    /// "Allowed", "Off", "Not asked yet".
    let value: String
    /// What a locked iPhone shows of a notification: iOS's Show Previews for pi², which the phone's own Details on the
    /// Lock Screen follows (docs/iphone.md section 7).
    let previews: String
    let action: Action?

    init(status: UNAuthorizationStatus, previews: UNShowPreviewsSetting) {
        switch status {
        case .notDetermined:
            allowed = .notAsked
            value = "Not asked yet"
            action = .ask
        case .denied:
            allowed = .off
            value = "Off"
            action = .openSettings
        case .authorized, .provisional, .ephemeral:
            allowed = .allowed
            value = status == .provisional ? "Delivered quietly" : "Allowed"
            action = .openSettings
        @unknown default:
            allowed = .off
            value = "Not known"
            action = .openSettings
        }
        switch previews {
        case .always: self.previews = "Shown"
        case .whenAuthenticated: self.previews = "Once unlocked"
        case .never: self.previews = "Never"
        @unknown default: self.previews = "As iOS sets it"
        }
    }
}
