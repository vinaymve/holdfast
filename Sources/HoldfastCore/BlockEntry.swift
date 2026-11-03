// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import Foundation
import Darwin

/// One line of a blocklist: `host`, `host:port`, `ip/mask`, `*:port`, etc.
/// Port of SCBlockEntry, plus input hardening: entries end up in /etc/hosts and a pf ruleset,
/// so anything that could smuggle in extra lines or tokens is rejected.
public struct BlockEntry: Hashable, Codable, CustomStringConvertible {
    public let hostname: String
    public let port: Int
    public let maskLen: Int

    public init(hostname: String, port: Int = 0, maskLen: Int = 0) {
        self.hostname = hostname
        self.port = port
        self.maskLen = maskLen
    }

    public var description: String { "[Entry: hostname = \(hostname), port = \(port), maskLen = \(maskLen)]" }

    public var isWildcard: Bool { hostname == "*" }
    public var isIPv4: Bool { Self.isIPv4(hostname) }
    public var isIPv6: Bool { Self.isIPv6(hostname) }
    public var isIP: Bool { isIPv4 || isIPv6 }
    /// A real domain name (not an IP, not `*`).
    public var isDomain: Bool { !isIP && !isWildcard }

    public static func isIPv4(_ s: String) -> Bool {
        var addr = in_addr()
        return inet_pton(AF_INET, s, &addr) == 1
    }

    public static func isIPv6(_ s: String) -> Bool {
        var addr = in6_addr()
        return inet_pton(AF_INET6, s, &addr) == 1
    }

    /// Returns nil when the text contains nothing valid to block.
    public static func parse(_ raw: String) -> BlockEntry? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }

        let lower = s.lowercased()
        for scheme in ["https://", "http://"] where lower.hasPrefix(scheme) {
            s = String(s.dropFirst(scheme.count))
            break
        }

        // Drop URL paths ("example.com/page") but keep CIDR masks ("10.0.0.0/8").
        if let slash = s.firstIndex(of: "/") {
            let after = s[s.index(after: slash)...]
            if after.isEmpty || !(after.first!.isNumber) {
                s = String(s[..<slash])
            }
        }

        var hostPart = s
        var tail: String?
        if let slash = s.firstIndex(of: "/") {
            hostPart = String(s[..<slash])
            tail = String(s[s.index(after: slash)...])
        }

        var host = hostPart
        var port = 0
        var mask = 0

        if hostPart.hasPrefix("[") {
            guard let close = hostPart.firstIndex(of: "]") else { return nil }
            host = String(hostPart[hostPart.index(after: hostPart.startIndex)..<close])
            let rest = hostPart[hostPart.index(after: close)...]
            if rest.hasPrefix(":") {
                guard let p = Int(rest.dropFirst()) else { return nil }
                port = p
            } else if !rest.isEmpty {
                return nil
            }
        } else if hostPart.filter({ $0 == ":" }).count == 1 {
            let comps = hostPart.split(separator: ":", omittingEmptySubsequences: false)
            host = String(comps[0])
            port = Int(comps[1]) ?? 0
        }

        if let tail {
            let comps = tail.split(separator: ":", omittingEmptySubsequences: false)
            mask = Int(comps.first ?? "") ?? 0
            if comps.count > 1, port == 0 { port = Int(comps[1]) ?? 0 }
        }

        host = host.lowercased()
        while host.hasSuffix(".") && host.count > 1 { host.removeLast() }
        if host.isEmpty { host = "*" }

        // We won't block "everywhere" without a port: too easy to do by accident. Use an allowlist instead.
        if host == "*" && port == 0 { return nil }
        guard isValidHostname(host) else { return nil }
        guard (0...65_535).contains(port) else { return nil }

        let maxMask = isIPv6(host) ? 128 : 32
        guard (0...maxMask).contains(mask) else { return nil }

        return BlockEntry(hostname: host, port: port, maskLen: mask)
    }

    static func isValidHostname(_ host: String) -> Bool {
        if host == "*" { return true }
        if isIPv4(host) || isIPv6(host) { return true }
        guard !host.isEmpty, host.count <= 253, !host.contains("..") else { return false }
        return host.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x61 && scalar.value <= 0x7A)   // a-z
                || (scalar.value >= 0x30 && scalar.value <= 0x39) // 0-9
                || scalar == "-" || scalar == "." || scalar == "_" || scalar == "*"
        }
    }
}
