
import SwiftUI
import Testing
import UIKit
@testable import pi2

/// Pictures of every pairing screen and connection state (#680), drawn in the simulator in the app's own window scene,
/// in both appearances and at the largest text size, into the folder `PI2_SHOTS` names
/// (`TEST_RUNNER_PI2_SHOTS=<folder>` for xcodebuild). The pairing screens are not reachable from the first screen until
/// `App/` places them, so the test draws them; the digits and paired screens come from a real pairing with the test Mac.
@MainActor
@Suite(.serialized, .enabled(if: TestPlaces.shots != nil, "PI2_SHOTS names no folder"))
struct PairingShots {
    static var folder: URL? { TestPlaces.shots }

    enum Look: CaseIterable {
        case light, dark, largest

        var suffix: String {
            switch self {
            case .light: "light"
            case .dark: "dark"
            case .largest: "largest"
            }
        }
    }

    /// Draws `view` full screen in a window of the app's scene and writes it as `<name>-<look>.png`.
    static func shoot(_ name: String, _ looks: [Look] = Look.allCases, _ view: () -> some View) async throws {
        let folder = try #require(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for look in looks {
            let size: DynamicTypeSize = look == .largest ? .accessibility5 : .large
            let window = UIWindow(windowScene: scene)
            window.frame = scene.screen.bounds
            window.overrideUserInterfaceStyle = look == .dark ? .dark : .light
            window.traitOverrides.preferredContentSizeCategory = look == .largest ? .accessibilityExtraExtraExtraLarge : .large
            window.rootViewController = UIHostingController(rootView: view().environment(\.dynamicTypeSize, size))
            window.windowLevel = .alert + 1
            window.isHidden = false
            // Let it lay out and draw: a few turns of the run loop, never a guess at how long the Mac takes.
            for _ in 0..<20 { try await Task.sleep(for: .milliseconds(50)) }
            let picture = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try #require(picture.pngData()).write(to: folder.appendingPathComponent("\(name)-\(look.suffix).png"))
            window.isHidden = true
        }
    }

    static func scanningFlow() -> PairingFlow {
        PairingFlow(needs: PairingFlow.Needs(keyStore: MemoryKeyStore(), attester: NoAttester(), store: MemoryPairingStore(), phone: .test))
    }

    @Test func theScanner() async throws {
        let flow = Self.scanningFlow()
        try await Self.shoot("scan-no-camera") { PairingView(flow: flow, camera: .none) }
        try await Self.shoot("scan-camera-denied") { PairingView(flow: flow, camera: .denied) }
    }

    @Test func eachFailure() async throws {
        let failures: [(String, PairingFailure)] = [
            ("not-a-code", .notACode), ("expired", .expired), ("unreachable", .unreachable), ("relay-token", .relayRefused("token")),
            ("relay-attestation", .relayRefused("attestation")), ("no-app-attest", .noAppAttest), ("mac-not-proved", .macNotProved),
            ("mac-did-not-pair", .macDidNotPair), ("mac-could-not-save", .macCouldNotSave), ("cancelled-on-mac", .cancelledOnMac),
            ("attestation", .attestation), ("keys", .keys),
        ]
        for (name, failure) in failures {
            try await Self.shoot("failed-\(name)", ["mac-did-not-pair", "mac-could-not-save"].contains(name) ? Look.allCases : [.light]) {
                NavigationStack { PairingFailedScreen(failure: failure, again: {}) }
            }
        }
    }

    @Test func theOtherScreens() async throws {
        try await Self.shoot("replace") {
            NavigationStack { PairingReplaceScreen(current: "Studio Mac", new: "Alex's MacBook Pro", replace: {}, keep: {}) }
        }
        try await Self.shoot("reaching") { NavigationStack { PairingReachingScreen(mac: "Alex's MacBook Pro") } }
        try await Self.shoot("digits-home", [.light]) { NavigationStack { PairingDigitsScreen(digits: "048213", mac: "Alex's MacBook Pro", path: .home) } }
    }

    /// The digits and paired screens from a real pairing over loopback TCP with the test Mac.
    @Test func aRealPairing() async throws {
        let mac = TestMac()
        defer { mac.stop() }
        let address = try await mac.listen()
        let flow = PairingFlow(needs: PairingTests.needs(MemoryKeyStore(), MemoryPairingStore()))
        flow.scanned(try mac.payload(relay: PairingTests.noRelay, addresses: [address]).text)
        #expect(await Wait.until { if case .digits = flow.step { true } else { false } })
        try await Self.shoot("digits") { PairingView(flow: flow) }
        guard case let .digits(digits, _, _) = flow.step else { return }
        mac.typed.push(digits)
        #expect(await Wait.until { if case .paired = flow.step { true } else { false } })
        try await Self.shoot("paired") { PairingView(flow: flow) }
    }

    /// The connection bar drawn for each state `RemoteConnection` computes, and the problems' cards.
    @Test func theConnectionsStates() async throws {
        let states: [(String, AppSession.Connection)] = [
            ("connecting", .connecting), ("connected-relay", .connected(.relay)), ("connected-home", .connected(.home, relayReachable: true)),
            ("connected-home-relay-down", .connected(.home, relayReachable: false)), ("connected-direct", .connected(.direct, relayReachable: false)),
            ("out-of-reach", .outOfReach(lastSeen: Date(timeIntervalSinceNow: -40 * 60))), ("not-paired", .notPaired),
        ]
        for (name, state) in states {
            let session = AppSession(connection: state)
            session.macName = "Alex's MacBook Pro"
            try await Self.shoot("bar-\(name)", name == "out-of-reach" ? Look.allCases : [.light]) {
                VStack { HomeConnectionBar(); Spacer() }.padding().environment(session)
            }
        }
        let problems: [(String, ConnectionProblem)] = [
            ("update", .update), ("suspended", .suspended), ("presence", .presence), ("clock", .clock), ("face-id", .faceID(.sessionNotOpen)),
            ("mac-not-proved", .macNotProved), ("relay-left", .relaySaid("left")),
        ]
        for (name, problem) in problems {
            let session = AppSession(connection: .outOfReach(lastSeen: Date(timeIntervalSinceNow: -5 * 60)))
            session.macName = "Alex's MacBook Pro"
            try await Self.shoot("problem-\(name)", name == "clock" || name == "relay-left" ? Look.allCases : [.light]) {
                VStack(spacing: 12) {
                    HomeConnectionBar()
                    ConnectionProblemNotice(problem: problem, tryAgain: {})
                    Spacer()
                }
                .padding()
                .environment(session)
            }
        }
    }
}

/// Where the tests that need something outside the simulator find it, from the environment xcodebuild gives them.
enum TestPlaces {
    static var shots: URL? { ProcessInfo.processInfo.environment["PI2_SHOTS"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    static var relay: URL? { ProcessInfo.processInfo.environment["PI2_RELAY"].flatMap(URL.init(string:)) }
}
