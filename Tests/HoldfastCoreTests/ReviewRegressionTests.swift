// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import XCTest
@testable import HoldfastCore

/// Tests written during the pre-release review. Each one first failed against the code as it stood.
final class AppBlockingReviewTests: XCTestCase {
    var processes = FakeProcesses()

    // Finding 1: the daemon never validated app paths it was sent.
    func testMalformedAppPathsNeverMatchOtherProcesses() {
        let blocker = AppBlocker(lister: processes, signaler: processes, ownPID: 1)
        processes.processes = [
            RunningProcess(pid: 900, path: "/usr/bin/unrelated"),
            RunningProcess(pid: 901, path: "/Applications/Other.app/Contents/MacOS/Other"),
            RunningProcess(pid: 902, path: "/System/Library/CoreServices/WindowServer"),
        ]
        for bad in ["/", "", "/Applications", "/Applications/", "relative/Game.app", "/usr/bin", "/Applications/Game", "/.", "//", "/Applications/../"] {
            let acted = blocker.enforce(apps: [BlockedApp(bundleID: "", name: "x", path: bad)])
            XCTAssertTrue(acted.isEmpty, "path \(bad.debugDescription) must not match anything, but acted on \(acted)")
        }
        XCTAssertTrue(processes.terminated.isEmpty)
    }

    func testControllerRejectsABlockWhoseOnlyAppHasABogusPath() throws {
        let (paths, root) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock(date(2026, 11, 3, 10))
        let c = BlockController(paths: paths, runner: RecordingRunner(), resolver: FakeResolver(table: [:]), scraper: NoScraper(),
                                appBlocker: AppBlocker(lister: processes, signaler: processes, ownPID: 1), calendar: utc, clocks: clock)
        c.log = { _ in }
        let bogus = BlockedApp(bundleID: "", name: "everything", path: "/")
        XCTAssertThrowsError(try c.startBlock(BlockRequest(entries: [], isAllowlist: false, endDate: clock.now.addingTimeInterval(600), apps: [bogus])))
    }

    // Finding 2: copying or moving an app to another folder defeated path matching.
    func testBlockedAppIsFoundByBundleIdentifierEvenWhenCopiedElsewhere() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("holdfast-bid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        func makeApp(_ name: String, id: String?) throws -> String {
            let app = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            if let id {
                let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleExecutable": "x"]
                try (plist as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"))
            }
            return PathUtil.canonical(app.path) + "/Contents/MacOS/x"
        }
        let copied = try makeApp("Desktop Copy/Totally Different Name.app", id: "com.example.game")
        let other = try makeApp("Other.app", id: "com.example.other")
        let noPlist = try makeApp("NoPlist.app", id: nil)

        let blocked = BlockedApp(bundleID: "com.example.game", name: "Game", path: "/Applications/Game.app")
        let blocker = AppBlocker(lister: processes, signaler: processes, ownPID: 1)
        processes.processes = [RunningProcess(pid: 11, path: copied), RunningProcess(pid: 12, path: other), RunningProcess(pid: 13, path: noPlist)]
        XCTAssertEqual(blocker.enforce(apps: [blocked]), [11], "only the copy with the matching bundle id")
    }

    func testBundleIDMatchingIsSkippedWhenTheBlockedAppHasNoID() throws {
        let blocker = AppBlocker(lister: processes, signaler: processes, ownPID: 1)
        processes.processes = [RunningProcess(pid: 20, path: "/Applications/Elsewhere.app/Contents/MacOS/Elsewhere")]
        XCTAssertTrue(blocker.enforce(apps: [BlockedApp(bundleID: "", name: "A", path: "/Applications/A.app")]).isEmpty)
    }
}

final class SystemFilesReviewTests: XCTestCase {
    // Finding 4: root deleting caches through a user-controlled symlink.
    func testCacheClearingDoesNotFollowSymlinksOutOfAUsersHome() throws {
        let (paths, root) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let users = paths.usersDirectory

        let victimFile = "\(users)/bob/Library/Application Support/Firefox/Profiles/logins.json"
        try fm.createDirectory(atPath: (victimFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "precious".write(toFile: victimFile, atomically: true, encoding: .utf8)

        // alice (a standard user) plants: ~/Library/Caches/Firefox -> bob's Application Support/Firefox
        try fm.createDirectory(atPath: "\(users)/alice/Library/Caches", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: "\(users)/alice/Library/Caches/Firefox",
                                  withDestinationPath: "\(users)/bob/Library/Application Support/Firefox")

        // ...and a genuine cache that *should* be cleared.
        let realCache = "\(users)/alice/Library/Caches/com.apple.Safari"
        try fm.createDirectory(atPath: realCache, withIntermediateDirectories: true)
        try "x".write(toFile: realCache + "/f", atomically: true, encoding: .utf8)

        SystemMaintenance.clearBrowserCaches(paths: paths)

        XCTAssertTrue(fm.fileExists(atPath: victimFile), "root must not delete another user's data via a planted symlink")
        XCTAssertFalse(fm.fileExists(atPath: realCache), "ordinary caches are still cleared")
    }

    // Finding 5: loose suffix matching.
    func testSubdomainRulesOnlyApplyToTheDomainAndItsSubdomains() {
        XCTAssertFalse(CommonSubdomains.hosts(for: "notfacebook.com").contains("157.240.0.0/16"))
        XCTAssertFalse(CommonSubdomains.hosts(for: "mytwitter.com").contains("api.twitter.com"))
        XCTAssertFalse(CommonSubdomains.hosts(for: "xnetflix.com").contains("nflxext.com"))
        XCTAssertTrue(CommonSubdomains.hosts(for: "facebook.com").contains("157.240.0.0/16"))
        XCTAssertTrue(CommonSubdomains.hosts(for: "m.facebook.com").contains("157.240.0.0/16"))
        XCTAssertTrue(CommonSubdomains.hosts(for: "www.twitter.com").contains("api.twitter.com"))
    }

    // Finding 7: a corrupt state file was silently thrown away (and then overwritten).
    func testCorruptStateFileIsPreservedNotDestroyed() throws {
        let (paths, root) = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try "{ this is not json".write(toFile: paths.state, atomically: true, encoding: .utf8)

        let state = StateStore(path: paths.state).load()
        XCTAssertNil(state.activeBlock)

        let dir = (paths.state as NSString).deletingLastPathComponent
        let kept = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasPrefix("state.json.corrupt") }
        XCTAssertEqual(kept.count, 1, "the unreadable file must be kept for recovery")
        let backup = try XCTUnwrap(kept.first)
        XCTAssertEqual(try String(contentsOfFile: dir + "/" + backup, encoding: .utf8), "{ this is not json")

        _ = StateStore(path: paths.state).load()   // reading again (the app polls) must not pile up copies
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasPrefix("state.json.corrupt") }.count, 1)
    }
}

final class DaemonBehaviourReviewTests: XCTestCase {
    var paths: SystemPaths!
    var root: URL!
    var clock: Clock!
    var runner: RecordingRunner!

    override func setUpWithError() throws {
        (paths, root) = try makeSandbox()
        clock = Clock(date(2026, 11, 3, 10))
        runner = RecordingRunner()
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func controller() -> BlockController {
        let c = BlockController(paths: paths, runner: runner,
                                resolver: FakeResolver(table: ["site.test": ["10.0.0.7"], "www.site.test": ["10.0.0.8"]]),
                                scraper: NoScraper(),
                                appBlocker: AppBlocker(lister: FakeProcesses(), signaler: FakeProcesses(), ownPID: 1),
                                calendar: utc, clocks: clock)
        c.log = { _ in }
        return c
    }

    // Finding 6: one failed attempt used up the schedule's window.
    func testScheduleThatFailsToStartIsRetriedWithinItsWindow() throws {
        let c = controller()
        let schedule = Schedule(name: "Work", weekdays: [3], startHour: 9, startMinute: 0, durationMinutes: 480,
                                profile: Profile(name: "Work", entries: ["site.test"]))
        try c.saveSchedules([schedule])

        var pfFails = true
        runner.responder = { path, args in
            if path.hasSuffix("pfctl"), pfFails { return CommandResult(status: 1, output: "pfctl: syntax error") }
            return RecordingRunner.defaultResponder(path, args)
        }
        c.tick()
        XCTAssertNil(c.activeBlock, "first attempt fails")
        XCTAssertFalse(c.blockRulesFoundOnSystem, "and leaves nothing behind")

        pfFails = false
        clock.advance(5)
        c.tick()
        XCTAssertNil(c.activeBlock, "not hammering: waits before retrying")
        clock.advance(61)
        c.tick()
        XCTAssertNotNil(c.activeBlock, "retries and starts the block for the rest of the window")
    }

    func testScheduleStopsRetryingAfterAFewAttempts() throws {
        let c = controller()
        let schedule = Schedule(name: "Work", weekdays: [3], startHour: 9, startMinute: 0, durationMinutes: 480,
                                profile: Profile(name: "Work", entries: ["site.test"]))
        try c.saveSchedules([schedule])
        var attempts = 0
        runner.responder = { path, args in
            if path.hasSuffix("pfctl"), args.contains("-E") { attempts += 1; return CommandResult(status: 1) }
            return RecordingRunner.defaultResponder(path, args)
        }
        for _ in 0..<40 { c.tick(); clock.advance(61) }
        XCTAssertLessThanOrEqual(attempts, SchedulePolicy.maxStartAttempts)
        XCTAssertNil(c.activeBlock)
    }

    // Finding 3: the documented recovery command didn't work while the daemon was running.
    func testEmergencyClearStopsTheDaemonBeforeTouchingRules() throws {
        let c = controller()
        try c.startBlock(BlockRequest(entries: ["site.test"], isAllowlist: false, endDate: clock.now.addingTimeInterval(3600)))
        XCTAssertTrue(c.blockRulesFoundOnSystem)

        let recovery = EmergencyClear(paths: paths, runner: runner)
        XCTAssertTrue(recovery.run())

        let commands = runner.commands.map { $0.joined(separator: " ") }
        let stop = commands.firstIndex { $0.contains("launchctl") && $0.contains("bootout") && $0.contains(SC.serviceName) }
        let firstPf = commands.firstIndex { $0.contains("pfctl") && ($0.contains("-d") || $0.contains("-X")) }
        XCTAssertNotNil(stop, "must stop the daemon, or it would put the block straight back")
        XCTAssertNotNil(firstPf)
        if let stop, let firstPf { XCTAssertLessThan(stop, firstPf) }
        XCTAssertTrue(commands.last?.contains("bootstrap") ?? false, "and start it again afterwards so schedules keep working")

        XCTAssertFalse(c.blockRulesFoundOnSystem)
        XCTAssertNil(StateStore(path: paths.state).load().activeBlock)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.state + ".clock"))
    }

    func testEmergencyClearKeepsScheduleAndHistory() throws {
        let c = controller()
        let schedule = Schedule(name: "Keep me", weekdays: [1], startHour: 1, startMinute: 0, durationMinutes: 60,
                                profile: Profile(name: "P", entries: ["site.test"]))
        try c.saveSchedules([schedule])
        try c.startBlock(BlockRequest(entries: ["site.test"], isAllowlist: false, endDate: clock.now.addingTimeInterval(3600)))
        _ = EmergencyClear(paths: paths, runner: runner).run()
        XCTAssertEqual(StateStore(path: paths.state).load().schedules.map(\.name), ["Keep me"])
    }
}

/// Finding 8: the root daemon fetched web pages with no size limit.
final class ScraperReviewTests: XCTestCase {
    final class FloodProtocol: URLProtocol {
        nonisolated(unsafe) static var chunksDelivered = 0
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let chunk = Data(repeating: UInt8(ascii: "a"), count: 64 * 1024)
            for _ in 0..<2_000 {                      // 125 MB offered
                if isStopped { return }
                Self.chunksDelivered += 1
                client?.urlProtocol(self, didLoad: chunk)
                Thread.sleep(forTimeInterval: 0.002)      // a real server is limited by the client reading
            }
            client?.urlProtocolDidFinishLoading(self)
        }
        private var isStopped = false
        override func stopLoading() { isStopped = true }
    }

    func testResponseBodyIsCappedAndTheDownloadStopped() {
        FloodProtocol.chunksDelivered = 0
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FloodProtocol.self]
        let scraper = HTTPLinkScraper(configuration: config)
        let body = scraper.fetchBody(of: URL(string: "http://flood.test")!)
        XCTAssertLessThanOrEqual(body?.count ?? 0, HTTPLinkScraper.maxBodyBytes)
        XCTAssertLessThan(FloodProtocol.chunksDelivered, 400, "should stop reading soon after the cap, not take all 125 MB")
    }
}

/// Finding 9: the installer must not trust a user-writable source binary blindly.
final class InstallerHardeningReviewTests: XCTestCase {
    func testScriptRefusesSymlinksAndRechecksTheStagedCopy() {
        let script = HelperInstaller.installScript(sourceBinary: "/Applications/Holdfast.app/Contents/MacOS/holdfastd", expectedTeamID: nil)
        XCTAssertTrue(script.contains("[ -L"), "must refuse a symlinked source (it could point at a root-only file)")
        XCTAssertTrue(script.contains("[ ! -f"), "must require a regular file")
        XCTAssertTrue(script.contains("umask 077"), "the staged copy must not be world-readable while it is being checked")
        XCTAssertTrue(script.contains("Mach-O"), "unsigned builds are at least checked to be an executable")
    }

    func testSignedBuildsPinTheTeamIDOnTheStagedRootOwnedCopy() throws {
        let script = HelperInstaller.installScript(sourceBinary: "/x/holdfastd", expectedTeamID: "ABCDE12345")
        XCTAssertTrue(script.contains("ABCDE12345"))
        XCTAssertTrue(script.contains("codesign"))
        // The verification must happen on the staged (root-owned) file, before it's moved into place.
        let verify = script.range(of: "codesign")!.lowerBound
        let move = script.range(of: "/bin/mv -f")!.lowerBound
        XCTAssertLessThan(verify, move)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hardened-\(UUID().uuidString).sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(ProcessRunner().run("/bin/sh", ["-n", file.path]).status, 0)
    }
}

/// Runs the *real* generated install script with system paths redirected into a temp directory and the
/// root-only commands (chown, launchctl) stubbed, so its ordering, quoting and refusals are exercised.
final class InstallerScriptExecutionTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("holdfast-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    private func sandboxed(_ script: String) -> String {
        let t = tmp.path
        return script
            .replacingOccurrences(of: SC.helperPath, with: "\(t)/PHT/holdfastd")
            .replacingOccurrences(of: SC.launchDaemonPlistPath, with: "\(t)/LD/holdfastd.plist")
            .replacingOccurrences(of: SC.legacyHelperPath, with: "\(t)/PHT/legacy")
            .replacingOccurrences(of: SC.legacyLaunchDaemonPlistPath, with: "\(t)/LD/legacy.plist")
            .replacingOccurrences(of: SC.supportDirectory, with: "\(t)/support")
            .replacingOccurrences(of: "/Library/PrivilegedHelperTools", with: "\(t)/PHT")
            .replacingOccurrences(of: "/usr/sbin/chown root:wheel", with: "/usr/bin/true")
            .replacingOccurrences(of: "/bin/launchctl", with: "/usr/bin/true")
    }

    private func run(source: String, team: String? = nil) throws -> CommandResult {
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("LD"), withIntermediateDirectories: true)
        let script = sandboxed(HelperInstaller.installScript(sourceBinary: source, expectedTeamID: team))
        let file = tmp.appendingPathComponent("run.sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        return ProcessRunner().run("/bin/sh", [file.path])
    }

    private func realExecutable() throws -> String {
        let copy = tmp.appendingPathComponent("holdfastd-src").path
        try FileManager.default.copyItem(atPath: "/bin/ls", toPath: copy)
        return copy
    }

    func testInstallsAnExecutableWithTheRightPermissions() throws {
        let result = try run(source: try realExecutable())
        XCTAssertEqual(result.status, 0, result.output)
        let helper = tmp.appendingPathComponent("PHT/holdfastd").path
        XCTAssertTrue(FileManager.default.contentsEqual(atPath: helper, andPath: tmp.appendingPathComponent("holdfastd-src").path))
        let mode = try FileManager.default.attributesOfItem(atPath: helper)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o755)
        XCTAssertFalse(FileManager.default.fileExists(atPath: helper + ".new"), "staging file is moved, not left behind")
        let plist = try String(contentsOf: tmp.appendingPathComponent("LD/holdfastd.plist"), encoding: .utf8)
        XCTAssertTrue(plist.contains(SC.serviceName) && plist.contains("MachServices"))
    }

    func testRefusesASymlinkedSourceAndInstallsNothing() throws {
        let secret = tmp.appendingPathComponent("secret").path
        try "root-only data".write(toFile: secret, atomically: true, encoding: .utf8)
        let link = tmp.appendingPathComponent("holdfastd-link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: secret)

        let result = try run(source: link)
        XCTAssertEqual(result.status, 4, result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("PHT/holdfastd").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("PHT/holdfastd.new").path), "nothing copied at all")
    }

    func testRefusesAFileThatIsNotAnExecutableAndCleansUpTheStagedCopy() throws {
        let text = tmp.appendingPathComponent("not-a-binary").path
        try "just text".write(toFile: text, atomically: true, encoding: .utf8)
        let result = try run(source: text)
        XCTAssertEqual(result.status, 5, result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("PHT/holdfastd").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("PHT/holdfastd.new").path))
    }

    func testRefusesAMissingSource() throws {
        XCTAssertEqual(try run(source: tmp.appendingPathComponent("nope").path).status, 4)
    }

    func testPinnedTeamRejectsABinaryWithoutThatSignature() throws {
        // /bin/ls (copied) has no Team ID, so a build pinned to a team must refuse it.
        let result = try run(source: try realExecutable(), team: "ABCDE12345")
        XCTAssertEqual(result.status, 5, result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("PHT/holdfastd").path))
    }

    func testPathsWithSpacesAndQuotesSurviveTheShell() throws {
        let odd = tmp.appendingPathComponent("it's a \"weird\" dir").path
        try FileManager.default.createDirectory(atPath: odd, withIntermediateDirectories: true)
        let src = odd + "/holdfastd"
        try FileManager.default.copyItem(atPath: "/bin/ls", toPath: src)
        let result = try run(source: src)
        XCTAssertEqual(result.status, 0, result.output)
    }
}
