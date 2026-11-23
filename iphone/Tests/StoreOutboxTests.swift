import CryptoKit
import Foundation
import SwiftUI
import Testing
@testable import pi2

/// The phone's store and its Outbox (#692, docs/iphone.md 3.6): what is kept, how it is kept on disk, how it is wiped,
/// the last state shown again with the Mac out of reach, and the Outbox sent once it is back.
@MainActor
struct StoreOutboxTests {
    /// A clock the test moves.
    @MainActor
    final class Clock {
        var date = Date(timeIntervalSince1970: 1_790_000_000)
        func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
    }

    /// A folder of the test's own, in the app's container: under Application Support when the test lists the container,
    /// else under tmp.
    private func folder(inSupport: Bool = false) -> StoreFolder {
        let base = inSupport
            ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            : FileManager.default.temporaryDirectory
        return StoreFolder(base.appending(path: "pi2-test-\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    private func eventually(_ seconds: Double = 30, _ condition: () -> Bool) async throws -> Bool {
        let end = Date(timeIntervalSinceNow: seconds)
        while !condition() {
            if Date() > end { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func line(_ object: [String: Any]) -> Data {
        var data = try! JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        return data
    }

    private func conversation(_ id: Int, reset: Bool, items: ClosedRange<Int>?, busy: Bool = false) -> Data {
        let entries: [[String: Any]] = items.map { range in range.map { ["id": $0, "kind": "assistant", "text": "entry \($0)"] } } ?? []
        return line(["event": "conversation", "id": id, "reset": reset, "items": entries, "state": ["busy": busy, "queued": [Any]()]])
    }

    // MARK: - On disk

    @Test func filesAreProtectedOutOfBackupsAndSealed() throws {
        let folder = folder()
        defer { try? folder.remove() }
        let store = PhoneStore(folder: folder)
        store.open(key: SymmetricKey(size: .bits256))
        store.take(lines: line(["event": "projects", "projects": [["id": "p-1", "name": "Marker project name"]]]))
        try Outbox(store: store).add("submit", ["id": 9, "text": "Marker message text"])
        store.saveNow()

        #expect(folder.names() == [PhoneStore.cacheFile, StoreManifest.file, PhoneStore.outboxFile].sorted())
        #expect(StoreFolder.protection == .complete)
        #expect(StoreFolder.fileOptions.contains(.completeFileProtection))
        for url in [folder.url] + folder.names().map({ folder.url.appending(path: $0) }) {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #if targetEnvironment(simulator)
            // The simulator keeps no protection class: the attribute set reads back as none, and the file's resource
            // value as the default class whatever was asked. So here only what the store asks for is checked (above).
            #expect(attributes[.protectionKey] == nil, "the simulator began keeping protection classes: check them here")
            #else
            #expect(attributes[.protectionKey] as? FileProtectionType == .complete, "\(url.lastPathComponent)")
            #expect(try url.resourceValues(forKeys: [.fileProtectionKey]).fileProtection == .complete, "\(url.lastPathComponent)")
            #endif
            #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true, "\(url.lastPathComponent)")
        }
        // The sealed parts hold none of their text in the clear; the manifest holds dates and a number only.
        for name in [PhoneStore.cacheFile, PhoneStore.outboxFile, StoreManifest.file] {
            let text = String(decoding: try #require(folder.read(name)), as: UTF8.self)
            #expect(!text.contains("Marker"), "\(name)")
        }
    }

    @Test func sealedPartsOpenOnlyWithTheirKey() throws {
        let folder = folder()
        defer { try? folder.remove() }
        let key = SymmetricKey(size: .bits256)
        let store = PhoneStore(folder: folder)
        store.open(key: key)
        store.take(lines: line(["event": "needs", "items": [Any]()]))
        try Outbox(store: store).add("abort", ["id": 9])
        store.close()
        #expect(store.cache.isEmpty && store.outbox.isEmpty, "closing forgets what was read")

        // The same key reads both again.
        let again = PhoneStore(folder: folder)
        #expect(again.open(key: key).unreadable.isEmpty)
        #expect(again.cache.events.map(\.kind) == ["needs"])
        #expect(again.outbox.map(\.method) == ["abort"])
        again.close()

        // A new cache key (Face ID enrolled again) reads neither, and both are wiped.
        let other = PhoneStore(folder: folder)
        #expect(other.open(key: SymmetricKey(size: .bits256)).unreadable == [.cache, .outbox])
        #expect(other.cache.isEmpty && other.outbox.isEmpty)
        #expect(folder.names() == [StoreManifest.file])
        #expect(other.lastWipe == .unreadable)
    }

    // MARK: - Wiping

    /// Every file under the container's Application Support, Documents and tmp, but other tests' folders.
    private func containerFiles(own: StoreFolder) -> Set<String> {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var found: Set<String> = []
        for place in ["Library/Application Support", "Documents", "tmp"] {
            let root = home.appending(path: place)
            guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walk {
                let path = url.path
                if path.contains("/pi2-test-"), !path.hasPrefix(own.url.path) { continue }
                found.insert(path)
            }
        }
        return found
    }

    @Test func wipingLeavesNothingInTheContainer() throws {
        let folder = folder(inSupport: true)
        defer { try? folder.remove() }
        let before = containerFiles(own: folder)

        let store = PhoneStore(folder: folder)
        store.open(key: SymmetricKey(size: .bits256))
        store.take(lines: line(["event": "projects", "projects": [Any]()]))
        store.take(lines: conversation(9, reset: true, items: 1...3))
        let outbox = Outbox(store: store)
        try outbox.add("submit", ["id": 9, "text": "Waiting for the Mac"])
        try outbox.add("inbox.decide", ["id": "n-1", "decision": "once"])
        #expect(store.takeState(number: 3))
        store.saveNow()

        // Everything the store wrote is inside its folder.
        let during = containerFiles(own: folder).subtracting(before)
        #expect(!during.isEmpty)
        #expect(during.allSatisfy { $0.hasPrefix(folder.url.path) }, "\(during.sorted())")

        // One call: the folder goes whole, and what was not sent comes back, to be shown before it is gone.
        let unsent = store.wipe(.revoked)
        #expect(unsent.map(\.summary) == ["Waiting for the Mac", "Allow once"])
        #expect(!folder.exists)
        #expect(containerFiles(own: folder) == before)
        #expect(store.cache.isEmpty && store.outbox.isEmpty && store.manifest == StoreManifest())

        // Revoked, the store is closed: a line that still comes writes nothing.
        store.take(lines: line(["event": "needs", "items": [Any]()]))
        store.saveNow()
        #expect(!folder.exists)
        #expect(throws: StoreError.self) { try outbox.add("abort", ["id": 9]) }
    }

    @Test func sevenDaysWithoutTheMacWipeTheCache() throws {
        let folder = folder()
        defer { try? folder.remove() }
        let clock = Clock()
        let key = SymmetricKey(size: .bits256)
        let store = PhoneStore(folder: folder, now: { clock.date })
        store.open(key: key)
        store.take(lines: line(["event": "projects", "projects": [Any]()]))
        store.saveNow()
        #expect(store.lastHeard == clock.date)

        clock.advance(PhoneStore.keptWithoutMac - 60)
        #expect(PhoneStore(folder: folder, now: { clock.date }).sweep().isEmpty)

        // The Outbox was written later, so it is kept while the cache goes.
        clock.advance(-3 * 86_400)
        try Outbox(store: store, now: { clock.date }).add("abort", ["id": 1])
        store.close()
        clock.advance(3 * 86_400 + 120)
        let later = PhoneStore(folder: folder, now: { clock.date })
        #expect(later.sweep() == [.cache])
        #expect(folder.names() == [StoreManifest.file, PhoneStore.outboxFile].sorted())
        later.open(key: key)
        #expect(later.cache.isEmpty)
        #expect(later.outbox.count == 1)
        later.close()

        // And once the Outbox too has gone seven days untouched, the whole store goes, its folder with it.
        clock.advance(PhoneStore.keptWithoutMac)
        let last = PhoneStore(folder: folder, now: { clock.date })
        #expect(last.sweep() == [.outbox])
        #expect(!folder.exists)
        #expect(last.lastWipe == .expired)
    }

    @Test func versionsTheBuildCannotReadAreWiped() throws {
        let folder = folder()
        defer { try? folder.remove() }
        #expect(StoreMigrations.plan(nil, folder: folder) == .fresh)
        try StoreManifest(version: StoreMigrations.current).write(folder)
        #expect(StoreMigrations.plan(StoreManifest.read(folder), folder: folder) == .upToDate)
        // Version 1 kept its dates in milliseconds since 1970, which this build would misread (#838).
        #expect(StoreMigrations.plan(StoreManifest(version: 1), folder: folder) == .discard("The store's version 1 has no way to this build's 2."))

        // Written by a newer build: wiped as the store opens.
        try StoreManifest(version: StoreMigrations.current + 1).write(folder)
        try folder.write(Data("sealed by a newer build".utf8), as: PhoneStore.cacheFile)
        let store = PhoneStore(folder: folder)
        #expect(store.lastWipe == .unreadable)
        #expect(!folder.exists)

        // Files with no manifest it can read: wiped too.
        try folder.write(Data("?".utf8), as: PhoneStore.outboxFile)
        #expect(PhoneStore(folder: folder).lastWipe == .unreadable)
        #expect(!folder.exists)
    }

    /// An item read back is the item written, its dates to the last bit, whatever the fraction of a second (#838).
    @Test func anItemReadBackIsTheItemWritten() throws {
        var written: [OutboxItem] = []
        for _ in 0..<1_000 {
            var item = try OutboxItem.make("submit", ["id": 9, "text": "Hello"], at: Date(timeIntervalSinceNow: .random(in: -86_400...86_400))).get()
            item.state = .inMailbox(Date(timeIntervalSinceNow: .random(in: -86_400...86_400)))
            written.append(item)
        }
        #expect(try PhoneStore.decoder.decode([OutboxItem].self, from: PhoneStore.encoder.encode(written)) == written)

        // And through the store, closed and opened again.
        let folder = folder()
        defer { try? folder.remove() }
        let key = SymmetricKey(size: .bits256)
        let store = PhoneStore(folder: folder)
        store.open(key: key)
        let outbox = Outbox(store: store)
        for _ in 0..<20 { _ = try outbox.add("submit", ["id": 9, "text": "Carry on"]) }
        let items = outbox.items
        store.close()
        let again = PhoneStore(folder: folder)
        again.open(key: key)
        #expect(Outbox(store: again).items == items)
    }

    @Test func statesOnlyRise() throws {
        let folder = folder()
        defer { try? folder.remove() }
        let store = PhoneStore(folder: folder)
        store.open(key: SymmetricKey(size: .bits256))
        #expect(store.takeState(number: 5))
        #expect(store.takeState(number: 5))
        #expect(store.takeState(number: 7))
        #expect(!store.takeState(number: 6))
        // After a restart too.
        #expect(PhoneStore(folder: folder).manifest.shownState == 7)
    }

    // MARK: - The cache

    @Test func theCacheKeepsTheLatestStateAndNewestEntries() throws {
        var cache = StateCache()
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        cache.take(line(["event": "projects", "projects": [["id": "p-1"]]]), at: date)
        cache.take(line(["event": "needs", "items": [Any]()]), at: date)
        cache.take(line(["event": "projects", "projects": [["id": "p-2"]]]), at: date)
        // Never kept: what a phone is never sent, and answers to requests.
        let tookMcp = cache.take(line(["event": "mcp", "servers": [Any]()]), at: date)
        let tookReply = cache.take(line(["id": 3, "result": ["secret": "no"]]), at: date)
        #expect(!tookMcp && !tookReply)
        #expect(cache.events.map(\.kind) == ["projects", "needs"])
        #expect(cache.events[0].line.contains("p-2"))
        #expect(cache.heardAt == date)

        // A conversation: sent from the start, then added to; at most the newest 300 entries.
        let tookUpdate = cache.take(conversation(4, reset: false, items: 1...2), at: date)
        #expect(!tookUpdate, "an update with nothing to add to")
        cache.take(conversation(4, reset: true, items: 101...350), at: date)
        cache.take(conversation(4, reset: false, items: 351...400, busy: true), at: date)
        let conversation4 = try #require(cache.conversations.first)
        #expect(conversation4.items.count == StateCache.entries)
        #expect(conversation4.items.first?.contains("\"id\":101") == true)
        #expect(conversation4.items.last?.contains("\"id\":400") == true)
        #expect(conversation4.state.contains("true"))

        // Its line, sent from the start, reads as the engine's.
        let synthesized = try #require(cache.conversationLine(4))
        let object = try #require(try JSONSerialization.jsonObject(with: synthesized) as? [String: Any])
        #expect(object["reset"] as? Bool == true)
        #expect((object["items"] as? [Any])?.count == 300)

        // Older entries fill only what is left of the 300.
        cache.take(conversation(5, reset: true, items: 90...100), at: date)
        cache.take(line(["event": "conversation.older", "id": 5, "earlier": 0, "items": (80...95).map { ["id": $0, "kind": "user", "text": "x"] }]), at: date)
        let conversation5 = try #require(cache.conversations.first { $0.id == 5 })
        #expect(conversation5.items.count == 21)
        #expect(conversation5.items.first?.contains("\"id\":80") == true)

        // At most 20 conversations, each sent in the last seven days.
        for id in 10..<40 { cache.take(conversation(id, reset: true, items: 1...1), at: date.addingTimeInterval(Double(id))) }
        #expect(cache.conversations.count == StateCache.conversationLimit)
        #expect(Set(cache.conversations.map(\.id)) == Set(20..<40))
        cache.prune(at: date.addingTimeInterval(7 * 86_400 + 30))
        #expect(Set(cache.conversations.map(\.id)) == Set(30..<40))
    }

    /// The issue's "done when", short of a real channel: a session shown the Mac's state, the app stopped and started
    /// again with the Mac out of reach, the last state shown, a message written to the Outbox, then the Mac back and the
    /// Outbox sent.
    @Test func afterARestartTheLastStateIsShownThenTheOutboxSent() async throws {
        let folder = folder()
        defer { try? folder.remove() }
        let key = SymmetricKey(size: .bits256)

        // The first launch: connected, and the cache follows what the Mac sends.
        let store = PhoneStore(folder: folder)
        store.open(key: key)
        let first = AppSession()
        first.start(RecordingTransport(try #require(ReplayTransport.recording()), store: store), as: .connected(.relay))
        #expect(try await eventually { first.engine.projects.count == 2 })
        let orchestrator = try #require(first.engine.projects.first { $0.name == "Demo project" }?.conversation)
        first.engine.openConversation(orchestrator)
        #expect(try await eventually { first.engine.open[orchestrator]?.items.isEmpty == false })
        let entries = try #require(first.engine.open[orchestrator]?.items.map(\.id))
        let needs = first.engine.needs.map(\.id)
        store.close()

        // Started again with the Mac out of reach: the last state, dated.
        let restarted = PhoneStore(folder: folder)
        #expect(restarted.lastHeard != nil)
        restarted.open(key: key)
        let outbox = Outbox(store: restarted)
        let second = AppSession()
        second.start(CachedTransport(restarted.cache, outbox: outbox), as: .outOfReach(lastSeen: restarted.lastHeard))
        #expect(try await eventually { second.engine.projects.count == 2 })
        #expect(second.engine.projects.map(\.name) == first.engine.projects.map(\.name))
        #expect(second.engine.needs.map(\.id) == needs)
        second.engine.openConversation(orchestrator)
        #expect(try await eventually { second.engine.open[orchestrator]?.items.isEmpty == false })
        #expect(second.engine.open[orchestrator]?.items.map(\.id) == Array(entries.suffix(StateCache.entries)))

        // A message goes to the Outbox; what needs the Mac is refused, saying so.
        #expect(await second.engine.submit("Carry on when you wake", to: orchestrator, steer: false) == .sent)
        #expect(outbox.items.map(\.summary) == ["Carry on when you wake"])
        await #expect(throws: (any Error).self) { try await second.engine.call("projects.rename", ["id": "x", "name": "y"]) }
        let written = try #require(outbox.items.first)
        restarted.close()

        // The Mac back: the Outbox, kept across another restart, goes first, with the id it was written with.
        let third = PhoneStore(folder: folder)
        third.open(key: key)
        let back = Outbox(store: third)
        #expect(back.items == [written])
        let mac = StandInMac()
        let report = await back.send(through: mac)
        #expect(report.taken == [written.id])
        #expect(mac.taken.map(\.method) == ["submit"])
        #expect(mac.taken.first?.parameters["requestId"] as? String == written.parameters["requestId"] as? String)
        #expect(back.items.isEmpty)
    }

    // MARK: - The Outbox

    /// A Mac that takes each item once by its id, as the engine takes a message once by its request id and the mailbox
    /// an item once by its nonce; told so, it fails, refuses, or takes an item and loses its answer.
    @MainActor
    final class StandInMac: OutboxCourier {
        enum Mood { case takes, unreachable, refuses(String), takesAndLosesTheAnswer, mailbox }
        var mood: [String: Mood] = [:]
        var otherwise: Mood = .takes
        private(set) var handed: [String] = []
        private(set) var taken: [OutboxItem] = []

        func deliver(_ item: OutboxItem) async -> OutboxDelivery {
            handed.append(item.id)
            await Task.yield()
            switch mood[item.id] ?? otherwise {
            case .takes:
                if !taken.contains(where: { $0.id == item.id }) { taken.append(item) }
                return .taken
            case .unreachable:
                return .unreachable("The Mac can't be reached.")
            case .refuses(let why):
                return .refused(why)
            case .takesAndLosesTheAnswer:
                if !taken.contains(where: { $0.id == item.id }) { taken.append(item) }
                mood[item.id] = .takes
                return .unreachable("The connection went before the Mac answered.")
            case .mailbox:
                return .inMailbox
            }
        }
    }

    private func openStore(_ clock: Clock? = nil) -> (PhoneStore, Outbox, StoreFolder) {
        let folder = folder()
        let now: @MainActor @Sendable () -> Date
        if let clock { now = { clock.date } } else { now = { Date() } }
        let store = PhoneStore(folder: folder, now: now)
        store.open(key: SymmetricKey(size: .bits256))
        return (store, Outbox(store: store, now: now), folder)
    }

    @Test func itemsGoOldestFirstAndStopWhereTheMacCannotBeReached() async throws {
        let (_, outbox, folder) = openStore()
        defer { try? folder.remove() }
        let one = try outbox.add("submit", ["id": 1, "text": "one"])
        let two = try outbox.add("inbox.answer", ["id": "q-1", "text": "two"])
        let three = try outbox.add("abort", ["id": 1])

        let mac = StandInMac()
        mac.mood[two.id] = .unreachable
        let first = await outbox.send(through: mac)
        #expect(first.taken == [one.id])
        #expect(first.stopped != nil)
        #expect(mac.handed == [one.id, two.id], "nothing written later overtakes what could not go")
        #expect(outbox.items.map(\.id) == [two.id, three.id])
        #expect(outbox.items.first?.state == .waiting)
        #expect(outbox.items.first?.tries == 1)

        mac.mood[two.id] = .refuses("This is no longer waiting: it was answered or withdrawn.")
        let second = await outbox.send(through: mac)
        #expect(second.notSent == [two.id])
        #expect(second.taken == [three.id])
        #expect(outbox.items.map(\.id) == [two.id])
        #expect(outbox.items.first?.state == .notSent("This is no longer waiting: it was answered or withdrawn."))
        #expect(mac.taken.map(\.id) == [one.id, three.id])
    }

    @Test func aResendIsNeverADuplicate() async throws {
        let (store, outbox, folder) = openStore()
        defer { try? folder.remove() }
        let item = try outbox.add("submit", ["id": 1, "text": "once only", "requestId": "r-1"])
        #expect(item.parameters["requestId"] as? String == "r-1")

        // The Mac takes it and the answer is lost: it is sent again, with the same id, and taken once.
        let mac = StandInMac()
        mac.mood[item.id] = .takesAndLosesTheAnswer
        #expect(await outbox.send(through: mac).stopped != nil)
        #expect(outbox.items.map(\.id) == [item.id])
        #expect(await outbox.send(through: mac).taken == [item.id])
        #expect(mac.handed == [item.id, item.id])
        #expect(mac.taken.count == 1)

        // The app stopped while one was on its way: it is still there, and goes again with its id.
        let stuck = try outbox.add("abort", ["id": 1])
        var all = store.outbox
        all[0].state = .sending
        try store.setOutbox(all)
        let again = Outbox(store: store)
        #expect(again.items.first?.isPending == true)
        #expect(await again.send(through: mac).taken == [stuck.id])

        // Two rounds at once hand nothing over twice.
        let third = try outbox.add("abort", ["id": 2])
        let slow = StandInMac()
        async let a = outbox.send(through: slow)
        async let b = outbox.send(through: slow)
        let (ra, rb) = await (a, b)
        #expect(ra.taken.count + rb.taken.count == 1)
        #expect(slow.handed == [third.id])
    }

    @Test func lateItemsAreNotSentAndKeepTheirText() async throws {
        let clock = Clock()
        let (_, outbox, folder) = openStore(clock)
        defer { try? folder.remove() }
        let answer = try outbox.add("needs.answer", ["id": "n-1", "answer": ["kind": "question", "text": "Use the second one"]])
        let widening = try outbox.add("needs.answer", ["id": "n-2", "answer": ["kind": "reach", "allow": true]])
        #expect(!answer.widens && widening.widens)
        #expect(widening.lifetime == 3_600 && answer.lifetime == 86_400)

        clock.advance(3_600 + 1)
        let mac = StandInMac()
        let report = await outbox.send(through: mac)
        #expect(report.notSent == [widening.id])
        #expect(report.taken == [answer.id])
        #expect(outbox.items.first?.state == .notSent(widening.tooLate))

        // Sent again: a new item, a new id, the same answer.
        let resent = try outbox.sendAgain(widening.id)
        #expect(resent.id != widening.id)
        #expect(resent.summary == "Allow")
        #expect(outbox.items.map(\.id) == [resent.id])

        // In the mailbox: the Mac's receipt settles it; with none, too late says so.
        mac.otherwise = .mailbox
        #expect(await outbox.send(through: mac).inMailbox == [resent.id])
        if case .inMailbox = outbox.items.first?.state {} else { Issue.record("not in the mailbox") }
        let message = try outbox.add("submit", ["id": 3, "text": "Sealed for the Mac"])
        #expect(await outbox.send(through: mac).inMailbox == [message.id])
        outbox.receipt(for: message.id, taken: true)
        #expect(outbox.items.map(\.id) == [resent.id])
        clock.advance(3_600 + 1)
        outbox.expire()
        if case .notSent = outbox.items.first?.state {} else { Issue.record("a mailbox item with no receipt stays as if it might go") }
    }

    @Test func theOutboxTakesOnlyWhatCanWaitForTheMac() throws {
        let (store, outbox, folder) = openStore()
        defer { try? folder.remove() }
        #expect(throws: StoreError(CachedTransport.needsTheMac)) { try outbox.add("projects.rename", ["id": "p", "name": "x"]) }
        #expect(throws: StoreError.self) { try outbox.add("submit", ["id": 1, "text": String(repeating: "a", count: 4_001)]) }
        #expect(throws: StoreError.self) { try outbox.add("submit", ["id": 1, "text": "a photo", "attachments": [["name": "a.png"]]]) }
        #expect(try outbox.add("submit", ["id": 1, "text": String(repeating: "a", count: 4_000)]).kind == .message)
        #expect(try outbox.add("inbox.decide", ["id": "a-1", "decision": "always"]).widens)
        #expect(try !outbox.add("inbox.decide", ["id": "a-1", "decision": "once"]).widens)
        #expect(try outbox.add("submit", ["id": 1, "text": "past a limit", "confirmLimit": true]).widens)
        for index in outbox.items.count..<Outbox.limit { try outbox.add("abort", ["id": index]) }
        #expect(throws: StoreError.self) { try outbox.add("abort", ["id": 0]) }
        #expect(outbox.items.count == Outbox.limit)

        // Each item's id reads as a sealed item's: 16 bytes as base64url.
        let id = try #require(outbox.items.first?.id)
        #expect(id.count == 22 && !id.contains("=") && !id.contains("+") && !id.contains("/"))
        #expect(Set(outbox.items.map(\.id)).count == Outbox.limit)

        // Closed, it takes nothing.
        store.close()
        #expect(throws: StoreError.self) { try outbox.add("abort", ["id": 1]) }
    }

    @Test func theOutboxLineCounts() {
        #expect(OutboxLine.words(waiting: 1, notSent: 0) == "Outbox: 1 waits for your Mac")
        #expect(OutboxLine.words(waiting: 2, notSent: 1) == "Outbox: 2 wait for your Mac, 1 not sent")
    }
}
