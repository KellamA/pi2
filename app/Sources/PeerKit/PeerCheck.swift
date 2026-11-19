import Darwin
import Foundation
import Security

/// Whether the process at the other end of a connection to the engine's socket is the pi² app (#504).
///
/// Every command an agent runs is a process of the same person as the app, so it can connect to the engine's socket
/// as the app does. What it cannot do is be the app: macOS records, for each connection to a Unix socket, the audit
/// token of the process that connected, and from that token Security gives that process's code, which is checked here
/// against the designated requirement of the app bundle the engine belongs to. For a release that is pi²'s bundle id
/// and Developer ID team; for an ad hoc signed development build or test copy, the cdhash of its own executable.
///
/// The engine cannot ask a socket any of this from Node, so it starts `pi2-peer` with the connection as its file
/// descriptor 3. See "Who may answer for the person" in docs/architecture.md.
public enum PeerCheck {
    public struct Verdict: Sendable, Equatable {
        /// Whether the process at the other end is the app: it satisfies the app's designated requirement.
        public let app: Bool
        /// The process at the other end, when the socket could say.
        public let pid: Int32?
        /// Why, in words for engine.log and app.log.
        public let why: String
    }

    /// Checks the process that connected on `socket` against the code at `app`, an app bundle or an executable.
    /// Anything that cannot be checked is "not the app": nothing here ever says yes for want of an answer.
    public static func verdict(socket: Int32, app: String) -> Verdict {
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0 else {
            let reason = String(cString: strerror(errno))
            return Verdict(app: false, pid: nil, why: "the connection could not say which process is at its other end (\(reason))")
        }
        // The process id is the sixth word of the token (audit_token_to_pid in libbsm, which is not linked here).
        let pid = Int32(bitPattern: token.val.5)

        var staticApp: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(URL(fileURLWithPath: app) as CFURL, [], &staticApp)
        guard status == errSecSuccess, let staticApp else {
            return Verdict(app: false, pid: pid, why: "the app at \(app) could not be read (\(message(status)))")
        }
        var requirement: SecRequirement?
        status = SecCodeCopyDesignatedRequirement(staticApp, [], &requirement)
        guard status == errSecSuccess, let requirement else {
            return Verdict(app: false, pid: pid, why: "the app at \(app) has no requirement to check against (\(message(status)))")
        }

        // The token, not the process id: it also names the process's version, so a process that ended and whose id
        // was given to another is not taken for it.
        let attributes = [kSecGuestAttributeAudit: withUnsafeBytes(of: &token) { Data($0) }] as CFDictionary
        var peer: SecCode?
        status = SecCodeCopyGuestWithAttributes(nil, attributes, [], &peer)
        guard status == errSecSuccess, let peer else {
            return Verdict(app: false, pid: pid, why: "process \(pid) could not be found; it may have ended (\(message(status)))")
        }
        let name = "process \(pid)\(identifier(of: peer).map { " (\($0))" } ?? "")"
        status = SecCodeCheckValidity(peer, [], requirement)
        switch status {
        case errSecSuccess:
            return Verdict(app: true, pid: pid, why: "\(name) is the app at \(app)")
        case errSecCSReqFailed:
            return Verdict(app: false, pid: pid, why: "\(name) is not the app at \(app)")
        default:
            return Verdict(app: false, pid: pid, why: "\(name) could not be checked against the app at \(app) (\(message(status)))")
        }
    }

    /// The verdict as the one line of JSON `pi2-peer` prints for the engine.
    public static func json(_ verdict: Verdict) -> String {
        var object: [String: Any] = ["app": verdict.app, "why": verdict.why]
        if let pid = verdict.pid { object["pid"] = Int(pid) }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data(#"{"app":false,"why":"no answer"}"#.utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func identifier(of code: SecCode) -> String? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess else { return nil }
        return (information as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String
    }

    private static func message(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "status \(status)"
    }
}
