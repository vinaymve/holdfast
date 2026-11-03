// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import XCTest
@testable import HoldfastCore

/// Models the three clocks the daemon sees. `advance`/assigning `now` are real time passing (wall and monotonic
/// move together, like sleep or a long wait); `setWall` is someone changing the system date; `reboot` resets
/// the monotonic clock and boot session.
final class Clock: SystemClocks {
    private(set) var wallTime: Date
    private var mono: TimeInterval = 10_000
    private var boot = "boot-1"

    init(_ now: Date) { wallTime = now }

    var now: Date {
        get { wallTime }
        set {
            mono += newValue.timeIntervalSince(wallTime)
            wallTime = newValue
        }
    }

    func advance(_ seconds: TimeInterval) { now = wallTime.addingTimeInterval(seconds) }
    func setWall(_ date: Date) { wallTime = date }
    func setWall(by seconds: TimeInterval) { wallTime = wallTime.addingTimeInterval(seconds) }

    /// Powered off for `downtime` real seconds; the wall clock additionally reads `wallError` seconds off
    /// when it comes back (a changed date).
    func reboot(downtime: TimeInterval, wallError: TimeInterval = 0) {
        boot = "boot-\(UUID().uuidString)"
        mono = 3
        wallTime = wallTime.addingTimeInterval(downtime + wallError)
    }

    func wall() -> Date { wallTime }
    func monotonic() -> TimeInterval { mono }
    func bootSession() -> String { boot }
}

final class FakeProcesses: ProcessListing, ProcessSignaling {
    var processes: [RunningProcess] = []
    var terminated: [Int32] = []
    var killed: [Int32] = []
    func running() -> [RunningProcess] { processes }
    func terminate(_ pid: Int32) { terminated.append(pid) }
    func kill(_ pid: Int32) {
        killed.append(pid)
        processes.removeAll { $0.pid == pid }
    }
}

let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
    utc.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

final class ControllerTests: XCTestCase {
    var paths: SystemPaths!
    var root: URL!
    var clock: Clock!
    var processes: FakeProcesses!
    var runner: RecordingRunner!

    // Tuesday 2026-11-03, 10:00 UTC
    override func setUpWithError() throws {
        (paths, root) = try makeSandbox()
        clock = Clock(date(2026, 11, 3, 10, 0))
        processes = FakeProcesses()
        runner = RecordingRunner()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func makeController() -> BlockController {
        let c = BlockController(
            paths: paths, runner: runner,
            resolver: FakeResolver(table: ["site.test": ["10.0.0.7"], "www.site.test": ["10.0.0.8"], "more.test": ["10.0.0.9"], "www.more.test": []]),
            scraper: NoScraper(),
            appBlocker: AppBlocker(lister: processes, signaler: processes, ownPID: 1),
            calendar: utc, clocks: clock)
        c.log = { _ in }
        return c
    }

    func request(minutes: Int = 60, entries: [String] = ["site.test"], allow: Bool = false, apps: [BlockedApp] = []) -> BlockRequest {
        BlockRequest(entries: entries, isAllowlist: allow, endDate: clock.now.addingTimeInterval(TimeInterval(minutes) * 60), apps: apps)
    }

    var hosts: String { (try? String(contentsOfFile: paths.hosts, encoding: .utf8)) ?? "" }

    func testFullLifecycleWritesStateThenExpiresAndRecordsHistory() throws {
        let c = makeController()
        try c.startBlock(request(minutes: 30))
        XCTAssertNotNil(c.activeBlock)
        XCTAssertTrue(hosts.contains("site.test"))

        // State is on disk for the app to read.
        let onDisk = StateStore(path: paths.state).load()
        XCTAssertEqual(onDisk.activeBlock?.entries, ["site.test"])

        clock.advance(29 * 60)
        c.tick()
        XCTAssertNotNil(c.activeBlock, "still running 1 minute early")
        XCTAssertTrue(hosts.contains("site.test"))

        clock.advance(61)
        c.tick()
        XCTAssertNil(c.activeBlock)
        XCTAssertFalse(hosts.contains("site.test"))
        XCTAssertEqual(c.state.history.count, 1)
        XCTAssertEqual(c.state.history[0].duration, 30 * 60, accuracy: 1)
        XCTAssertEqual(StateStore(path: paths.state).load().history.count, 1)
    }

    func testCannotStartTwoBlocks() throws {
        let c = makeController()
        try c.startBlock(request())
        XCTAssertThrowsError(try c.startBlock(request())) { XCTAssertEqual(($0 as? SCError)?.code, .blockAlreadyRunning) }
    }

    func testRejectsInvalidRequests() throws {
        let c = makeController()
        XCTAssertThrowsError(try c.startBlock(request(entries: [])))
        XCTAssertThrowsError(try c.startBlock(request(entries: ["   ", "*"])), "only invalid entries")
        XCTAssertThrowsError(try c.startBlock(BlockRequest(entries: ["a.test"], isAllowlist: false, endDate: clock.now.addingTimeInterval(-5))))
        XCTAssertThrowsError(try c.startBlock(request(minutes: 8 * 24 * 60)))
        XCTAssertNil(c.activeBlock)
        XCTAssertFalse(c.blockRulesFoundOnSystem, "a rejected request must leave nothing behind")
    }

    func testEmptyAllowlistIsAllowed() throws {
        let c = makeController()
        try c.startBlock(request(entries: [], allow: true))
        let anchor = try String(contentsOfFile: paths.pfAnchor, encoding: .utf8)
        XCTAssertTrue(anchor.contains("block return out proto tcp from any to any\n"))
    }

    func testTamperingWithHostsIsRepairedOnNextTick() throws {
        let c = makeController()
        try c.startBlock(request())
        try HostsFileEditor.defaultContents.write(toFile: paths.hosts, atomically: true, encoding: .utf8)
        XCTAssertFalse(hosts.contains("site.test"))

        clock.advance(1)
        c.tick()
        XCTAssertTrue(hosts.contains("site.test"), "daemon should re-add a removed hosts block")
    }

    func testTamperingWithPfConfIsRepaired() throws {
        let c = makeController()
        try c.startBlock(request())
        try "# wiped\n".write(toFile: paths.pfConf, atomically: true, encoding: .utf8)
        clock.advance(1)
        c.tick()
        XCTAssertTrue(PacketFilter.blockFound(paths: paths))
    }

    func testDeletedStateWithRemainingRulesIsCleanedUp() throws {
        let c = makeController()
        try c.startBlock(request())
        try FileManager.default.removeItem(atPath: paths.state)

        let restarted = makeController()   // simulates a daemon restart that finds no state
        XCTAssertNil(restarted.activeBlock)
        restarted.tick()
        XCTAssertFalse(restarted.blockRulesFoundOnSystem, "can't know the end time, so remnants are removed to avoid a permanent block")
    }

    func testNeverTouchesABlockStartedByTheOriginalSelfControlApp() throws {
        // The original app can be installed side by side. Its block (hosts markers + "org.eyebeam" anchor)
        // must survive our daemon's "no block in my state, clean up remnants" logic.
        let originalHosts = HostsFileEditor.defaultContents
            + "\n# BEGIN SELFCONTROL BLOCK\n0.0.0.0\tfacebook.com\n# END SELFCONTROL BLOCK\n"
        try originalHosts.write(toFile: paths.hosts, atomically: true, encoding: .utf8)
        let originalPf = "scrub-anchor \"com.apple/*\"\nanchor \"org.eyebeam\"\nload anchor \"org.eyebeam\" from \"/etc/pf.anchors/org.eyebeam\"\n"
        try originalPf.write(toFile: paths.pfConf, atomically: true, encoding: .utf8)

        let c = makeController()
        XCTAssertFalse(c.blockRulesFoundOnSystem)
        c.tick()
        XCTAssertEqual(hosts, originalHosts)
        XCTAssertEqual(try String(contentsOfFile: paths.pfConf, encoding: .utf8), originalPf)

        // ...and starting and ending one of our own blocks leaves theirs alone too.
        try c.startBlock(request(minutes: 1))
        clock.advance(61)
        c.tick()
        XCTAssertNil(c.activeBlock)
        XCTAssertTrue(hosts.contains("# BEGIN SELFCONTROL BLOCK"))
        XCTAssertTrue(hosts.contains("0.0.0.0\tfacebook.com"))
        XCTAssertTrue(try String(contentsOfFile: paths.pfConf, encoding: .utf8).contains("anchor \"org.eyebeam\""))
        XCTAssertFalse(hosts.contains("HOLDFAST"))
    }

    func testBlockSurvivesDaemonRestart() throws {
        let c = makeController()
        try c.startBlock(request(minutes: 60))
        let restarted = makeController()
        XCTAssertNotNil(restarted.activeBlock)
        clock.advance(3601)
        restarted.tick()
        XCTAssertNil(restarted.activeBlock)
        XCTAssertFalse(restarted.blockRulesFoundOnSystem)
    }

    func testExtendOnlyLaterAndAtMostADay() throws {
        let c = makeController()
        try c.startBlock(request(minutes: 60))
        let end = c.activeBlock!.endDate
        XCTAssertThrowsError(try c.extendBlock(to: end.addingTimeInterval(-60))) { XCTAssertEqual(($0 as? SCError)?.code, .endDateInPast) }
        XCTAssertThrowsError(try c.extendBlock(to: end.addingTimeInterval(86_401))) { XCTAssertEqual(($0 as? SCError)?.code, .extensionTooLong) }
        try c.extendBlock(to: end.addingTimeInterval(1_800))
        XCTAssertEqual(c.activeBlock!.endDate, end.addingTimeInterval(1_800))
    }

    func testAddingSitesToRunningBlock() throws {
        let c = makeController()
        try c.startBlock(request())
        try c.addToBlock(BlockAddition(entries: ["more.test", "site.test", "bad entry!"]))
        XCTAssertEqual(c.activeBlock!.entries, ["site.test", "more.test"], "duplicates and invalid entries are ignored")
        XCTAssertTrue(hosts.contains("more.test"))
        XCTAssertTrue(try String(contentsOfFile: paths.pfAnchor, encoding: .utf8).contains("10.0.0.9"))
    }

    func testCannotAddSitesToAllowlistBlock() throws {
        let c = makeController()
        try c.startBlock(request(entries: ["site.test"], allow: true))
        XCTAssertThrowsError(try c.addToBlock(BlockAddition(entries: ["more.test"]))) {
            XCTAssertEqual(($0 as? SCError)?.code, .allowlistCannotBeUpdated)
        }
    }

    // MARK: App blocking

    func testAppOnlyBlockNeverTouchesHostsOrPf() throws {
        let c = makeController()
        let hostsBefore = hosts
        let app = BlockedApp(bundleID: "com.example.Game", name: "Game", path: "/Applications/Game.app")
        try c.startBlock(BlockRequest(entries: [], isAllowlist: false, endDate: clock.now.addingTimeInterval(600), apps: [app]))
        XCTAssertEqual(hosts, hostsBefore)
        XCTAssertFalse(PacketFilter.blockFound(paths: paths))
        XCTAssertFalse(c.activeBlock!.usesNetworkRules)

        processes.processes = [RunningProcess(pid: 500, path: "/Applications/Game.app/Contents/MacOS/Game"),
                               RunningProcess(pid: 501, path: "/Applications/Game.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"),
                               RunningProcess(pid: 502, path: "/Applications/GameShop.app/Contents/MacOS/GameShop"),
                               RunningProcess(pid: 503, path: "/usr/bin/safe")]
        clock.advance(1)
        c.tick()
        XCTAssertEqual(Set(processes.terminated), [500, 501], "app and its helpers, not look-alike prefixes")

        // Still alive 2s later -> SIGKILL.
        clock.advance(2)
        c.tick()
        XCTAssertEqual(Set(processes.killed), [500, 501])
    }

    func testRelaunchedAppIsKilledAgain() throws {
        let c = makeController()
        let app = BlockedApp(bundleID: "x", name: "X", path: "/Applications/X.app")
        try c.startBlock(BlockRequest(entries: [], isAllowlist: false, endDate: clock.now.addingTimeInterval(600), apps: [app]))
        processes.processes = [RunningProcess(pid: 10, path: "/Applications/X.app/Contents/MacOS/X")]
        c.tick()
        processes.processes = []
        clock.advance(5)
        processes.processes = [RunningProcess(pid: 11, path: "/Applications/X.app/Contents/MacOS/X")]
        c.tick()
        XCTAssertEqual(processes.terminated, [10, 11])
    }

    func testProtectedAppsAreDroppedAndNeverKilled() throws {
        let c = makeController()
        let finder = BlockedApp(bundleID: "com.apple.finder", name: "Finder", path: "/System/Library/CoreServices/Finder.app")
        XCTAssertThrowsError(try c.startBlock(BlockRequest(entries: [], isAllowlist: false,
                                                           endDate: clock.now.addingTimeInterval(600), apps: [finder])),
                             "a block containing only protected apps has nothing left to block")
        let blocker = AppBlocker(lister: processes, signaler: processes, ownPID: 99)
        processes.processes = [RunningProcess(pid: 300, path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder")]
        XCTAssertTrue(blocker.enforce(apps: [finder]).isEmpty)
    }

    func testAppPathThroughSymlinkStillMatchesCanonicalProcessPath() throws {
        // Regression (found by the end-to-end run): proc_pidpath reports /private/tmp/..., while the stored
        // path goes through the /tmp symlink. The literals below deliberately don't use the code under test.
        let name = "sc-symlink-\(UUID().uuidString)"
        let appDir = "/tmp/\(name)/Game.app"
        try FileManager.default.createDirectory(atPath: appDir + "/Contents/MacOS", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: "/tmp/\(name)") }

        let viaSymlink = BlockedApp(bundleID: "g", name: "Game", path: appDir)
        let blocker = AppBlocker(lister: processes, signaler: processes, ownPID: 1)
        processes.processes = [RunningProcess(pid: 700, path: "/private/tmp/\(name)/Game.app/Contents/MacOS/Game")]
        XCTAssertEqual(blocker.enforce(apps: [viaSymlink]), [700])
    }

    func testAppBlockerNeverKillsItself() {
        let blocker = AppBlocker(lister: processes, signaler: processes, ownPID: 42)
        processes.processes = [RunningProcess(pid: 42, path: "/Applications/X.app/Contents/MacOS/holdfastd")]
        blocker.enforce(apps: [BlockedApp(bundleID: "x", name: "X", path: "/Applications/X.app")])
        XCTAssertTrue(processes.terminated.isEmpty)
    }

    func testAddingAppsToRunningBlock() throws {
        let c = makeController()
        try c.startBlock(request())
        let app = BlockedApp(bundleID: "com.example.Chat", name: "Chat", path: "/Applications/Chat.app")
        try c.addToBlock(BlockAddition(apps: [app]))
        XCTAssertEqual(c.activeBlock!.apps, [app])
        try c.addToBlock(BlockAddition(apps: [app]))
        XCTAssertEqual(c.activeBlock!.apps.count, 1)
    }

    func testAddingSiteToAppOnlyBlockBuildsNetworkRules() throws {
        let c = makeController()
        let app = BlockedApp(bundleID: "x", name: "X", path: "/Applications/X.app")
        try c.startBlock(BlockRequest(entries: [], isAllowlist: false, endDate: clock.now.addingTimeInterval(600), apps: [app]))
        try c.addToBlock(BlockAddition(entries: ["site.test"]))
        XCTAssertTrue(c.activeBlock!.usesNetworkRules)
        XCTAssertTrue(hosts.contains("site.test"))
        clock.advance(601)
        c.tick()
        XCTAssertFalse(hosts.contains("site.test"))
    }

    // MARK: Clock tampering

    private func remaining(_ c: BlockController) -> TimeInterval {
        c.activeBlock?.remaining(at: clock.wall()) ?? 0
    }

    func testSettingTheClockForwardDoesNotEndTheBlock() throws {
        let c = makeController()
        try c.startBlock(request(minutes: 60))
        clock.advance(10 * 60)
        c.tick()

        clock.setWall(by: 3 * 3600)          // "it's three hours later now"
        c.tick()
        XCTAssertNotNil(c.activeBlock, "moving the date forward must not end the block")
        XCTAssertTrue(hosts.contains("site.test"))
        XCTAssertEqual(remaining(c), 50 * 60, accuracy: 2, "countdown is based on real elapsed time")
        XCTAssertEqual(c.activeBlock!.clockOffset, -3 * 3600, accuracy: 2)
        XCTAssertEqual(c.activeBlock!.displayEnd, clock.wall().addingTimeInterval(50 * 60))

        clock.advance(50 * 60 + 1)
        c.tick()
        XCTAssertNil(c.activeBlock, "and it still ends after the real time has passed")
        XCTAssertFalse(hosts.contains("site.test"))
    }

    func testSettingTheClockBackDoesNotExtendTheBlock() throws {
        let c = makeController()
        try c.startBlock(request(minutes: 30))
        clock.setWall(by: -5 * 3600)
        c.tick()
        XCTAssertNotNil(c.activeBlock)
        clock.advance(30 * 60 + 1)
        c.tick()
        XCTAssertNil(c.activeBlock, "a block must end on time even if the date was moved back")
    }

    func testCreepingTheClockInSmallStepsIsStillCaught() throws {
        let c = makeController()
        try c.startBlock(request(minutes: 60))
        for _ in 0..<600 {                   // runs the clock 1.5x too fast, in steps too small for a jump detector
            clock.advance(1)
            clock.setWall(by: 0.5)
            c.tick()
        }
        XCTAssertEqual(remaining(c), 60 * 60 - 600, accuracy: 5, "600 real seconds have passed, not 900")
        XCTAssertNotNil(c.activeBlock)
    }

    func testSleepIsNotMistakenForTampering() throws {
        let c = makeController()
        try c.startBlock(request(minutes: 120))
        clock.advance(3600)                  // lid closed for an hour: both clocks keep counting
        c.tick()
        XCTAssertEqual(c.activeBlock!.clockOffset, 0, accuracy: 1)
        XCTAssertEqual(remaining(c), 3600, accuracy: 2)
    }

    func testDaemonRestartMidBlockStillRemembersTheRealTime() throws {
        let c = makeController()
        try c.startBlock(request(minutes: 60))
        clock.advance(10 * 60)
        c.tick()
        clock.setWall(by: 3 * 3600)
        c.tick()

        let restarted = makeController()     // same boot, daemon killed and relaunched
        restarted.tick()
        XCTAssertNotNil(restarted.activeBlock)
        XCTAssertEqual(remaining(restarted), 50 * 60, accuracy: 2)
    }

    func testRebootWithMovedClockWaitsForNetworkTimeThenCorrects() throws {
        let c = makeController()
        try c.startBlock(request(minutes: 60))
        clock.advance(10 * 60)
        c.tick()
        let realTimeAfterReboot = clock.wall().addingTimeInterval(120)   // two minutes of genuine downtime

        clock.reboot(downtime: 120, wallError: 3 * 3600)                 // ...and the date was moved forward
        let restarted = makeController()
        restarted.tick()
        XCTAssertNotNil(restarted.activeBlock, "an unverified clock that says 'expired' is held, not trusted")
        XCTAssertTrue(restarted.wantsNetworkTime)
        XCTAssertTrue(hosts.contains("site.test"), "rules stay in place while we wait")

        restarted.applyNetworkTime(realTimeAfterReboot)
        XCTAssertFalse(restarted.wantsNetworkTime)
        restarted.tick()
        XCTAssertNotNil(restarted.activeBlock)
        XCTAssertEqual(remaining(restarted), 48 * 60, accuracy: 5)

        clock.advance(48 * 60 + 1)
        restarted.tick()
        XCTAssertNil(restarted.activeBlock)
    }

    func testLegitimateLongDowntimeEndsAsSoonAsNetworkTimeConfirms() throws {
        let c = makeController()
        try c.startBlock(request(minutes: 60))
        clock.advance(10 * 60)
        c.tick()

        clock.reboot(downtime: 3 * 3600)                                 // powered off overnight, clock is honest
        let restarted = makeController()
        restarted.tick()
        XCTAssertNotNil(restarted.activeBlock, "can't tell honest downtime from tampering until the network answers")
        restarted.applyNetworkTime(clock.wall())
        restarted.tick()
        XCTAssertNil(restarted.activeBlock)
    }

    func testOfflineHoldIsBoundedSoABlockCanNeverBeStuck() throws {
        let c = makeController()
        try c.startBlock(request(minutes: 60))
        clock.advance(10 * 60)
        c.tick()
        clock.reboot(downtime: 3 * 3600, wallError: 0)
        let restarted = makeController()
        restarted.tick()

        clock.advance(TrustedClock.verificationGrace - 60)
        restarted.tick()
        XCTAssertNotNil(restarted.activeBlock, "still within the grace period")
        clock.advance(120)
        restarted.tick()
        XCTAssertNil(restarted.activeBlock, "no network for 30 minutes: give up waiting and end the block")
    }

    func testRebootWithClockSetBackNeverRewindsTrustedTime() throws {
        let c = makeController()
        try c.startBlock(request(minutes: 60))
        clock.advance(10 * 60)
        c.tick()

        clock.reboot(downtime: 60, wallError: -5 * 3600)
        let restarted = makeController()
        restarted.tick()
        XCTAssertNotNil(restarted.activeBlock)
        XCTAssertEqual(remaining(restarted), 50 * 60, accuracy: 5, "time doesn't run backwards because the date did")
    }

    func testDeletedClockRecordIsTreatedAsUnverified() throws {
        let c = makeController()
        try c.startBlock(request(minutes: 60))
        try FileManager.default.removeItem(atPath: paths.state + ".clock")
        let restarted = makeController()
        XCTAssertTrue(restarted.wantsNetworkTime)
    }

    func testNetworkTimeAgreeingWithOurClockChangesNothing() throws {
        let c = makeController()
        try c.startBlock(request(minutes: 60))
        clock.reboot(downtime: 30)
        let restarted = makeController()
        let before = remaining(restarted)
        restarted.applyNetworkTime(clock.wall().addingTimeInterval(5))   // within the 60 s tolerance
        XCTAssertEqual(remaining(restarted), before, accuracy: 1)
        XCTAssertFalse(restarted.wantsNetworkTime)
    }

    // MARK: Schedules

    func schedule(days: [Int] = [2, 3, 4, 5, 6], start: (Int, Int) = (9, 0), minutes: Int = 480) -> Schedule {
        Schedule(name: "Work", weekdays: days, startHour: start.0, startMinute: start.1, durationMinutes: minutes,
                 profile: Profile(name: "Work", entries: ["site.test"]))
    }

    func testScheduleStartsBlockForRemainderOfWindow() throws {
        let c = makeController()
        try c.saveSchedules([schedule()])   // Tuesday 09:00-17:00, now 10:00
        c.tick()
        let block = try XCTUnwrap(c.activeBlock)
        XCTAssertEqual(block.endDate, date(2026, 11, 3, 17, 0))
        XCTAssertEqual(block.source.label, "Schedule: Work")
        XCTAssertTrue(hosts.contains("site.test"))
    }

    func testScheduleDoesNotRestartAfterItsBlockEnds() throws {
        let c = makeController()
        try c.saveSchedules([schedule()])
        c.tick()
        clock.now = date(2026, 11, 3, 17, 0)
        c.tick()
        XCTAssertNil(c.activeBlock)
        clock.advance(60)
        c.tick()
        XCTAssertNil(c.activeBlock, "window is over; must not re-fire")
    }

    func testScheduleDoesNothingOutsideWindowOrOnOtherDays() throws {
        let c = makeController()
        try c.saveSchedules([schedule(start: (13, 0), minutes: 60)])   // starts 13:00; now 10:00
        c.tick()
        XCTAssertNil(c.activeBlock)

        clock.now = date(2026, 11, 7, 10, 0)  // Saturday
        try c.saveSchedules([schedule()])
        c.tick()
        XCTAssertNil(c.activeBlock)
    }

    func testScheduleWaitsForRunningManualBlockThenCoversRemainingWindow() throws {
        let c = makeController()
        try c.startBlock(request(minutes: 30))           // 10:00-10:30
        try c.saveSchedules([schedule()])
        c.tick()
        XCTAssertEqual(c.activeBlock!.source, .manual)

        clock.advance(31 * 60)
        c.tick()                                         // manual block ends 10:30 -> schedule picks up
        XCTAssertNil(c.activeBlock)
        c.tick()
        XCTAssertEqual(c.activeBlock?.endDate, date(2026, 11, 3, 17, 0))
    }

    func testDisabledScheduleNeverFires() throws {
        var s = schedule()
        s.enabled = false
        let c = makeController()
        try c.saveSchedules([s])
        c.tick()
        XCTAssertNil(c.activeBlock)
    }

    func testOvernightWindowSpansMidnight() {
        let s = schedule(days: [3], start: (22, 0), minutes: 8 * 60)   // Tuesdays 22:00 -> Wed 06:00
        XCTAssertNotNil(s.window(containing: date(2026, 11, 3, 23, 0), calendar: utc))
        XCTAssertNotNil(s.window(containing: date(2026, 11, 4, 5, 59), calendar: utc), "after midnight, on Wednesday")
        XCTAssertNil(s.window(containing: date(2026, 11, 4, 6, 0), calendar: utc))
        XCTAssertNil(s.window(containing: date(2026, 11, 4, 23, 0), calendar: utc), "Wednesday 22:00 isn't a Tuesday window")
        XCTAssertEqual(s.window(containing: date(2026, 11, 4, 1, 0), calendar: utc)?.start, date(2026, 11, 3, 22, 0))
    }

    func testNextStart() {
        let s = schedule(days: [2, 4], start: (9, 0))    // Mon, Wed
        XCTAssertEqual(s.nextStart(after: date(2026, 11, 3, 10, 0), calendar: utc), date(2026, 11, 4, 9, 0))
        XCTAssertEqual(s.nextStart(after: date(2026, 11, 4, 9, 0), calendar: utc), date(2026, 11, 9, 9, 0))
        XCTAssertEqual(s.endTimeOfDay, TimeOfDay(hour: 17, minute: 0))
    }

    func testScheduleValidation() throws {
        XCTAssertThrowsError(try schedule(days: []).validate())
        XCTAssertThrowsError(try schedule(days: [8]).validate())
        XCTAssertThrowsError(try schedule(minutes: 0).validate())
        XCTAssertThrowsError(try schedule(start: (24, 0)).validate())
        var empty = schedule()
        empty.profile.entries = []
        XCTAssertThrowsError(try empty.validate())
        var unnamed = schedule()
        unnamed.name = "  "
        XCTAssertThrowsError(try unnamed.validate())
        XCTAssertNoThrow(try schedule().validate())
        let c = makeController()
        XCTAssertThrowsError(try c.saveSchedules([schedule(days: [])]))
    }
}

final class StatsTests: XCTestCase {
    func entry(_ start: Date, hours: Double) -> HistoryEntry {
        let block = ActiveBlock(request: BlockRequest(entries: ["a.com"], isAllowlist: false, endDate: start.addingTimeInterval(hours * 3600)),
                                startDate: start, usesNetworkRules: true)
        return HistoryEntry(block: block, endedAt: start.addingTimeInterval(hours * 3600))
    }

    func testTotalsAndLongest() {
        let now = date(2026, 11, 3, 12)
        let stats = BlockStats.compute(history: [entry(date(2026, 11, 3, 8), hours: 2), entry(date(2026, 11, 2, 8), hours: 4)],
                                       now: now, calendar: utc)
        XCTAssertEqual(stats.totalSeconds, 6 * 3600)
        XCTAssertEqual(stats.longestSeconds, 4 * 3600)
        XCTAssertEqual(stats.blockCount, 2)
        XCTAssertEqual(stats.daily.count, 14)
        XCTAssertEqual(stats.daily.last?.seconds, 2 * 3600)
    }

    func testStreakCountsConsecutiveDaysAndSurvivesAnEmptyToday() {
        let now = date(2026, 11, 3, 6)
        let history = [entry(date(2026, 11, 2, 9), hours: 1), entry(date(2026, 11, 1, 9), hours: 1), entry(date(2026, 10, 30, 9), hours: 1)]
        let stats = BlockStats.compute(history: history, now: now, calendar: utc)
        XCTAssertEqual(stats.currentStreakDays, 2, "today has none yet, but yesterday and the day before count")
        XCTAssertEqual(stats.longestStreakDays, 2)
    }

    func testStreakBreaksOnAGap() {
        let now = date(2026, 11, 3, 12)
        let stats = BlockStats.compute(history: [entry(date(2026, 11, 1, 9), hours: 1)], now: now, calendar: utc)
        XCTAssertEqual(stats.currentStreakDays, 0)
    }

    func testBlocksCrossingMidnightAreSplit() {
        let now = date(2026, 11, 3, 12)
        let stats = BlockStats.compute(history: [entry(date(2026, 11, 2, 22), hours: 4)], now: now, calendar: utc)
        XCTAssertEqual(stats.daily[stats.daily.count - 2].seconds, 2 * 3600)
        XCTAssertEqual(stats.daily[stats.daily.count - 1].seconds, 2 * 3600)
    }

    func testRunningBlockCountsLive() {
        let now = date(2026, 11, 3, 12)
        let active = ActiveBlock(request: BlockRequest(entries: ["a.com"], isAllowlist: false, endDate: now.addingTimeInterval(3600)),
                                 startDate: now.addingTimeInterval(-1800), usesNetworkRules: true)
        let stats = BlockStats.compute(history: [], active: active, now: now, calendar: utc)
        XCTAssertEqual(stats.totalSeconds, 1800)
        XCTAssertEqual(stats.currentStreakDays, 1)
    }
}

final class NetworkTimeTests: XCTestCase {
    private func reply(nonce: [UInt8], unix: TimeInterval, mode: UInt8 = 4, stratum: UInt8 = 2) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 48)
        p[0] = 0b00_100_000 | mode
        p[1] = stratum
        p.replaceSubrange(24..<32, with: nonce)
        let seconds = UInt32(unix + NetworkTime.ntpEpochOffset)
        let fraction = UInt32((unix - floor(unix)) * 4_294_967_296)
        for i in 0..<4 {
            p[40 + i] = UInt8((seconds >> (24 - 8 * UInt32(i))) & 0xff)
            p[44 + i] = UInt8((fraction >> (24 - 8 * UInt32(i))) & 0xff)
        }
        return p
    }

    private let nonce: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]

    func testRequestShape() {
        let packet = NetworkTime.makeRequest(nonce: nonce)
        XCTAssertEqual(packet.count, 48)
        XCTAssertEqual(packet[0] & 0b111, 3, "client mode")
        XCTAssertEqual((packet[0] >> 3) & 0b111, 4, "version 4")
        XCTAssertEqual(Array(packet[40..<48]), nonce)
    }

    func testParsesAValidReply() throws {
        let when = 1_800_000_000.25
        let parsed = try XCTUnwrap(NetworkTime.parseResponse(reply(nonce: nonce, unix: when), nonce: nonce))
        XCTAssertEqual(parsed.timeIntervalSince1970, when, accuracy: 0.001)
    }

    func testRejectsRepliesThatAreNotAnswersToUs() {
        XCTAssertNil(NetworkTime.parseResponse(reply(nonce: [9, 9, 9, 9, 9, 9, 9, 9], unix: 1_800_000_000), nonce: nonce), "wrong nonce (spoofed/replayed)")
        XCTAssertNil(NetworkTime.parseResponse(reply(nonce: nonce, unix: 1_800_000_000, mode: 3), nonce: nonce), "not a server reply")
        XCTAssertNil(NetworkTime.parseResponse(reply(nonce: nonce, unix: 1_800_000_000, stratum: 0), nonce: nonce), "kiss-o'-death / unsynchronised")
        XCTAssertNil(NetworkTime.parseResponse([UInt8](repeating: 0, count: 10), nonce: nonce), "truncated")
    }
}
