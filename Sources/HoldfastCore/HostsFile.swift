// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import Foundation

/// Port of HostFileBlocker: adds/removes the `# BEGIN HOLDFAST BLOCK` section of /etc/hosts.
public struct HostsFileEditor {
    public let path: String

    public init(path: String = "/etc/hosts") {
        self.path = path
    }

    public static let defaultContents = """
    ##
    # Host Database
    #
    # localhost is used to configure the loopback interface
    # when the system is booting.  Do not change this entry.
    ##
    127.0.0.1\tlocalhost
    255.255.255.255\tbroadcasthost
    ::1             localhost
    fe80::1%lo0\tlocalhost


    """

    // MARK: Pure string transforms (unit-tested)

    public static func containsBlock(_ contents: String) -> Bool {
        contents.range(of: SC.hostsBegin) != nil
    }

    /// Removes the Holdfast section, plus the tidy newlines around it.
    /// If the footer is missing we delete everything below the header: a stuck block is worse than lost lines.
    public static func removingBlock(from contents: String) -> String {
        guard let start = contents.range(of: SC.hostsBegin) else { return contents }

        var lower = start.lowerBound
        if lower > contents.startIndex {
            let prev = contents.index(before: lower)
            if contents[prev].isNewline { lower = prev }
        }

        var upper = contents.endIndex
        if let end = contents.range(of: SC.hostsEnd, range: start.upperBound..<contents.endIndex) {
            upper = end.upperBound
            if upper < contents.endIndex, contents[upper].isNewline {
                upper = contents.index(after: upper)
            }
        }

        var result = contents
        result.removeSubrange(lower..<upper)
        return result
    }

    static func isSafeDomain(_ domain: String) -> Bool {
        !domain.isEmpty && !domain.unicodeScalars.contains { $0.properties.isWhitespace || $0.value < 0x20 || $0 == "#" }
    }

    static func rules(for domains: [String]) -> String {
        domains.filter(isSafeDomain).map { "0.0.0.0\t\($0)\n::\t\($0)\n" }.joined()
    }

    public static func blockSection(domains: [String]) -> String {
        "\n\(SC.hostsBegin)\n" + rules(for: domains) + "\(SC.hostsEnd)\n"
    }

    /// Inserts rules just before the footer of an existing block; nil if there is no block.
    public static func insertingIntoBlock(domains: [String], in contents: String) -> String? {
        guard let footer = contents.range(of: SC.hostsEnd) else { return nil }
        var result = contents
        result.insert(contentsOf: rules(for: domains), at: footer.lowerBound)
        return result
    }

    // MARK: File operations

    public func read() -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? Self.defaultContents
    }

    public func write(_ contents: String) throws {
        // /etc/hosts is a symlink on macOS; write through it rather than replacing the link.
        let resolved = PathUtil.canonical(path)
        try contents.write(toFile: resolved, atomically: true, encoding: .utf8)
    }

    public func containsBlock() -> Bool {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return Self.containsBlock(contents)
    }

    public var backupPath: String { path + ".bak" }

    @discardableResult
    public func createBackup() -> Bool {
        deleteBackup()
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            try? Self.defaultContents.write(toFile: path, atomically: true, encoding: .utf8)
        }
        guard fm.isReadableFile(atPath: path) else { return false }
        return (try? fm.copyItem(atPath: path, toPath: backupPath)) != nil
    }

    @discardableResult
    public func deleteBackup() -> Bool {
        (try? FileManager.default.removeItem(atPath: backupPath)) != nil
    }

    @discardableResult
    public func restoreBackup() -> Bool {
        let fm = FileManager.default
        guard fm.isReadableFile(atPath: backupPath) else { return false }
        let resolved = PathUtil.canonical(path)
        guard (try? fm.removeItem(atPath: resolved)) != nil else { return false }
        return (try? fm.moveItem(atPath: backupPath, toPath: resolved)) != nil
    }

    /// Strips any existing block, then writes a fresh one containing `domains`.
    public func installBlock(domains: [String]) throws {
        let cleaned = Self.removingBlock(from: read())
        try write(cleaned + Self.blockSection(domains: domains))
    }

    public func appendToBlock(domains: [String]) throws {
        guard let updated = Self.insertingIntoBlock(domains: domains, in: read()) else {
            throw SCError(.ioFailure, "The hosts file has no Holdfast block to extend.")
        }
        try write(updated)
    }

    /// Removes the block from disk and returns true if it's really gone afterwards.
    @discardableResult
    public func removeBlock() -> Bool {
        let current = read()
        if Self.containsBlock(current) {
            try? write(Self.removingBlock(from: current))
        }
        return !containsBlock()
    }
}
