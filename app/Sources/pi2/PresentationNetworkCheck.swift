#if PI2_DEVELOPMENT
import Foundation
import PiModels

/// Drives the window's version-following and consent handlers in a test copy, with no WebKit page or engine requests.
@MainActor
enum PresentationNetworkCheck {
    static let asked = ProcessInfo.processInfo.environment["PI2_SHOW"] == "presentation:network-check"

    static func run(note: (String) -> Void) async {
        var failures = 0
        func check(_ name: String, _ holds: Bool) {
            if !holds { failures += 1 }
            note("presentation network check: \(holds ? "ok" : "FAIL") \(name)")
        }

        let ref = PresentationRef(conversation: 1, presentation: "p1")
        let one = PresentationWindowModel.NetworkTarget(ref: ref, version: 1)
        let two = PresentationWindowModel.NetworkTarget(ref: ref, version: 2)
        var allowed: Set<Int> = []
        var writes: [Int] = []
        var beforeWrite: (() async -> Void)?
        let feed = PresentationFeed(
            list: { [] }, updates: { AsyncStream { $0.finish() } },
            picture: { _, _ in throw NoPage() }, page: { _ in throw NoPage() }, files: { _, _ in fatalError("No live page in this check") },
            setNetwork: { version, allow in
                await beforeWrite?()
                writes.append(version)
                if allow { allowed.insert(version) } else { allowed.remove(version) }
            }
        )
        let model = PresentationWindowModel(ref: ref, feed: feed)
        func show(_ newest: Int) { model.take(record(through: newest, allowed: allowed)) }

        show(1)
        check("first version starts off", !model.networkAllowed)
        model.askNetworkConsent()
        check("opening captures conversation, presentation and version", model.networkConsent == one)
        model.dismissNetworkConsent()
        check("Cancel clears consent and leaves the network off", model.networkConsent == nil && !model.networkAllowed && writes.isEmpty)

        model.askNetworkConsent()
        let original = model.networkConsent
        show(2)
        model.askNetworkConsent()
        check("following a new version does not rewrite the open consent", original == one && model.networkConsent == original && model.networkTarget == two)
        model.dismissNetworkConsent()
        let stale = original.flatMap(model.confirmNetworkConsent)
        model.step(version: -1) // Going back after clicking does not make a stale confirmation valid.
        await stale?.value
        check("stale Allow writes nothing for either version", stale == nil && writes.isEmpty && !model.networkAllowed)
        model.step(version: 1)

        model.askNetworkConsent()
        let fresh = model.networkConsent
        show(2) // Another record for the same version, as when a snapshot is drawn.
        model.dismissNetworkConsent()
        if let fresh { await model.confirmNetworkConsent(fresh)?.value }
        show(2)
        check("fresh Allow for an unchanged target turns on only that version", fresh == two && writes == [2] && allowed == [2] && model.networkAllowed)
        show(3)
        check("the next version does not inherit the grant", model.versionNumber == 3 && !model.networkAllowed)

        model.askNetworkConsent()
        let third = model.networkConsent
        model.dismissNetworkConsent()
        for other in [PresentationRef(conversation: 2, presentation: "p1"), PresentationRef(conversation: 1, presentation: "p2")] {
            await model.confirmNetworkConsent(.init(ref: other, version: 3))?.value
        }
        check("same version number in another conversation or presentation grants nothing", writes == [2])

        if let third {
            let pending = model.confirmNetworkConsent(third)
            show(4) // Same actor: the new version is shown before the confirmation task can run.
            await pending?.value
            check("a version change before the task runs writes nothing", pending != nil && writes == [2] && !model.networkAllowed)
        } else {
            check("the third version has a consent target", false)
        }

        model.askNetworkConsent()
        let fourth = model.networkConsent
        model.dismissNetworkConsent()
        beforeWrite = { await Task { @MainActor in show(5) }.value } // Follow a version while the request is in flight.
        if let fourth { await model.confirmNetworkConsent(fourth)?.value }
        beforeWrite = nil
        show(5)
        check("an in-flight request still writes only the confirmed version", writes == [2, 4] && allowed == [2, 4] && model.versionNumber == 5 && !model.networkAllowed)
        model.close()
        note("presentation network check: \(failures == 0 ? "all passed" : "\(failures) failed")")
    }

    private struct NoPage: Error {}

    private static func record(through newest: Int, allowed: Set<Int>) -> PresentationRecord {
        let item = PresentedItem(label: "Page", caption: nil, kind: .page, name: "index.html", mimeType: "text/html",
                                 sha256: String(repeating: "0", count: 64), bytes: 1, files: 1, width: nil, height: nil, snapshot: .pending, drawn: nil)
        return PresentationRecord(id: "p1", versions: (1...newest).map { version in
            PresentedVersion(version: version, callId: "sample-\(version)", createdAt: 0, title: "Sample", items: [item], question: nil,
                             network: PresentedNetwork(allowed: allowed.contains(version), changes: []))
        })
    }
}
#endif
