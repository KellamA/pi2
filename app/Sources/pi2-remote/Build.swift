import Foundation
import Security

/// Which kind of pi² Remote this is (docs/iphone.md 5.5, decision 24; docs/pi2-remote.md).
///
/// A **development** build (`app/build.sh` without `release`, and every throwaway copy made from one) runs in loopback
/// mode only: it listens on 127.0.0.1 alone, advertises nothing on Bonjour, keeps its keys in a file in its own data
/// folder, and never calls the Keychain or the Secure Enclave. A **release** build reads no argument, variable or file
/// that chooses its relay, socket, mode or keys; it keeps its keys in the Secure Enclave and the Keychain, listens on
/// the Mac's addresses and advertises on Bonjour.
///
/// Decided twice, so that neither alone can give a release build the development paths: the development paths are
/// compiled only under `PI2_DEVELOPMENT` (Package.swift defines it for a debug build; `build.sh optimised` passes it),
/// and the Keychain, Secure Enclave and Bonjour calls only without it; and a build compiled for development that is
/// signed with a Developer ID (Apple's anchor) is neither, and stops at start.
package enum BuildKind: Sendable, Equatable, CustomStringConvertible {
	case development
	case release

	/// Whether the development paths are compiled in.
	package static let compiledForDevelopment: Bool = {
		#if PI2_DEVELOPMENT
		return true
		#else
		return false
		#endif
	}()

	/// This process's kind, or why it is neither.
	package static func current() -> Result<BuildKind, Refused> {
		guard compiledForDevelopment else { return .success(.release) }
		// Anything that cannot be told is taken as signed: a development build that cannot read its own signature stops.
		if signedWithDeveloperID() != false {
			return .failure(Refused("this development build is signed with a Developer ID, or its signature could not be read; a development build of pi² Remote runs only signed ad hoc"))
		}
		return .success(.development)
	}

	/// Whether this process's own code satisfies Apple's anchor (a Developer ID, or Apple's own), or nil if it cannot
	/// be checked. An ad hoc signature, which every development build has, does not.
	static func signedWithDeveloperID() -> Bool? {
		var code: SecCode?
		guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
		var requirement: SecRequirement?
		guard SecRequirementCreateWithString("anchor apple generic" as CFString, [], &requirement) == errSecSuccess, let requirement else { return nil }
		switch SecCodeCheckValidity(code, [], requirement) {
		case errSecSuccess: return true
		case errSecCSReqFailed, errSecCSUnsigned: return false
		default: return nil
		}
	}

	package var description: String { self == .development ? "development" : "release" }
}

/// Why pi² Remote will not run, in words for its log and its standard error. Never holds a key or a secret.
package struct Refused: Error, CustomStringConvertible, Equatable {
	package let description: String
	package init(_ description: String) { self.description = description }
}
