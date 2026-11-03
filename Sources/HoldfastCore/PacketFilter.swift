// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import Foundation

/// Port of PacketFilter: builds a pf anchor file and loads it with pfctl.
public final class PacketFilter {
    public let isAllowlist: Bool
    public let allowLocalNetworks: Bool
    private let paths: SystemPaths
    private let runner: CommandRunner
    private let lock = NSLock()
    private var rules: [String] = []
    private var appending = false

    public init(isAllowlist: Bool, allowLocalNetworks: Bool = true, paths: SystemPaths, runner: CommandRunner) {
        self.isAllowlist = isAllowlist
        self.allowLocalNetworks = allowLocalNetworks
        self.paths = paths
        self.runner = runner
    }

    // MARK: Rule generation

    static func ruleStrings(isAllowlist: Bool, ip: String?, port: Int, maskLen: Int) -> [String] {
        var target = "from any to " + (ip ?? "any")
        if maskLen > 0 { target += "/\(maskLen)" }
        if port > 0 { target += " port \(port)" }
        let action = isAllowlist ? "pass out" : "block return out"
        return ["\(action) proto tcp \(target)\n", "\(action) proto udp \(target)\n"]
    }

    public func addRule(ip: String?, port: Int, maskLen: Int) {
        // Link-local IPv6 results ("fe80::1%en0") aren't valid in pf rules.
        if let ip, ip.contains("%") { return }
        let new = Self.ruleStrings(isAllowlist: isAllowlist, ip: ip, port: port, maskLen: maskLen)
        lock.lock()
        rules.append(contentsOf: new)
        lock.unlock()
    }

    var currentRules: [String] {
        lock.lock(); defer { lock.unlock() }
        return rules
    }

    static let header = """
    # Options
    set block-policy drop
    set fingerprints "/etc/pf.os"
    set ruleset-optimization basic
    set skip on lo0

    #
    # dev.holdfast ruleset for Holdfast blocks
    #

    """

    static let localNetworkRanges = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "fe80::/10", "fc00::/7"]

    public func configText() -> String {
        var text = Self.header
        if isAllowlist {
            text += "block return out proto tcp from any to any\n"
            text += "block return out proto udp from any to any\n\n"
        }
        text += currentRules.joined()
        if isAllowlist {
            for port in [53, 123, 67, 68, 5353] {
                text += "pass out proto udp from any to any port \(port)\n"
            }
            for port in [53, 67, 68, 5353] {
                text += "pass out proto tcp from any to any port \(port)\n"
            }
            if allowLocalNetworks {
                for range in Self.localNetworkRanges {
                    text += "pass out proto tcp from any to \(range)\n"
                    text += "pass out proto udp from any to \(range)\n"
                }
            }
        }
        return text
    }

    // MARK: Lifecycle

    public static func blockFound(paths: SystemPaths) -> Bool {
        guard let conf = try? String(contentsOfFile: paths.pfConf, encoding: .utf8) else { return false }
        return conf.contains("anchor \"\(SC.pfAnchorName)\"")
    }

    public var containsBlock: Bool {
        guard let conf = try? String(contentsOfFile: paths.pfConf, encoding: .utf8) else { return false }
        return conf.contains(SC.pfAnchorName)
    }

    /// Writes the anchor, hooks it into pf.conf, and enables pf.
    public func startBlock() throws {
        try addAnchorToMainConfig()
        try configText().write(toFile: paths.pfAnchor, atomically: true, encoding: .utf8)

        let result = runner.run(paths.pfctl, ["-E", "-f", paths.pfConf, "-F", "states"])
        for line in result.output.components(separatedBy: "\n") where line.hasPrefix("Token : ") {
            try? String(line.dropFirst("Token : ".count)).write(toFile: paths.pfToken, atomically: true, encoding: .utf8)
            break
        }
        if result.status != 0 {
            throw SCError(.ioFailure, "pfctl exited with status \(result.status): \(result.output)")
        }
    }

    // Append mode is for adding sites to a running blocklist: new rules go on the end of the anchor file.
    public func beginAppending() {
        appending = true
    }

    public func finishAppending() throws {
        defer { appending = false }
        guard !isAllowlist else { return }
        let new = currentRules.joined()
        guard !new.isEmpty else { return }
        guard let handle = FileHandle(forWritingAtPath: paths.pfAnchor) else {
            throw SCError(.ioFailure, "Couldn't open the pf anchor file for appending.")
        }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(new.utf8))
        refreshRules()
    }

    @discardableResult
    public func refreshRules() -> Int32 {
        runner.run(paths.pfctl, ["-f", paths.pfConf, "-F", "states"]).status
    }

    /// True if `pfctl -s info` says pf is on. Sandbox mode has no real pf, so it always reports true.
    public func isEnabled() -> Bool {
        if paths.isSandbox { return true }
        return runner.run(paths.pfctl, ["-s", "info"]).output.contains("Status: Enabled")
    }

    public func reenable() {
        runner.run(paths.pfctl, ["-E"])
    }

    @discardableResult
    public func stopBlock(force: Bool) -> Int32 {
        let token = (try? String(contentsOfFile: paths.pfToken, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        try? "".write(toFile: paths.pfAnchor, atomically: true, encoding: .utf8)

        if let conf = try? String(contentsOfFile: paths.pfConf, encoding: .utf8) {
            let kept = conf.components(separatedBy: "\n").filter { !$0.contains(SC.pfAnchorName) }
            let rewritten = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            try? rewritten.write(toFile: paths.pfConf, atomically: true, encoding: .utf8)
        }

        let args = (!token.isEmpty && !force) ? ["-X", token, "-f", paths.pfConf] : ["-d", "-f", paths.pfConf]
        let status = runner.run(paths.pfctl, args).status
        try? FileManager.default.removeItem(atPath: paths.pfToken)
        return status
    }

    private func addAnchorToMainConfig() throws {
        var conf = (try? String(contentsOfFile: paths.pfConf, encoding: .utf8)) ?? ""
        guard !conf.contains(paths.pfAnchor) else { return }
        conf += "\nanchor \"\(SC.pfAnchorName)\"\nload anchor \"\(SC.pfAnchorName)\" from \"\(paths.pfAnchor)\"\n"
        try conf.write(toFile: paths.pfConf, atomically: true, encoding: .utf8)
    }
}
