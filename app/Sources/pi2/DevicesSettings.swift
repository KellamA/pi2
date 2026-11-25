import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import PiModels
import SwiftUI
import UserNotifications

// The owner's decision of 22 November 2026: until a real phone is paired (#712), a release build has none of this, not
// the tab, not the device line in the menu bar item and the sidebar, nor the `devices` event. Everything in this file,
// and every place that uses it, is inside `PI2_DEVELOPMENT`, the compile-time condition of development builds (their
// ordinary, optimised and test-copy forms) that a release build never defines; `app/check-release-build.mts` fails a
// release executable that names it.
#if PI2_DEVELOPMENT

// Settings › Devices (docs/iphone.md 3.1 to 3.6, 4.4, 6.5; docs/design/iphone.md, The Devices page on the Mac; #679):
// pairing an iPhone, the paired devices and what each did, and the switches of remote access. Everything here is the
// Mac's alone: every `devices.*` request but a device's own is the app's (FOR_THE_PERSON_SETTINGS), and so is the
// `devices` event, which the app asks for with `devices.watch`. Behind the preview switch (decision 19): with it off,
// the tab shows that switch and nothing else, and the menu bar item and the sidebar show no device.

// MARK: - What the engine says

/// A paired device as the engine keeps it (`Device` in engine/src/devices.ts), with the fields the page reads. Its keys
/// are public halves, and none is shown.
struct PairedDevice: Decodable, Equatable, Identifiable {
    let id: String
    var name: String
    var model: String
    var system: String
    var build: String?
    /// A new Face ID key the phone sent, waiting for the person to accept it here (3.2).
    var pendingPresenceKey: String?
    var suspendedAt: Double?
    var pairedAt: Double
    var lastSeenAt: Double?
    var lastPath: String?
    var revokedAt: Double?

    var revoked: Bool { revokedAt != nil }
    var suspended: Bool { suspendedAt != nil }
    /// "iPhone 17 Pro · iOS 27.1", from what the phone said of itself.
    var kind: String { [model, system].filter { !$0.isEmpty }.joined(separator: " · ") }
}

/// The `devices` event, and the answer to `devices.watch` (`devicesEvent` in engine/src/devices.ts). Every field but the
/// switches is optional here, so that an engine that sends less draws less rather than an error.
struct DevicesEvent: Decodable, Equatable {
    struct Switches: Decodable, Equatable {
        var on = false, relay = true, home = true, direct = false, preview = false
    }
    struct MacKeys: Decodable, Equatable {
        let secureEnclave: Bool
    }
    struct Helper: Decodable, Equatable {
        let running: Bool
        let stoppedInLastHour: Int
        /// What pi² Remote last said of the relay path, or nil before it said anything (or while it does not run).
        var relay: RelayPath?

        private enum CodingKeys: String, CodingKey { case running, stoppedInLastHour, relay }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            running = try container.decode(Bool.self, forKey: .running)
            stoppedInLastHour = try container.decode(Int.self, forKey: .stoppedInLastHour)
            // Read by itself: a relay state the app cannot read loses that line, never the event.
            relay = (try? container.decodeIfPresent(RelayPath.self, forKey: .relay)) ?? nil
        }
    }
    /// What pi² Remote says of the relay path (`remote.state`'s `relay`, which the engine passes on as `helper.relay`;
    /// docs/iphone.md 6.5, #916). Each member is read by itself, and a state this version does not know is `unknown`, so
    /// that a newer pi² Remote draws a plain line rather than nothing.
    struct RelayPath: Decodable, Equatable {
        enum State: Equatable { case off, unavailable, connecting, ready, down, stopped, unknown }
        var state: State
        /// pi² Remote's words for why it is off, unavailable, down or stopped; the relay's own word is in them.
        var why: String?
        /// Why it is unavailable, as a fixed word beside the words (#917): what the page acts on, never the words.
        var reason: String?
        /// When pi² Remote connects again, while it is down (ms since 1970).
        var retryAt: Double?
        /// The relay's word that another copy of pi² Remote tried to connect as this Mac, and when (3.4).
        var anotherMacAt: Double?
        /// Where this Mac's pairing is registered beside the relay's address now set (`here`, `another-relay`, `none`),
        /// and that address (#1013): what decides whether the engine opens a pairing code.
        var registered: String?
        var address: String?

        /// This Mac's pairing cannot use the relay now set, and only a new one can (#917): it belongs to another relay,
        /// or to none (made with the relay off). The page offers to start again.
        var pairingElsewhere: Bool { state == .unavailable && (reason == "another-relay" || reason == "unregistered") }

        private enum CodingKeys: String, CodingKey { case available, state, why, reason, retryAt, anotherMacAt, registered, address }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let available = (try? container.decodeIfPresent(Bool.self, forKey: .available)) ?? nil
            let word = (try? container.decodeIfPresent(String.self, forKey: .state)) ?? nil
            state = switch word {
            case "off": .off
            case "unavailable": .unavailable
            case "connecting": .connecting
            case "ready": .ready
            case "down": .down
            case "stopped": .stopped
            // As the engine reads one with no state: `available` alone.
            case nil where available == true: .ready
            case nil where available == false: .unavailable
            default: .unknown
            }
            why = ((try? container.decodeIfPresent(String.self, forKey: .why)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
            reason = (try? container.decodeIfPresent(String.self, forKey: .reason)) ?? nil
            retryAt = (try? container.decodeIfPresent(Double.self, forKey: .retryAt)) ?? nil
            anotherMacAt = (try? container.decodeIfPresent(Double.self, forKey: .anotherMacAt)) ?? nil
            registered = (try? container.decodeIfPresent(String.self, forKey: .registered)) ?? nil
            address = (try? container.decodeIfPresent(String.self, forKey: .address)) ?? nil
        }
    }
    /// A device attached now, by the path its channel came over.
    struct Session: Decodable, Equatable {
        let device: String
        let session: String
        let path: String
        let since: Double
    }
    /// The join window open now: when it closes, and the claim on it, shown without its digits (3.3).
    struct Window: Decodable, Equatable {
        let expires: Double
        let claim: Claim?
    }
    struct Claim: Decodable, Equatable {
        let name: String
        let model: String
        let system: String
        let path: String
        let at: Double
        /// The paired device whose name and model it has, which pairing it can replace.
        let replaces: String?
        let wrongDigits: Int
    }
    /// Why the last window closed before a phone paired: a second claim, a refused claim, wrong digits, the time.
    struct Closed: Decodable, Equatable {
        let why: String
        let at: Double
    }
    /// What the Mac should notify the person of (4.4).
    struct Notice: Decodable, Equatable {
        let kind: String
        let device: String?
        let text: String
        let at: Double
    }

    var remote = Switches()
    var relay: String?
    var macName: String?
    /// The pairing's id at the relay, once pi² Remote registered this Mac there.
    var pairing: String?
    var macKeys: MacKeys?
    var helper: Helper?
    var devices: [PairedDevice]?
    var sessions: [Session]?
    var pairingWindow: Window?
    var closed: Closed?
    var notice: Notice?
    /// Why the engine could not read its record of paired devices, when it could not: then no device can pair or
    /// connect, and every `devices.*` request but `devices.watch` is refused with these words (#776).
    var unreadable: String?
}

/// One line of a device's log (`DeviceLogEntry`, 4.4).
struct DeviceLogEntry: Decodable, Equatable, Identifiable {
    let at: Double
    let device: String
    let path: String
    let method: String
    let summary: String
    let presence: Bool
    let outcome: String
    let why: String?
    /// Refusals of the same request for the same reason within a minute of each other, made one entry: how many, and
    /// the last one's time (#776).
    let count: Int?
    let lastAt: Double?

    var id: String { "\(at)-\(method)-\(summary)" }
}

/// The words for a path a device came by.
enum DevicePathWords {
    static func how(_ path: String?) -> String? {
        switch path {
        case "relay": "through the relay"
        case "home": "at home"
        case "direct": "direct"
        case "mailbox": "from the mailbox"
        default: nil
        }
    }
}

/// Time from the engine, in milliseconds since 1970.
private func engineDate(_ ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000) }

/// The words for what pi² Remote says of the relay path (docs/iphone.md 6.5, #916): plain sentences, with pi² Remote's
/// own reason in them, and none of the names it sends them by.
enum RelayPathWords {
    /// The status line under **Reach through pi²’s relay**, and its dot. `paired` says whether any device is paired:
    /// before one is, a relay that cannot be used yet is nothing to worry about.
    static func line(_ path: DevicesEvent.RelayPath, paired: Bool, now: Date) -> (dot: Color, words: String) {
        let why = path.why.map(sentence)
        switch path.state {
        case .off:
            return (Theme.tx3, "Off, as you chose: pi² Remote does not connect to the relay.")
        case .unavailable where path.reason == "another-relay":
            return (Theme.warn, "Not connected: this Mac’s pairing belongs to another relay.")
        case .unavailable where path.reason == "unregistered":
            return (Theme.warn, "Not connected: this Mac’s pairing was made with the relay off.")
        case .unavailable:
            return (paired ? Theme.warn : Theme.tx3, join("pi² Remote cannot use the relay.", why, "An iPhone at home or on a private network still reaches this Mac."))
        case .connecting:
            return (Theme.warn, "Connecting to the relay…")
        case .ready:
            return (Theme.ok, "Connected to the relay: a paired iPhone can reach this Mac from any network.")
        case .down:
            let again: String
            if let retryAt = path.retryAt, engineDate(retryAt) > now {
                again = "pi² Remote tries again at \(time(engineDate(retryAt), seconds: true))."
            } else {
                again = "pi² Remote is trying again now."
            }
            return (Theme.bad, join("The relay can’t be reached.", why, again, "An iPhone at home or on a private network still reaches this Mac."))
        case .stopped:
            return (Theme.bad, join(
                "pi² Remote stopped connecting to the relay.", why,
                "It tries again in an hour or when pi² next starts, or now if you turn Reach through pi²’s relay off and on."))
        case .unknown:
            return (Theme.tx3, join("pi² Remote says something of the relay that this version of pi² does not know.", why))
        }
    }

    /// The relay's word that another copy of pi² Remote tried to connect as this Mac (3.4): what it means, and what to do.
    static func anotherMac(at: Double) -> String {
        "pi²’s relay says another copy of pi² Remote tried to connect as this Mac, \(when(engineDate(at))). That is the relay’s word, which this Mac cannot check; the relay kept this Mac connected and turned the other away. If pi² also runs on another Mac set up from this one, or a second copy runs here on this Mac’s data, turn off Reach from an iPhone in that copy. If neither, turn off Reach through pi²’s relay until you know more: an iPhone then reaches this Mac only at home or over a private network."
    }

    /// pi² Remote's reason as a sentence of its own, with the relay's refusal said in words and a time in place of the
    /// milliseconds a limit ends at.
    static func sentence(_ why: String) -> String {
        var text = why.trimmingCharacters(in: .whitespacesAndNewlines)
        // The line says that in words of its own.
        text = text.replacing(/[;,]?\s*(the relay path is off, )?home and direct carry on\.?$/, with: "")
        text = text.replacing(/until (\d{12,14})/) { match in
            guard let ms = Double(match.output.1) else { return String(match.output.0) }
            return "until \(time(engineDate(ms), seconds: false))"
        }
        text = text.replacing(/saying ([a-z][a-z-]*)/) { match in "saying \(refusal(String(match.output.1)))" }
        guard let first = text.first else { return text }
        text = first.uppercased() + text.dropFirst()
        return text.hasSuffix(".") ? text : text + "."
    }

    /// A refusal's fixed word (`RelayWhy`), quoted as words, with what it means for this Mac where that is known.
    static func refusal(_ word: String) -> String {
        let quoted = "“\(word.replacingOccurrences(of: "-", with: " "))”"
        let meaning: String? = switch word {
        case "update-required": "it takes only a newer version of pi²"
        case "unknown-pairing": "it does not know this Mac’s pairing"
        case "deleted": "this Mac’s pairing was deleted there"
        case "signature": "it did not accept this Mac’s key"
        case "another-mac": "another copy of pi² Remote is connected as this Mac"
        case "unavailable": "it is not taking connections now"
        case "limits", "busy", "too-many": "this Mac is past its limits there"
        default: nil
        }
        return meaning.map { "\(quoted) (\($0))" } ?? quoted
    }

    /// What the page says beside **Start Again at This Relay…** (#917), from pi² Remote's reason, and what starting again
    /// does. Nil for any other state.
    static func elsewhere(_ path: DevicesEvent.RelayPath, paired: Int) -> String? {
        guard path.pairingElsewhere else { return nil }
        let what = path.reason == "another-relay"
            ? "This Mac’s pairing was made at another relay, and pi² shows a pairing to no relay but its own, so this relay cannot carry it."
            : "This Mac’s pairing was made with the relay off, for home and private networks alone, so no relay knows it."
        let reach = paired == 0 ? nil : "A paired iPhone reaches this Mac only at home or over a private network."
        return join(what, reach, "To use this relay, start again: this Mac makes a new pairing here, and each iPhone pairs again.")
    }

    /// The confirmation's message: exactly what starting again costs, by name.
    /// Only what the person must know before pressing: who is unpaired, by name up to three, and what the Mac does next.
    /// What Revoke does to a phone, its log and the old relay is Revoke's, and in the docs.
    static func startAgainCost(_ devices: [PairedDevice], host: String) -> String {
        let relay = host.isEmpty ? "the relay now set" : host
        let unpaired: String
        switch devices.count {
        case 0: unpaired = "No iPhone is paired, so none is unpaired."
        case 1: unpaired = "\(devices[0].name) is unpaired, as Revoke does, and must scan a new code."
        case 2, 3:
            let names = devices.map(\.name)
            unpaired = "\(names.dropLast().joined(separator: ", ")) and \(names.last!) are unpaired, as Revoke does, and must each scan a new code."
        default: unpaired = "All \(devices.count) paired iPhones are unpaired, as Revoke does, and must each scan a new code."
        }
        return "\(unpaired) This Mac then makes a new pairing at \(relay) with the next pairing code."
    }

    private static func join(_ parts: String?...) -> String { parts.compactMap { $0 }.joined(separator: " ") }

    private static func time(_ date: Date, seconds: Bool) -> String {
        let clock = date.formatted(date: .omitted, time: seconds ? .standard : .shortened)
        return Calendar.current.isDateInToday(date) ? clock : "\(date.formatted(date: .abbreviated, time: .omitted)), \(clock)"
    }

    private static func when(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? "at \(time(date, seconds: false))" : "on \(time(date, seconds: false))"
    }
}

/// A stand-in for what pi² Remote says of the relay path, so that a picture can show each state: a copy's pi² Remote
/// has no relay to connect to. The copy's own preference names it, set before launch (or before `reopen`), so nothing of
/// the person's sets it, and only a development build has this file at all:
///
///     defaults write dev.pi2.app.test-7 relay-sample -string 'down'
///
/// `off`, `unavailable`, `another-relay` and `unregistered` (a pairing only starting again mends, #917), `no-pairing`,
/// `connecting`, `ready`, `down`, `busy` (down past a limit), `stopped`, `another` (ready, and the relay's word of
/// another Mac) and `unknown` (a state this version does not know, with a member it cannot read). Each
/// is JSON as pi² Remote sends it, read by the same decoder as the engine's. See docs/development.md, "Choosing what a
/// copy shows".
@MainActor
enum RelaySample {
    static let asked: DevicesEvent.RelayPath? = {
        guard let name = UserDefaults.standard.string(forKey: "relay-sample") else { return nil }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let json: String? = switch name {
        case "off": #"{"available":false,"state":"off","why":"Reach through pi²'s relay is off: home and private networks only."}"#
        case "unavailable": #"{"available":false,"state":"unavailable","why":"the relay key for this address could not be read or made; the relay path is off, home and direct carry on","reason":"key"}"#
        case "another-relay": #"{"available":false,"state":"unavailable","why":"this Mac's pairing belongs to another relay: it was not registered at this relay by pi² Remote, and is shown to no other relay; home and direct carry on","reason":"another-relay","registered":"another-relay"}"#
        case "unregistered": #"{"available":false,"state":"unavailable","why":"this Mac's pairing is registered at no relay (it was made for the home path alone), and was not registered at this relay by pi² Remote; home and direct carry on","reason":"unregistered","registered":"none"}"#
        case "no-pairing": #"{"available":false,"state":"unavailable","why":"no pairing yet: one is registered at the relay when the first iPhone pairs","reason":"no-pairing"}"#
        case "connecting": #"{"available":false,"state":"connecting"}"#
        case "ready": #"{"available":true,"state":"ready"}"#
        case "down": #"{"available":false,"state":"down","why":"the connection to the relay was lost","retryAt":"# + "\(now + 40_000)}"
        case "busy": #"{"available":false,"state":"down","why":"the relay says this Mac is past a limit, until "# + "\(now + 1_800_000)\",\"retryAt\":\(now + 1_800_000)}"
        case "stopped": #"{"available":false,"state":"stopped","why":"the relay refused, saying update-required"}"#
        case "another": #"{"available":true,"state":"ready","anotherMacAt":"# + "\(now - 180_000)}"
        case "unknown": #"{"available":false,"state":"resting","why":"the relay asked this Mac to rest","retryAt":"soon"}"#
        default: nil
        }
        guard let data = json?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DevicesEvent.RelayPath.self, from: data)
    }()
}

// MARK: - The store

/// What the engine last said of devices, kept for the Devices tab, the menu bar item and the sidebar, and the Mac's
/// notifications of 4.4. Fed by EngineClient from the `devices` event, and from `devices.watch` at each connection.
@MainActor
@Observable
final class DevicesStore {
    private(set) var state: DevicesEvent?

    var preview: Bool { state?.remote.preview == true }
    var remoteOn: Bool { preview && state?.remote.on == true }

    /// Every device the engine lists, revoked ones included (their log is kept 90 days).
    var devices: [PairedDevice] { state?.devices ?? [] }
    var active: [PairedDevice] { devices.filter { !$0.revoked } }

    func device(_ id: String) -> PairedDevice? { devices.first { $0.id == id } }

    /// The devices attached now, each with the words for its path, while the preview and remote access are on.
    var attached: [(session: String, device: PairedDevice, how: String, since: Date)] {
        guard remoteOn else { return [] }
        return (state?.sessions ?? []).compactMap { session in
            guard let device = device(session.device) else { return nil }
            return (session.session, device, DevicePathWords.how(session.path) ?? session.path, engineDate(session.since))
        }
    }

    /// What the menu bar item and the sidebar say while a device is attached (4.4): "Alex's iPhone · through the relay".
    var attachedLine: String? {
        let attached = attached
        guard let first = attached.first else { return nil }
        let more = attached.count > 1 ? " and \(attached.count - 1) more" : ""
        return "\(first.device.name) · \(first.how)\(more)"
    }

    /// Asks the engine for the `devices` event on this connection, and takes its answer. An engine from before #673 does
    /// not know the request; then nothing about devices shows.
    func watch(_ engine: EngineClient) async {
        guard let reply = try? await engine.call("devices.watch"),
              let data = try? JSONEncoder().encode(reply),
              let event = try? JSONDecoder().decode(DevicesEvent.self, from: data) else { return }
        take(event, engine: engine)
    }

    /// The `devices` event. Read leniently: an event the app cannot read is left out, never put up as an error.
    func take(line: Data, decoder: JSONDecoder, engine: EngineClient) {
        guard let event = try? decoder.decode(DevicesEvent.self, from: line) else {
            engine.note("devices: an event the app could not read was left out")
            return
        }
        take(event, engine: engine)
    }

    private func take(_ event: DevicesEvent, engine: EngineClient) {
        var kept = event
        kept.notice = nil
        if state != kept { state = kept }
        if let notice = event.notice { Notifier.shared.device(notice, name: notice.device.flatMap { device($0)?.name }) }
        if let notice = event.notice { engine.note("devices: notice \(notice.kind)") }
    }
}

// MARK: - Notifications (4.4)

extension Notifier {
    /// What the engine notifies of: a claim, a pairing, a new Face ID key waiting to be accepted (3.2, #786), a widening
    /// request from a device, a suspension. Posted when the
    /// person turned on notifications in General, the switch that asked macOS for them, whether or not pi² is in front:
    /// someone working the agents from elsewhere should not go unseen at the desk. A test copy never has that switch
    /// on, so it asks macOS for nothing and posts nothing.
    func device(_ notice: DevicesEvent.Notice, name: String?) {
        let title = switch notice.kind {
        case "claim": "An iPhone wants to pair with this Mac"
        case "paired": "\(name ?? "A device") was paired"
        case "presenceKey": "Face ID was set up again on \(name ?? "a device")"
        case "widening": "\(name ?? "A device") widened what agents may do"
        case "suspended": "\(name ?? "A device") was suspended"
        default: "A paired device"
        }
        post(id: "device-\(notice.kind)-\(notice.device ?? "")-\(Int(notice.at))", title: title, body: notice.text)
    }

    private func post(id: String, title: String, body: String) {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

// MARK: - The attached line

/// "Alex's iPhone · through the relay", in the menu bar item and the sidebar while a device is attached (4.4). Nothing
/// with the preview off or no device attached.
struct DevicesAttachedLine: View {
    let store: DevicesStore

    var body: some View {
        if let line = store.attachedLine {
            HStack(spacing: 7) {
                Image(systemName: "iphone").font(.system(size: 11)).foregroundStyle(Theme.acc).frame(width: 14)
                Text(line).lineLimit(1).truncationMode(.middle).foregroundStyle(Theme.tx2)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            .help("A paired device is connected to this Mac and can act for you. Settings › Devices shows what it did, and can revoke it.")
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - The tab

struct DevicesSettings: View {
    let engine: EngineClient
    @State private var problem: String?
    @State private var pairing = false
    @State private var logOf: PairedDevice?
    @State private var renaming: PairedDevice?
    @State private var newName = ""
    @State private var revoking: PairedDevice?
    /// The confirmation of **Start Again at This Relay…** is up (#917).
    @State private var startingAgain = false
    @State private var relayDraft = ""
    /// Why the engine refused the relay's address typed, in its words.
    @State private var relayProblem: String?

    private var store: DevicesStore { engine.devices }
    private var state: DevicesEvent? { store.state }
    private var switches: DevicesEvent.Switches { state?.remote ?? .init() }

    var body: some View {
        Form {
            Section {
                Toggle("iPhone (preview)", isOn: binding(\.preview, "preview"))
                    .disabled(state == nil || state?.unreadable != nil)
                if let unreadable = state?.unreadable {
                    Label {
                        Text(unreadable).font(.callout)
                    } icon: {
                        Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(Theme.bad)
                    }
                }
                if let problem {
                    Text(problem).font(.callout).foregroundStyle(Theme.bad)
                }
            } footer: {
                Text(state == nil
                    ? "This engine does not know of devices yet."
                    : "Reaching this Mac from pi² for iPhone, which is not given out yet. With this off, nothing here runs, no device can pair or connect, and pi² asks macOS for nothing.").formFooter()
            }
            if store.preview {
                reach
                paired
                if state?.pairing != nil && store.active.isEmpty { forget }
                if store.devices.contains(where: \.revoked) { revoked }
            }
        }
        .formStyle(.grouped)
        .settingsPage(.devices)
        .sheet(isPresented: $pairing) { PairingSheet(engine: engine) }
        .sheet(item: $logOf) { device in DeviceLogSheet(engine: engine, device: device) }
        .alert("Rename device", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { rename() }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("The name this Mac shows it by, in its log and its notifications. The iPhone keeps its own.")
        }
        .confirmationDialog(
            "Revoke \(revoking?.name ?? "this device")?",
            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } })
        ) {
            Button("Revoke", role: .destructive) { revoke() }
            Button("Cancel", role: .cancel) { revoking = nil }
        } message: {
            Text("It can no longer reach this Mac, at once: its keys are forgotten, its connection is closed, and pi²’s relay forgets it, its mailbox and its notifications. The iPhone is told when it next reaches this Mac, and wipes what it kept. Its log stays here for 90 days.")
        }
        .confirmationDialog(
            store.active.isEmpty ? "Start again at this relay?" : "Unpair every iPhone and start again at this relay?",
            isPresented: $startingAgain
        ) {
            Button(store.active.isEmpty ? "Start Again" : store.active.count == 1 ? "Unpair 1 iPhone and Start Again" : "Unpair \(store.active.count) iPhones and Start Again", role: .destructive) { startAgain() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(RelayPathWords.startAgainCost(store.active, host: relayHost))
        }
        .onAppear { relayDraft = state?.relay ?? "" }
        .onChange(of: state?.relay) { _, relay in
            relayDraft = relay ?? ""
            relayProblem = nil
        }
        #if PI2_DEVELOPMENT
        .task {
            // The devices arrive a moment after the tab appears.
            guard let asked = SettingsLaunch.takeDevicesSheet() else { return }
            if asked == "pair" {
                pairing = true
                return
            }
            if asked == "start-again" {
                // Only while the page offers it, as the button does: pi² Remote's word arrives a moment after the tab.
                for _ in 0..<100 {
                    if let relayPath, relayPath.pairingElsewhere, switches.on {
                        startingAgain = true
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                return
            }
            let wanted = String(asked.dropFirst("log=".count))
            for _ in 0..<100 {
                if let device = store.devices.first(where: { $0.id == wanted || $0.name == wanted }) {
                    logOf = device
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        #endif
    }

    // MARK: Reach

    private var reach: some View {
        Section {
            VStack(alignment: .leading, spacing: 3) {
                Toggle("Reach from an iPhone", isOn: binding(\.on, "on"))
                Text(reachLine).font(.caption).foregroundStyle(Theme.tx2)
            }
            VStack(alignment: .leading, spacing: 3) {
                Toggle("Reach through pi²’s relay", isOn: binding(\.relay, "relay"))
                Text(switches.relay
                    ? "From any network, with notifications while pi² is closed on the iPhone. Encrypted end to end: the relay cannot read what it passes."
                    : "Off: home and private networks only, and no notifications while pi² is closed on the iPhone.")
                    .font(.caption).foregroundStyle(Theme.tx2)
                if switches.relay || (switches.on && relayPath != nil) { relayState }
            }
            if switches.relay {
                HStack(spacing: 8) {
                    TextField("Relay", text: $relayDraft, prompt: Text("wss://relay.example/v1"))
                        .labelsHidden()
                        .font(Theme.mono)
                        .accessibilityLabel("The relay’s address")
                        .onSubmit(saveRelay)
                    Button("Save", action: saveRelay)
                        .disabled(relayDraft.trimmingCharacters(in: .whitespaces) == (state?.relay ?? ""))
                }
                if let relayProblem {
                    Text(relayProblem).font(.callout).foregroundStyle(Theme.bad)
                }
                if switches.on, let relayPath, let words = RelayPathWords.elsewhere(relayPath, paired: store.active.count) {
                    // #917: only pi² Remote's reason offers it, and only the person's word in the confirmation does it.
                    VStack(alignment: .leading, spacing: 8) {
                        Label {
                            Text(words).font(.callout).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                        }
                        Button("Start Again at This Relay…") { startingAgain = true }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Toggle("Find on this network", isOn: binding(\.home, "home"))
                Text(switches.home
                    ? "Talks directly at home, which is faster. The first time, macOS asks whether pi² Remote may use the local network."
                    : "Off: pi² asks macOS for nothing, and the relay carries everything.")
                    .font(.caption).foregroundStyle(Theme.tx2)
            }
            VStack(alignment: .leading, spacing: 3) {
                Toggle("Direct from any address", isOn: binding(\.direct, "direct"))
                Text(switches.direct
                    ? "On: an iPhone may connect directly from any address that reaches this Mac."
                    : "Off: direct connections only from home and private networks.")
                    .font(.caption).foregroundStyle(Theme.tx2)
            }
            warnings
        } header: {
            Text("Reach")
        } footer: {
            Text("A paired iPhone can do what you do here, but what needs this Mac’s hands or a secret, once Face ID has opened pi² on it. Pairing, revoking and these switches are this Mac’s alone.").formFooter()
        }
        .id(SettingsSection.reach)
    }

    /// The relay's host, as the page names it.
    private var relayHost: String {
        let address = state?.relay ?? ""
        return URL(string: address)?.host() ?? address
    }

    private func relayLine(now: Date) -> (Color, String) {
        let address = state?.relay ?? ""
        let host = URL(string: address)?.host() ?? address
        let running = state?.helper?.running == true
        if address.isEmpty && switches.relay { return (Theme.tx3, "No relay’s address yet: an iPhone cannot pair through one.") }
        if !switches.on { return (Theme.tx3, "Not connected while Reach from an iPhone is off · \(host)") }
        if let relayPath {
            let line = RelayPathWords.line(relayPath, paired: !store.active.isEmpty, now: now)
            return (line.dot, relayPath.state == .off || host.isEmpty ? line.words : "\(line.words) · \(host)")
        }
        if running && state?.pairing != nil { return (Theme.ok, "Registered at the relay · \(host)") }
        if running { return (Theme.warn, "Registering at the relay… · \(host)") }
        if store.active.isEmpty { return (Theme.tx3, "Connects once an iPhone is paired · \(host)") }
        return (Theme.warn, "pi² Remote is not running, so the relay cannot reach this Mac · \(host)")
    }

    private var reachLine: String {
        let count = store.active.count
        let paired = count == 0 ? "No device paired." : count == 1 ? "1 device paired." : "\(count) devices paired."
        return switches.on ? "\(paired) Reachable while pi² runs on this Mac." : "\(paired) Off: paired devices stay paired and can do nothing until it is on again."
    }

    /// Why no pairing code can be made now, as the engine would refuse one (#1013): a code names the pairing with the
    /// relay's address now set, and the phone tries that relay at once. Nil when one can, or pi² Remote has not said.
    private var pairBlocked: String? {
        guard let relayPath, relayPath.address == nil || relayPath.address == state?.relay else { return nil }
        if relayPath.registered == "another-relay" {
            return switches.relay ? "Start again at this relay first" : "This Mac’s pairing belongs to another relay: set its address back"
        }
        if relayPath.registered == "none" && switches.relay { return "Start again at this relay first" }
        return nil
    }

    /// What pi² Remote last said of the relay path (6.5, #916), or a development build's stand-in for it (`RelaySample`).
    private var relayPath: DevicesEvent.RelayPath? {
        if let sample = RelaySample.asked { return sample }
        guard state?.helper?.running == true else { return nil }
        return state?.helper?.relay
    }

    /// What the relay path does: pi² Remote's own word once it has said it (6.5, #916); before that, whether this Mac is
    /// registered at the relay, from the pairing pi² Remote has there and whether it runs.
    private var relayState: some View {
        // Down, it says when it tries again, and that time passing changes the line.
        TimelineView(.periodic(from: .now, by: relayPath?.state == .down ? 1 : 3600)) { context in
            let (dot, words) = relayLine(now: context.date)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Dot(color: dot).alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                Text(words).font(.caption).foregroundStyle(Theme.tx2).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: What needs saying

    /// Rows at the foot of Reach, when there is something to say. Rows, not a section of their own: a grouped form
    /// that gains a section between two others while shown draws the sections after it out of place.
    @ViewBuilder
    private var warnings: some View {
        let stops = state?.helper?.stoppedInLastHour ?? 0
        // 4.4: more than three times in an hour.
        if stops > 3 {
            Label {
                Text("pi² Remote stopped unexpectedly \(stops) times in the last hour. pi² starts it again each time, waiting longer after each stop, and no iPhone can reach this Mac while it is stopped. Something on this Mac may be stopping it.")
                    .font(.callout)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
            }
        }
        // 3.4: the relay's word, said as such, with what to do about it.
        if store.remoteOn, let at = relayPath?.anotherMacAt {
            Label {
                Text(RelayPathWords.anotherMac(at: at)).font(.callout)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
            }
        }
        if state?.macKeys?.secureEnclave == false {
            Label {
                Text("This Mac has no Secure Enclave, so its keys for remote access are kept in pi²’s part of the Keychain, which only pi²’s signed code can read. A Mac with Apple silicon or a T2 chip keeps them in the Secure Enclave, where they cannot be copied.")
                    .font(.callout)
            } icon: {
                Image(systemName: "lock.trianglebadge.exclamationmark").foregroundStyle(Theme.warn)
            }
        }
    }

    /// The devices attached now, as rows at the head of the list.
    private var attachedNow: some View {
        // By session: a device's own row below has its id.
        ForEach(store.attached, id: \.session) { one in
            HStack(spacing: 8) {
                Dot(color: Theme.ok)
                Text("**\(one.device.name)** is connected \(one.how), since \(one.since.formatted(date: .omitted, time: .shortened)). The menu bar and the sidebar show it too.")
                    .font(.callout)
            }
            .listRowBackground(Theme.ok.opacity(0.08))
        }
    }

    // MARK: The devices

    private var paired: some View {
        Section {
            attachedNow
            if store.active.isEmpty {
                Text("No device is paired.").foregroundStyle(Theme.tx2)
            }
            ForEach(store.active) { device in
                DeviceRow(
                    engine: engine, device: device,
                    log: { logOf = device },
                    rename: {
                        newName = device.name
                        renaming = device
                    },
                    revoke: { revoking = device },
                    problem: $problem
                )
            }
            HStack {
                Button("Pair an iPhone…") { pairing = true }
                    .disabled(!store.remoteOn || store.active.count >= 5 || pairBlocked != nil)
                Spacer()
                Text(!switches.on ? "Turn on Reach from an iPhone to pair" : pairBlocked ?? (store.active.count >= 5 ? "5 devices are paired: revoke one first" : "up to 5 devices"))
                    .font(.caption).foregroundStyle(Theme.tx3)
            }
        } header: {
            Text("Paired devices")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                // 3.6: revoking needs this Mac; away from it, the remedy is Find My.
                Text("Lost your iPhone away from this Mac? Erase it with Find My: that destroys the keys that pair it. Then revoke it here.").formFooter()
                Text("Each device’s log keeps what it did for 90 days: every answer and change, every connection and refused try, and every file it read, with the path it came by and whether Face ID opened the session. After five refused tries in ten minutes this Mac suspends a device until you resume it here.").formFooter()
            }
        }
        .id(SettingsSection.paired)
    }

    private var revoked: some View {
        Section("Revoked") {
            ForEach(store.devices.filter(\.revoked)) { device in
                HStack {
                    Image(systemName: "iphone.slash").foregroundStyle(Theme.tx3).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name).foregroundStyle(Theme.tx2)
                        Text("Revoked \(engineDate(device.revokedAt ?? 0).formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(Theme.tx3)
                    }
                    Spacer()
                    Button("What It Did…") { logOf = device }
                }
            }
        }
    }

    /// 3.6: with every device revoked, the pairing at the relay can be deleted. The engine has no request for it yet
    /// (#679's report); the button lights up when `forgetRequest` names one.
    private var forget: some View {
        Section {
            HStack {
                Button("Forget This Mac at the Relay") {
                    guard let request = Self.forgetRequest else { return }
                    Task {
                        do {
                            try await engine.call(request)
                            problem = nil
                        } catch {
                            problem = error.localizedDescription
                        }
                    }
                }
                .disabled(Self.forgetRequest == nil)
                Spacer()
            }
        } footer: {
            Text(Self.forgetRequest == nil
                ? "Deletes this Mac’s pairing at pi²’s relay, now that no device is paired. This version of pi² cannot do it yet."
                : "Deletes this Mac’s pairing at pi²’s relay, now that no device is paired. Pairing an iPhone again makes a new one.").formFooter()
        }
    }

    /// The engine's request that deletes the pairing at the relay, once there is one.
    static let forgetRequest: String? = nil

    // MARK: Changes

    private func binding(_ path: WritableKeyPath<DevicesEvent.Switches, Bool>, _ key: String) -> Binding<Bool> {
        Binding(
            get: { switches[keyPath: path] },
            set: { on in change([key: on]) }
        )
    }

    /// The engine keeps the address in its one written form, which comes back in the event and replaces what was typed.
    private func saveRelay() {
        let address = relayDraft.trimmingCharacters(in: .whitespaces)
        guard address != (state?.relay ?? "") else { return }
        Task {
            do {
                try await engine.call("devices.set", ["relayAddress": address])
                relayProblem = nil
                // Written the same way as before, the event does not change, and the draft is put back by hand.
                relayDraft = store.state?.relay ?? address
            } catch {
                relayProblem = error.localizedDescription
            }
        }
    }

    private func change(_ params: [String: Any]) {
        Task {
            do {
                try await engine.call("devices.set", params)
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func rename() {
        guard let device = renaming else { return }
        renaming = nil
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != device.name else { return }
        Task {
            do {
                try await engine.call("devices.rename", ["device": device.id, "name": name])
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    /// Every device revoked and the pairing forgotten (`devices.startAgain`, #917); then the pairing sheet, whose code
    /// registers a new pairing at the relay now set. A registration that fails is said there, and the button to pair
    /// tries again: the Mac is left with no pairing and no device, as the confirmation said.
    private func startAgain() {
        Task {
            do {
                try await engine.call("devices.startAgain")
                problem = nil
                pairing = true
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func revoke() {
        guard let device = revoking else { return }
        revoking = nil
        Task {
            do {
                try await engine.call("devices.revoke", ["device": device.id])
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// One paired device: what it is, when it was paired and last seen and how, and what can be done with it.
private struct DeviceRow: View {
    let engine: EngineClient
    let device: PairedDevice
    let log: () -> Void
    let rename: () -> Void
    let revoke: () -> Void
    @Binding var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "iphone")
                    .font(.system(size: 15))
                    .foregroundStyle(device.suspended ? Theme.tx3 : Theme.acc)
                    .frame(width: 26, height: 26)
                    .background(Theme.card2, in: .rect(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(device.name).fontWeight(.semibold).lineLimit(1)
                        if !device.kind.isEmpty { Text(device.kind).font(.caption).foregroundStyle(Theme.tx3).lineLimit(1) }
                        if device.suspended { Tag("suspended", .bad) }
                        if device.pendingPresenceKey != nil { Tag("new Face ID", .warn) }
                    }
                    Text(seen).font(.caption).foregroundStyle(Theme.tx2).lineLimit(2)
                }
                Spacer(minLength: 4)
                Button("What It Did…", action: log)
                Menu {
                    Button("Rename…", action: rename)
                    Button("Revoke…", role: .destructive, action: revoke)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Rename or revoke \(device.name)")
                .accessibilityLabel("More for \(device.name)")
            }
            if device.suspended { suspendedBox }
            if device.pendingPresenceKey != nil { faceIDBox }
        }
        .padding(.vertical, 2)
    }

    private var seen: String {
        var parts = ["Paired \(engineDate(device.pairedAt).formatted(date: .abbreviated, time: .omitted))"]
        if let last = device.lastSeenAt {
            let how = DevicePathWords.how(device.lastPath).map { ", \($0)" } ?? ""
            parts.append("last seen \(engineDate(last).formatted(.relative(presentation: .named)))\(how)")
        } else {
            parts.append("not connected yet")
        }
        return parts.joined(separator: " · ")
    }

    private var suspendedBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Suspended \(engineDate(device.suspendedAt ?? 0).formatted(date: .abbreviated, time: .shortened)): this Mac refused five of its connections or Face ID signatures in ten minutes, and takes nothing from it until you resume it. Its log says what was refused. Resume it only if it was you.")
                .font(.callout)
            HStack {
                Button("Resume \(device.name)") { act("devices.resume") }
                Button("What It Did…", action: log).buttonStyle(.link)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bad.opacity(0.1), in: .rect(cornerRadius: 8))
    }

    /// 3.2: a new presence key, used only once the person accepts it here.
    private var faceIDBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Face ID was set up again on \(device.name). Accept only if you did it yourself.")
                .font(.callout.weight(.semibold))
            Text("Until you accept it, the iPhone cannot open pi² with Face ID. Whoever knows its passcode can enrol a face, so accepting a key you did not make gives them Face ID’s answers.")
                .font(.caption).foregroundStyle(Theme.tx2)
            HStack {
                Button("Accept the New Face ID") { act("devices.acceptPresenceKey") }
                Button("Refuse It") { act("devices.refusePresenceKey") }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warn.opacity(0.12), in: .rect(cornerRadius: 8))
    }

    private func act(_ method: String) {
        Task {
            do {
                try await engine.call(method, ["device": device.id])
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

// MARK: - Pairing (3.1, 3.3)

/// Pair an iPhone: the code, kept out of screen captures while it shows; then the claim of the phone that scanned it,
/// and the field for the six digits that phone shows. The code is good for one claim and five minutes; it lives in this
/// sheet's memory alone, and is never logged or written anywhere.
struct PairingSheet: View {
    let engine: EngineClient
    @Environment(\.dismiss) private var dismiss

    /// The payload of the code, with its secret: from `devices.pairStart`'s answer, kept here and nowhere else.
    @State private var payload: String?
    @State private var expires: Double = 0
    /// When this sheet last asked for a code, to tell a window that closed since from an older one.
    @State private var started: Double = 0
    @State private var starting = false
    @State private var problem: String?
    @State private var digits = ""
    @State private var confirming = false
    @State private var wrong: String?
    @State private var paired: String?
    /// The digits matched but this Mac could not save the pairing: nothing was paired, and the phone was told so (#776).
    @State private var notSaved: String?
    /// True once the sheet's window is kept out of captures; the code is drawn only then.
    @State private var hidden = false

    private var store: DevicesStore { engine.devices }
    private var window: DevicesEvent.Window? { store.state?.pairingWindow }
    private var claim: DevicesEvent.Claim? { window?.claim }
    /// Why the window closed since this sheet opened it, when it did before a phone paired.
    private var closedWhy: String? {
        guard payload != nil, pairedName == nil, window == nil else { return nil }
        if let notSaved { return notSaved }
        if let closed = store.state?.closed, closed.at >= started { return closed.why }
        return "The pairing was closed."
    }
    /// The phone this sheet paired: by its own Pair, or by a confirmation the engine took from the app another way while
    /// the sheet was open, which closes the window with no reason and lists the device.
    private var pairedName: String? {
        if let paired { return paired }
        guard payload != nil, window == nil else { return nil }
        return store.active.last { $0.pairedAt >= started }?.name
    }
    /// The code shows while it can still be claimed: from the answer until a phone claims it or the window closes.
    private var codeShows: Bool { payload != nil && window != nil && claim == nil && pairedName == nil }

    var body: some View {
        VStack(spacing: 14) {
            Text("Pair an iPhone").font(.title3.weight(.semibold))
            content
                .frame(maxWidth: .infinity)
            Text("Kept out of screen sharing and recordings. Once paired, the iPhone can answer for you and change what agents may do. You can revoke it in Settings › Devices at any time.")
                .font(.caption).foregroundStyle(Theme.tx3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(pairedName == nil ? "Cancel" : "Done") { dismiss() }
                    .keyboardShortcut(pairedName == nil ? .cancelAction : .defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        // 3.1: the sheet asks macOS to keep it out of captures and screen sharing while the code shows.
        .background(CaptureExclusion(excluded: codeShows, title: "Pair an iPhone", applied: $hidden))
        .task { await start() }
        .onDisappear {
            // The window is this sheet's: closing the sheet closes it (3.1), and the secret goes with it.
            if pairedName == nil { engine.perform("devices.pairCancel") }
            payload = nil
        }
    }

    @ViewBuilder
    private var content: some View {
        if let paired = pairedName {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 34)).foregroundStyle(Theme.ok)
                Text("\(paired) is paired with this Mac.").font(.headline)
                Text("It finishes setting up on the iPhone, and then connects.").font(.callout).foregroundStyle(Theme.tx2)
            }
            .padding(.vertical, 20)
        } else if let problem {
            VStack(spacing: 10) {
                Text(problem).foregroundStyle(Theme.bad).multilineTextAlignment(.center)
                Button("Try Again") { Task { await start() } }
            }
            .padding(.vertical, 20)
        } else if let closedWhy {
            VStack(spacing: 10) {
                Image(systemName: "xmark.octagon").font(.system(size: 28)).foregroundStyle(Theme.bad)
                Text(closedWhy).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Button("Start Again") { Task { await start() } }
                    .buttonStyle(.piPrimary)
            }
            .padding(.vertical, 16)
        } else if let claim {
            claimView(claim)
        } else if payload != nil, window != nil {
            codeView
        } else {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Making a code…").font(.callout).foregroundStyle(Theme.tx2)
            }
            .frame(height: 220)
        }
    }

    private var codeView: some View {
        VStack(spacing: 10) {
            Text("Open pi² on your iPhone and scan this code. The iPhone can be on any network.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                if hidden, let payload, let image = PairingCode.image(payload) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 200, height: 200)
                        .padding(10)
                        .background(.white, in: .rect(cornerRadius: 8))
                        .accessibilityLabel("The pairing code")
                } else {
                    RoundedRectangle(cornerRadius: 8).fill(Theme.card2).frame(width: 220, height: 220)
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, Int(expires / 1000 - context.date.timeIntervalSince1970))
                Text("Good for \(left / 60):\(String(format: "%02d", left % 60)) more, for one iPhone")
                    .font(.caption).monospacedDigit().foregroundStyle(Theme.tx3)
            }
            Button("Make a New Code") { Task { await start() } }
                .buttonStyle(.link)
            Text("Then type here the six digits your iPhone shows.").font(.callout).foregroundStyle(Theme.tx2)
        }
    }

    private func claimView(_ claim: DevicesEvent.Claim) -> some View {
        let replaced = claim.replaces.flatMap { store.device($0) }
        let how = DevicePathWords.how(claim.path) ?? claim.path
        return VStack(spacing: 12) {
            VStack(spacing: 3) {
                Text("**\(claim.name)** wants to pair, \(how).").multilineTextAlignment(.center)
                Text([claim.model, claim.system].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(Theme.tx3)
            }
            Text("Type the six digits it shows:").font(.callout).foregroundStyle(Theme.tx2)
            TextField("", text: $digits, prompt: Text("000000"))
                .textFieldStyle(.plain)
                .font(.system(size: 26, weight: .semibold, design: .monospaced))
                .multilineTextAlignment(.center)
                .padding(.vertical, 6)
                .frame(width: 170)
                .background(Theme.card2, in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
                .accessibilityLabel("The six digits the iPhone shows")
                .onChange(of: digits) { _, typed in
                    let kept = String(typed.filter(\.isASCII).filter(\.isNumber).prefix(6))
                    if kept != typed { digits = kept }
                }
                .onSubmit { if replaced == nil { confirm(replace: false) } }
            if let wrong {
                Text(wrong).font(.callout).foregroundStyle(Theme.bad).multilineTextAlignment(.center)
            }
            if let replaced {
                Text("It has the name and model of \(replaced.name), paired \(engineDate(replaced.pairedAt).formatted(date: .abbreviated, time: .omitted)). Replacing it revokes the old pairing in the same step.")
                    .font(.caption).foregroundStyle(Theme.tx2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Pair as Another Device") { confirm(replace: false) }
                    Button("Replace \(replaced.name)") { confirm(replace: true) }
                        .buttonStyle(.piPrimary)
                }
                .disabled(digits.count != 6 || confirming)
            } else {
                Button("Pair") { confirm(replace: false) }
                    .buttonStyle(.piPrimary)
                    .disabled(digits.count != 6 || confirming)
            }
            Text("No digits on the iPhone, or not your iPhone? Cancel: nothing is paired until the digits match.")
                .font(.caption).foregroundStyle(Theme.tx3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func start() async {
        guard !starting else { return }
        starting = true
        defer { starting = false }
        problem = nil
        wrong = nil
        notSaved = nil
        digits = ""
        payload = nil
        started = Date().timeIntervalSince1970 * 1000
        do {
            let reply = try await engine.call("devices.pairStart")
            guard let text = reply["payload"]?.stringValue, case .number(let until)? = reply["expires"] else {
                problem = "The engine did not give a code."
                return
            }
            payload = text
            expires = until
        } catch {
            problem = error.localizedDescription
        }
    }

    private func confirm(replace: Bool) {
        guard digits.count == 6, !confirming, let claim else { return }
        confirming = true
        Task {
            defer { confirming = false }
            do {
                try await engine.call("devices.pairConfirm", ["digits": digits, "replace": replace])
                paired = claim.name
                wrong = nil
            } catch {
                digits = ""
                if let still = self.claim, still.wrongDigits > claim.wrongDigits {
                    // Wrong digits: the claim's count, this entry included, came with the event before the answer.
                    // Three close the window, and the claim with it.
                    let left = 3 - still.wrongDigits
                    wrong = "\(error.localizedDescription) \(left == 1 ? "1 try" : "\(left) tries") left."
                } else if self.window == nil, store.state?.closed.map({ $0.at >= started }) != true {
                    // The window closed with no reason of the engine's: the digits matched, and saving failed.
                    notSaved = "This Mac could not save the pairing, so nothing was paired: \(error.localizedDescription) The iPhone was told. Start again."
                } else {
                    wrong = error.localizedDescription
                }
            }
        }
    }
}

/// The pairing code as a picture, made in memory from the payload and never written anywhere.
enum PairingCode {
    static func image(_ payload: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// Asks macOS to keep the window this sits in out of screen captures and screen sharing while `excluded` (3.1:
/// `NSWindow.sharingType = .none`; a window's, since macOS has no such switch for a part of one), and to let it be
/// captured again once the code has gone. `applied` says when the window is kept out, and the code is drawn only then.
/// Nothing relies on it: an agent's commands can still take pictures of the screen, and 3.3 is built for that.
private struct CaptureExclusion: NSViewRepresentable {
    let excluded: Bool
    let title: String
    @Binding var applied: Bool

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.changed = { on in if applied != on { applied = on } }
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.changed = { on in if applied != on { applied = on } }
        probe.title = title
        probe.excluded = excluded
        probe.apply()
    }

    final class Probe: NSView {
        var excluded = false
        var title = ""
        var changed: (Bool) -> Void = { _ in }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            guard let window else { return }
            // Named, so that a test copy's `shot --window` finds the sheet to show that the code is not in it.
            if window.title != title { window.title = title }
            let wanted: NSWindow.SharingType = excluded ? .none : .readOnly
            if window.sharingType != wanted { window.sharingType = wanted }
            let on = excluded && window.sharingType == .none
            // Not while SwiftUI updates the view that holds the binding.
            DispatchQueue.main.async { [changed] in changed(on) }
        }
    }
}

// MARK: - A device's log (4.4)

/// What one device did: every answer and change, connection and refused try, and file it read, newest first, 200 at a
/// time, with the path, whether Face ID opened the session, and how it ended.
struct DeviceLogSheet: View {
    let engine: EngineClient
    let device: PairedDevice
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [DeviceLogEntry] = []
    @State private var loaded = false
    @State private var more = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What \(device.name) did").font(.title3.weight(.semibold))
            if let problem {
                Text(problem).foregroundStyle(Theme.bad)
            }
            if loaded && entries.isEmpty {
                Text("Nothing yet.").foregroundStyle(Theme.tx2).frame(maxWidth: .infinity, minHeight: 200)
            } else {
                Table(entries) {
                    TableColumn("When") { entry in
                        Text(when(entry.at)).monospacedDigit().foregroundStyle(Theme.tx2)
                    }
                    .width(76)
                    TableColumn("What") { entry in
                        let times = entry.count.map { $0 > 1 ? " · \($0) times, the last at \(when(entry.lastAt ?? entry.at))" : "" } ?? ""
                        Text(entry.summary + times).lineLimit(2).help(entry.summary + times)
                    }
                    .width(min: 150, ideal: 220)
                    TableColumn("Path") { entry in
                        Text(entry.path).foregroundStyle(Theme.tx2)
                    }
                    .width(50)
                    TableColumn("Face ID") { entry in
                        if entry.presence { Image(systemName: "checkmark").foregroundStyle(Theme.ok).accessibilityLabel("Face ID") }
                    }
                    .width(50)
                    TableColumn("") { entry in
                        outcome(entry)
                    }
                    .width(min: 160, ideal: 230)
                }
                .frame(minHeight: 280)
            }
            HStack {
                if more {
                    Button("Show Older") { Task { await load(before: entries.last?.at) } }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 760, height: 480)
        .task { await load(before: nil) }
    }

    private func outcome(_ entry: DeviceLogEntry) -> some View {
        let words = switch entry.outcome {
        case "refused": "refused" + (entry.why.map { ": \($0)" } ?? "")
        case "failed": "failed" + (entry.why.map { ": \($0)" } ?? "")
        default: entry.why ?? entry.outcome
        }
        return Text(words)
            .foregroundStyle(entry.outcome == "done" ? Theme.tx3 : Theme.bad)
            .lineLimit(3)
            .help(words)
    }

    private func when(_ at: Double) -> String {
        let date = engineDate(at)
        return Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    private func load(before: Double?) async {
        var params: [String: Any] = ["device": device.id]
        if let before { params["before"] = before }
        do {
            let reply = try await engine.call("devices.log", params)
            let data = try JSONEncoder().encode(reply["entries"] ?? .array([]))
            let page = try JSONDecoder().decode([DeviceLogEntry].self, from: data)
            entries = before == nil ? page : entries + page
            more = page.count >= 200
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        loaded = true
    }
}
#endif
