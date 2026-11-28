import Foundation
import Testing
@testable import pi2

// The Keychain group the app shares with its notification service extension (docs/iphone.md 3.2, #682): the value the
// build expanded into `PI2KeychainAccessGroup`, which is a group only when a signed build put the team's prefix in it.
// No Keychain call is made: what a signed build does with the group is the owner's phone's to show (docs/iphone-app.md
// "The extensions": an unsigned build has no Keychain at all).
@Suite struct KeychainGroupTests {
    @Test func aSignedBuildsGroupIsTheOneTheEntitlementsGive() {
        #expect(KeychainGroup.group(from: "ABCDE12345.group.dev.pi2.ios") == "ABCDE12345.group.dev.pi2.ios")
    }

    @Test func aBuildWithNoPrefixNamesNoGroup() {
        // What the simulator's Info.plist holds: `$(AppIdentifierPrefix)` expands to nothing without a profile.
        #expect(KeychainGroup.group(from: "group.dev.pi2.ios") == nil)
        #expect(KeychainGroup.group(from: "$(AppIdentifierPrefix)group.dev.pi2.ios") == nil)
        #expect(KeychainGroup.group(from: "") == nil)
        #expect(KeychainGroup.group(from: nil) == nil)
        // A prefix that is not a team's, and nothing after it.
        #expect(KeychainGroup.group(from: "ABCDE1234.group.dev.pi2.ios") == nil)
        #expect(KeychainGroup.group(from: "abcde12345.group.dev.pi2.ios") == nil)
        #expect(KeychainGroup.group(from: "ABCDE12345.") == nil)
    }

    @Test func theTestBuildHasNoGroup() {
        // The test host is a simulator build, unsigned, and its Info.plist's value has no prefix: nothing may name a
        // group there, which is what the app and the extension did before #682.
        #expect(KeychainGroup.id == nil)
    }

    @Test func aListAndAWipeGoThroughBothAccessGroups() {
        // The first launch's wipe and Unpair must empty the shared group as well as the app's own (3.2, 3.6), and the
        // list that checks the wipe must reach both. A simulator build has no shared group to leave items in, so the
        // searches themselves are what is checked here: reaching one group and not the other fails this test.
        let shared = "ABCDE12345.group.dev.pi2.ios"
        let own = SystemKeychain.searches(shared: nil)
        #expect(!own.isEmpty)
        #expect(own.allSatisfy { $0.group == nil })

        let both = SystemKeychain.searches(shared: shared)
        #expect(both.count == own.count * 2)
        #expect(both.filter { $0.group == nil }.map { $0.itemClass as String } == own.map { $0.itemClass as String })
        #expect(both.filter { $0.group == shared }.map { $0.itemClass as String } == own.map { $0.itemClass as String })
    }
}
