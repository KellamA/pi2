import Darwin
import Foundation

/// The rules that hold whatever the engine, the agent or a page says: pi²'s browser loads public http and https
/// addresses and nothing else. The engine checks the same thing before it asks; this is the check that every
/// navigation actually passes through, including redirects, links and what the person types in the address field.
public struct BrowserPolicy: Sendable {
    /// Origins, as "host:port", that the private-address rule lets through. Only the developer probe sets this, to
    /// reach the fixture server it runs on this Mac. The app never does.
    public var fixtureOrigins: Set<String> = []

    public init(fixtureOrigins: Set<String> = []) {
        self.fixtureOrigins = fixtureOrigins
    }

    public enum Verdict: Equatable, Sendable {
        case allowed
        case refused(String)
    }

    public static let notLocal = "pi²'s browser only opens public web pages. Addresses on this Mac or the local network are off limits."

    private func isFixture(_ url: URL) -> Bool {
        guard !fixtureOrigins.isEmpty, url.scheme?.lowercased() == "http", let host = url.host else { return false }
        return fixtureOrigins.contains("\(host.lowercased()):\(url.port ?? 80)")
    }

    /// Whether an address may be loaded, judged by how it is written. A name that passes still has to pass
    /// `resolvesToPrivate` before it is loaded.
    public func check(_ url: URL) -> Verdict {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else {
            return .refused("pi²'s browser only opens http and https addresses, not \(scheme.isEmpty ? "that kind" : scheme + ":") ones.")
        }
        guard let host = url.host, !host.isEmpty else { return .refused("That address has no site in it.") }
        if url.user != nil || url.password != nil { return .refused("Addresses that carry a user name or password are not opened.") }
        if isFixture(url) { return .allowed }
        return Self.isPrivate(host: host) ? .refused(Self.notLocal) : .allowed
    }

    /// Whether a name needs looking up before it is loaded: every name does, except an address written as numbers,
    /// which `check` has already judged, and the probe's own fixture server.
    func needsLookup(_ url: URL) -> Bool {
        guard let host = url.host, !isFixture(url) else { return false }
        return Self.ipv4(host) == nil && Self.ipv6(host) == nil
    }

    // MARK: - Addresses

    /// An IPv4 address in any of the spellings a browser accepts: 127.0.0.1, 127.1, 2130706433, 0x7f.0.0.1.
    static func ipv4(_ host: String) -> [UInt8]? {
        guard host.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == "x" || $0 == "X" }), host.first?.isNumber == true else { return nil }
        var address = in_addr()
        guard inet_aton(host, &address) != 0 else { return nil }
        return withUnsafeBytes(of: address.s_addr) { Array($0) }
    }

    static func ipv6(_ host: String) -> [UInt8]? {
        var text = host
        if text.hasPrefix("["), text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
        // A zone ("fe80::1%en0") names a network interface of this Mac; the address before it is what counts.
        if let zone = text.firstIndex(of: "%") { text = String(text[..<zone]) }
        guard text.contains(":") else { return nil }
        var address = in6_addr()
        guard inet_pton(AF_INET6, text, &address) == 1 else { return nil }
        return withUnsafeBytes(of: address) { Array($0) }
    }

    static func isPrivate(ipv4 b: [UInt8]) -> Bool {
        guard b.count == 4 else { return true }
        return b[0] == 0 // "this network"; 0.0.0.0 reaches the Mac itself
            || b[0] == 10
            || b[0] == 127
            || (b[0] == 100 && (64...127).contains(b[1])) // shared address space, where VPNs such as Tailscale live
            || (b[0] == 169 && b[1] == 254)
            || (b[0] == 172 && (16...31).contains(b[1]))
            || (b[0] == 192 && b[1] == 168)
            || b[0] >= 224 // multicast and reserved
    }

    static func isPrivate(ipv6 b: [UInt8]) -> Bool {
        guard b.count == 16 else { return true }
        if b[0..<15].allSatisfy({ $0 == 0 }), b[15] <= 1 { return true } // :: and ::1
        if b[0] & 0xFE == 0xFC { return true } // fc00::/7, private
        if b[0] == 0xFE, b[1] & 0xC0 == 0x80 { return true } // fe80::/10, link-local
        if b[0] == 0xFF { return true } // multicast
        // An IPv4 address carried inside an IPv6 one is judged as itself.
        let mapped = b[0..<10].allSatisfy { $0 == 0 } && b[10] == 0xFF && b[11] == 0xFF
        let compatible = b[0..<12].allSatisfy { $0 == 0 }
        let translated = b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xFF && b[3] == 0x9B && b[4..<12].allSatisfy { $0 == 0 }
        if mapped || compatible || translated { return isPrivate(ipv4: Array(b[12..<16])) }
        return false
    }

    /// Whether a host, as an address is written, is this Mac or somewhere on the local network: loopback, the private
    /// and link-local ranges, and names that only a local network can answer.
    public static func isPrivate(host raw: String) -> Bool {
        var host = raw.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        if host.isEmpty { return true }
        if let v6 = ipv6(host) { return isPrivate(ipv6: v6) }
        if host.hasPrefix("[") { return true } // brackets around something that is not an address
        if let v4 = ipv4(host) { return isPrivate(ipv4: v4) }
        if !host.contains(".") { return true } // "localhost", "router", "nas": names only the local network knows
        return [".localhost", ".local", ".internal", ".lan", ".home.arpa"].contains { host.hasSuffix($0) }
    }

    /// Whether any of the addresses a name stands for is private. A public-looking name can point anywhere, at
    /// 127.0.0.1 as easily as at a server, so the name is looked up before the page is. Blocks while it asks.
    public static func resolvesToPrivate(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        // A name that cannot be looked up cannot be loaded either; WebKit reports that itself.
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return false }
        defer { freeaddrinfo(first) }
        var next: UnsafeMutablePointer<addrinfo>? = first
        while let entry = next {
            if let address = entry.pointee.ai_addr {
                if entry.pointee.ai_family == AF_INET {
                    let bytes = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr.s_addr) { Array($0) } }
                    if isPrivate(ipv4: bytes) { return true }
                } else if entry.pointee.ai_family == AF_INET6 {
                    let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) } }
                    if isPrivate(ipv6: bytes) { return true }
                }
            }
            next = entry.pointee.ai_next
        }
        return false
    }

    // MARK: - What pages may load

    /// Rules for WebKit's content blocker, so that a public page cannot make the browser fetch from this Mac or the
    /// local network either (an image, a script, a `fetch`, a WebSocket). They match addresses as written; a public
    /// name that points at a private address is only caught when it is navigated to.
    func contentRules() -> String {
        // The pattern language has no "or", so each range is its own rule.
        let hosts = [
            "localhost", "[^/:]*\\.localhost", "[^/:]*\\.local", "[^/:]*\\.internal", "[^/:]*\\.lan",
            "0\\.[0-9.]+", "10\\.[0-9.]+", "127\\.[0-9.]+", "169\\.254\\.[0-9.]+", "192\\.168\\.[0-9.]+",
            "172\\.1[6-9]\\.[0-9.]+", "172\\.2[0-9]\\.[0-9.]+", "172\\.3[01]\\.[0-9.]+",
            "100\\.6[4-9]\\.[0-9.]+", "100\\.[7-9][0-9]\\.[0-9.]+", "100\\.1[01][0-9]\\.[0-9.]+", "100\\.12[0-7]\\.[0-9.]+",
            "\\[::1?\\]", "\\[f[cd][0-9a-f]*:[0-9a-f:.]*\\]", "\\[fe[89ab][0-9a-f]*:[0-9a-f:.]*\\]", "\\[::ffff:[0-9a-f:.]*\\]",
        ]
        var rules: [[String: Any]] = hosts.map { ["trigger": ["url-filter": "^[a-z]+://\($0)[:/]"], "action": ["type": "block"]] }
        for origin in fixtureOrigins.sorted() {
            let escaped = origin.replacingOccurrences(of: ".", with: "\\.")
            rules.append(["trigger": ["url-filter": "^http://\(escaped)/"], "action": ["type": "ignore-previous-rules"]])
        }
        let data = (try? JSONSerialization.data(withJSONObject: rules)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
