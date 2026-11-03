// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import XCTest
@testable import HoldfastCore

struct FakeResolver: DomainResolving {
    var table: [String: [String]]
    func addresses(for host: String) -> [String] { table[host] ?? [] }
}

struct FakeScraper: LinkScraping {
    var table: [String: Set<String>] = [:]
    func relatedHosts(for host: String) -> Set<String> { table[host] ?? [] }
}

func makeSandbox() throws -> (SystemPaths, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sc-test-\(UUID().uuidString)")
    return (try SystemPaths.sandbox(root: root.path), root)
}

final class HostsFileTests: XCTestCase {
    private let base = HostsFileEditor.defaultContents

    func testInstallAndRemoveRestoresOriginalExactly() throws {
        let (paths, root) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let editor = HostsFileEditor(path: paths.hosts)
        let original = editor.read()

        try editor.installBlock(domains: ["a.com", "b.com"])
        let blocked = editor.read()
        XCTAssertTrue(blocked.contains("0.0.0.0\ta.com\n::\ta.com\n"))
        XCTAssertTrue(blocked.contains("0.0.0.0\tb.com"))
        XCTAssertTrue(editor.containsBlock())

        XCTAssertTrue(editor.removeBlock())
        XCTAssertEqual(editor.read(), original)
    }

    func testReinstallDoesNotStackBlocks() throws {
        let (paths, root) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let editor = HostsFileEditor(path: paths.hosts)
        try editor.installBlock(domains: ["a.com"])
        try editor.installBlock(domains: ["b.com"])
        let contents = editor.read()
        XCTAssertEqual(contents.components(separatedBy: SC.hostsBegin).count - 1, 1)
        XCTAssertFalse(contents.contains("a.com"))
        XCTAssertTrue(contents.contains("b.com"))
    }

    func testRemovalWithMissingFooterDropsEverythingBelowHeader() {
        let broken = base + "\(SC.hostsBegin)\n0.0.0.0\tx.com\n"
        let cleaned = HostsFileEditor.removingBlock(from: broken)
        XCTAssertFalse(cleaned.contains("x.com"))
        XCTAssertFalse(HostsFileEditor.containsBlock(cleaned))
        XCTAssertTrue(cleaned.contains("localhost"))
    }

    func testRemovalKeepsLinesAfterFooter() {
        let text = base + HostsFileEditor.blockSection(domains: ["x.com"]) + "10.0.0.5\tmyserver\n"
        let cleaned = HostsFileEditor.removingBlock(from: text)
        XCTAssertTrue(cleaned.contains("10.0.0.5\tmyserver"))
        XCTAssertFalse(cleaned.contains("x.com"))
    }

    func testAppendInsertsBeforeFooter() throws {
        let text = base + HostsFileEditor.blockSection(domains: ["a.com"])
        let updated = try XCTUnwrap(HostsFileEditor.insertingIntoBlock(domains: ["b.com"], in: text))
        let bRange = try XCTUnwrap(updated.range(of: "b.com"))
        let footer = try XCTUnwrap(updated.range(of: SC.hostsEnd))
        XCTAssertTrue(bRange.upperBound <= footer.lowerBound)
        XCTAssertNil(HostsFileEditor.insertingIntoBlock(domains: ["b.com"], in: base))
    }

    func testUnsafeDomainsAreNeverWritten() {
        let section = HostsFileEditor.blockSection(domains: ["ok.com", "bad.com\n1.1.1.1 bank.com", "x y.com", "h#.com"])
        XCTAssertTrue(section.contains("ok.com"))
        XCTAssertFalse(section.contains("bank.com"))
        XCTAssertFalse(section.contains("x y.com"))
        XCTAssertFalse(section.contains("h#.com"))
    }
}

final class PacketFilterTests: XCTestCase {
    func testBlocklistRules() {
        let rules = PacketFilter.ruleStrings(isAllowlist: false, ip: "1.2.3.4", port: 443, maskLen: 24)
        XCTAssertEqual(rules, ["block return out proto tcp from any to 1.2.3.4/24 port 443\n",
                               "block return out proto udp from any to 1.2.3.4/24 port 443\n"])
        let wildcard = PacketFilter.ruleStrings(isAllowlist: false, ip: nil, port: 80, maskLen: 0)
        XCTAssertEqual(wildcard[0], "block return out proto tcp from any to any port 80\n")
    }

    func testAllowlistBlocksEverythingFirstThenPasses() throws {
        let (paths, root) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let pf = PacketFilter(isAllowlist: true, allowLocalNetworks: true, paths: paths, runner: RecordingRunner())
        pf.addRule(ip: "9.9.9.9", port: 0, maskLen: 0)
        let text = pf.configText()
        let blockAll = try XCTUnwrap(text.range(of: "block return out proto tcp from any to any\n"))
        let pass = try XCTUnwrap(text.range(of: "pass out proto tcp from any to 9.9.9.9\n"))
        XCTAssertTrue(blockAll.lowerBound < pass.lowerBound, "pf is last-match-wins, so pass rules must follow the block-all")
        XCTAssertTrue(text.contains("pass out proto udp from any to any port 53"))      // DNS keeps working
        XCTAssertTrue(text.contains("pass out proto tcp from any to 192.168.0.0/16"))   // local networks allowed
    }

    func testAllowlistCanExcludeLocalNetworks() throws {
        let (paths, root) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let pf = PacketFilter(isAllowlist: true, allowLocalNetworks: false, paths: paths, runner: RecordingRunner())
        XCTAssertFalse(pf.configText().contains("192.168.0.0/16"))
    }

    func testLinkLocalIPv6IsSkipped() throws {
        let (paths, root) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let pf = PacketFilter(isAllowlist: false, paths: paths, runner: RecordingRunner())
        pf.addRule(ip: "fe80::1%en0", port: 0, maskLen: 0)
        XCTAssertTrue(pf.currentRules.isEmpty)
    }
}

final class BlockEngineTests: XCTestCase {
    private func engine(_ config: BlockEngine.Config, paths: SystemPaths, runner: RecordingRunner,
                        dns: [String: [String]] = [:], scraper: LinkScraping = NoScraper()) -> BlockEngine {
        BlockEngine(config: config, paths: paths, runner: runner, resolver: FakeResolver(table: dns), scraper: scraper)
    }

    func testBlocklistWritesHostsAndPfAndClearsCleanly() throws {
        let (paths, root) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = RecordingRunner()
        let hostsBefore = try String(contentsOfFile: paths.hosts, encoding: .utf8)
        let pfConfBefore = try String(contentsOfFile: paths.pfConf, encoding: .utf8)

        let e = engine(.init(isAllowlist: false), paths: paths, runner: runner,
                       dns: ["example.com": ["93.184.216.34", "2606:2800:220:1::1"], "www.example.com": ["93.184.216.35"]])
        e.prepareToAddBlock()
        e.add(["example.com", "10.1.2.3/24", "mail.test:993"])
        try e.finalizeBlock()

        let hosts = try String(contentsOfFile: paths.hosts, encoding: .utf8)
        XCTAssertTrue(hosts.contains("0.0.0.0\texample.com"))
        XCTAssertTrue(hosts.contains("0.0.0.0\twww.example.com"), "common subdomain should be added")
        XCTAssertFalse(hosts.contains("mail.test"), "port-specific entries are pf-only")
        XCTAssertFalse(hosts.contains("10.1.2.3"), "IPs are pf-only")

        let anchor = try String(contentsOfFile: paths.pfAnchor, encoding: .utf8)
        XCTAssertTrue(anchor.contains("block return out proto tcp from any to 93.184.216.34\n"))
        XCTAssertTrue(anchor.contains("to 2606:2800:220:1::1\n"))
        XCTAssertTrue(anchor.contains("to 93.184.216.35\n"))
        XCTAssertTrue(anchor.contains("block return out proto tcp from any to 10.1.2.3/24\n"))
        XCTAssertFalse(anchor.contains("block return out proto tcp from any to any\n"), "blocklists must not block everything")

        let pfConf = try String(contentsOfFile: paths.pfConf, encoding: .utf8)
        XCTAssertTrue(pfConf.contains("anchor \"\(SC.pfAnchorName)\""))
        XCTAssertTrue(runner.commands.contains { $0.contains("-E") && $0.contains("-f") }, "pf must be enabled")
        XCTAssertEqual(try String(contentsOfFile: paths.pfToken, encoding: .utf8), "424242")
        XCTAssertTrue(e.blockIsActive)

        XCTAssertTrue(e.clearBlock())
        XCTAssertFalse(e.blockIsActive)
        XCTAssertEqual(try String(contentsOfFile: paths.hosts, encoding: .utf8), hostsBefore)
        XCTAssertEqual(try String(contentsOfFile: paths.pfConf, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                       pfConfBefore.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(try String(contentsOfFile: paths.pfAnchor, encoding: .utf8), "")
        XCTAssertTrue(runner.commands.contains { $0.contains("-X") && $0.contains("424242") }, "should release pf with the stored token")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.hosts + ".bak"))
    }

    func testAllowlistLeavesHostsAloneAndBlocksEverythingElse() throws {
        let (paths, root) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let hostsBefore = try String(contentsOfFile: paths.hosts, encoding: .utf8)
        let e = engine(.init(isAllowlist: true), paths: paths, runner: RecordingRunner(),
                       dns: ["wiki.test": ["10.9.9.9"]],
                       scraper: FakeScraper(table: ["wiki.test": ["cdn.wiki.test"]]))
        e.prepareToAddBlock()
        e.add(["wiki.test"])
        try e.finalizeBlock()

        XCTAssertEqual(try String(contentsOfFile: paths.hosts, encoding: .utf8), hostsBefore)
        let anchor = try String(contentsOfFile: paths.pfAnchor, encoding: .utf8)
        XCTAssertTrue(anchor.contains("block return out proto tcp from any to any\n"))
        XCTAssertTrue(anchor.contains("pass out proto tcp from any to 10.9.9.9\n"))
        XCTAssertTrue(e.clearBlock())
    }

    func testGoogleDomainsUseHostsOnlyInBlocklistsAndRangesInAllowlists() throws {
        XCTAssertTrue(GoogleRanges.isGoogleDomain("www.youtube.com"))
        XCTAssertTrue(GoogleRanges.isGoogleDomain("google.co.uk"))
        XCTAssertFalse(GoogleRanges.isGoogleDomain("notgoogle.example.com"))
        XCTAssertFalse(GoogleRanges.cidrs.contains { $0.hasSuffix("/240") }, "original had a /240 typo")
        XCTAssertEqual(GoogleRanges.cidrs.count, Set(GoogleRanges.cidrs).count, "no duplicates")

        let (paths, root) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let blocklist = engine(.init(isAllowlist: false), paths: paths, runner: RecordingRunner(), dns: ["youtube.com": ["142.250.1.1"]])
        blocklist.prepareToAddBlock()
        blocklist.add(["youtube.com"])
        try blocklist.finalizeBlock()
        XCTAssertFalse(try String(contentsOfFile: paths.pfAnchor, encoding: .utf8).contains("142.250.1.1"))
        XCTAssertTrue(try String(contentsOfFile: paths.hosts, encoding: .utf8).contains("youtube.com"))
        XCTAssertTrue(blocklist.clearBlock())

        let allow = engine(.init(isAllowlist: true), paths: paths, runner: RecordingRunner())
        allow.prepareToAddBlock()
        allow.add(["youtube.com"])
        try allow.finalizeBlock()
        XCTAssertTrue(try String(contentsOfFile: paths.pfAnchor, encoding: .utf8).contains("pass out proto tcp from any to 142.250.0.0/15\n"))
        XCTAssertTrue(allow.clearBlock())
    }

    func testAppendingToRunningBlocklist() throws {
        let (paths, root) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = RecordingRunner()
        let dns = ["a.test": ["10.0.0.1"], "b.test": ["10.0.0.2"], "www.a.test": [], "www.b.test": []]

        let first = engine(.init(isAllowlist: false), paths: paths, runner: runner, dns: dns)
        first.prepareToAddBlock()
        first.add(["a.test"])
        try first.finalizeBlock()

        let second = engine(.init(isAllowlist: false), paths: paths, runner: runner, dns: dns)
        try second.beginAppending()
        second.add(["b.test"])
        try second.finishAppending()

        let hosts = try String(contentsOfFile: paths.hosts, encoding: .utf8)
        XCTAssertTrue(hosts.contains("a.test") && hosts.contains("b.test"))
        XCTAssertEqual(hosts.components(separatedBy: SC.hostsBegin).count - 1, 1)
        let anchor = try String(contentsOfFile: paths.pfAnchor, encoding: .utf8)
        XCTAssertTrue(anchor.contains("to 10.0.0.1\n") && anchor.contains("to 10.0.0.2\n"))
        XCTAssertTrue(second.clearBlock())
    }

    func testAllowlistCannotBeAppendedTo() throws {
        let (paths, root) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let e = engine(.init(isAllowlist: true), paths: paths, runner: RecordingRunner())
        XCTAssertThrowsError(try e.beginAppending())
    }

    func testClearRestoresBackupIfHostsCleanupFails() throws {
        let (paths, root) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let e = engine(.init(isAllowlist: false), paths: paths, runner: RecordingRunner())
        e.prepareToAddBlock()
        e.add(["x.test"])
        try e.finalizeBlock()
        XCTAssertTrue(e.blockIsActive)
        XCTAssertTrue(e.clearBlock())
    }

    func testCommonSubdomains() {
        XCTAssertTrue(CommonSubdomains.hosts(for: "reddit.com").contains("www.reddit.com"))
        XCTAssertTrue(CommonSubdomains.hosts(for: "www.reddit.com").contains("reddit.com"))
        XCTAssertTrue(CommonSubdomains.hosts(for: "facebook.com").contains("157.240.0.0/16"))
        XCTAssertTrue(CommonSubdomains.hosts(for: "twitter.com").contains("api.twitter.com"))
        XCTAssertTrue(CommonSubdomains.hosts(for: "netflix.com").contains("nflxext.com"))
    }
}
