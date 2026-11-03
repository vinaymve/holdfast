// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import XCTest
@testable import HoldfastCore

final class BlockEntryTests: XCTestCase {
    func testPlainHostname() {
        XCTAssertEqual(BlockEntry.parse("facebook.com"), BlockEntry(hostname: "facebook.com"))
    }

    func testHostnameWithPort() {
        XCTAssertEqual(BlockEntry.parse("mail.example.com:993"), BlockEntry(hostname: "mail.example.com", port: 993))
    }

    func testCIDRWithAndWithoutPort() {
        XCTAssertEqual(BlockEntry.parse("10.0.0.0/8"), BlockEntry(hostname: "10.0.0.0", maskLen: 8))
        XCTAssertEqual(BlockEntry.parse("10.0.0.0/24:80"), BlockEntry(hostname: "10.0.0.0", port: 80, maskLen: 24))
    }

    func testWildcardNeedsAPort() {
        XCTAssertNil(BlockEntry.parse("*"))
        XCTAssertNil(BlockEntry.parse(""))
        XCTAssertEqual(BlockEntry.parse("*:443"), BlockEntry(hostname: "*", port: 443))
        XCTAssertEqual(BlockEntry.parse(":443"), BlockEntry(hostname: "*", port: 443))
    }

    func testIPv6() {
        XCTAssertEqual(BlockEntry.parse("2001:4860::/32"), BlockEntry(hostname: "2001:4860::", maskLen: 32))
        XCTAssertEqual(BlockEntry.parse("::1"), BlockEntry(hostname: "::1"))
        XCTAssertEqual(BlockEntry.parse("[2001:db8::1]:8080"), BlockEntry(hostname: "2001:db8::1", port: 8080))
        XCTAssertTrue(BlockEntry.parse("2001:4860::/32")!.isIPv6)
    }

    func testPastedURLsAreCleaned() {
        XCTAssertEqual(BlockEntry.parse("https://www.Reddit.com/r/swift"), BlockEntry(hostname: "www.reddit.com"))
        XCTAssertEqual(BlockEntry.parse("  example.com.  "), BlockEntry(hostname: "example.com"))
    }

    func testRejectsAnythingThatCouldInjectIntoConfigFiles() {
        XCTAssertNil(BlockEntry.parse("evil.com\n127.0.0.1 bank.com"))
        XCTAssertNil(BlockEntry.parse("a b.com"))
        XCTAssertNil(BlockEntry.parse("x.com # comment"))
        XCTAssertNil(BlockEntry.parse("foo\"bar.com"))
        XCTAssertNil(BlockEntry.parse("a.com;rm"))
        XCTAssertNil(BlockEntry.parse("example.com:99999"))
        XCTAssertNil(BlockEntry.parse("10.0.0.0/33"))
        XCTAssertNil(BlockEntry.parse("a..com"))
    }

    func testKinds() {
        XCTAssertTrue(BlockEntry.parse("1.2.3.4")!.isIPv4)
        XCTAssertTrue(BlockEntry.parse("example.com")!.isDomain)
        XCTAssertFalse(BlockEntry.parse("1.2.3.4")!.isDomain)
    }
}

final class DurationTests: XCTestCase {
    func testParsesCommonForms() {
        XCTAssertEqual(DurationParser.minutes(from: "90"), 90)
        XCTAssertEqual(DurationParser.minutes(from: "45m"), 45)
        XCTAssertEqual(DurationParser.minutes(from: "2h"), 120)
        XCTAssertEqual(DurationParser.minutes(from: "1.5h"), 90)
        XCTAssertEqual(DurationParser.minutes(from: "1h30m"), 90)
        XCTAssertEqual(DurationParser.minutes(from: "1h 30"), 90)
        XCTAssertEqual(DurationParser.minutes(from: "2 hours"), 120)
        XCTAssertEqual(DurationParser.minutes(from: "1:30"), 90)
        XCTAssertEqual(DurationParser.minutes(from: " 3 HRS "), 180)
    }

    func testRejectsGarbage() {
        XCTAssertNil(DurationParser.minutes(from: ""))
        XCTAssertNil(DurationParser.minutes(from: "abc"))
        XCTAssertNil(DurationParser.minutes(from: "2 weeks"))
        XCTAssertNil(DurationParser.minutes(from: "0"))
        XCTAssertNil(DurationParser.minutes(from: "1:75"))
        XCTAssertNil(DurationParser.minutes(from: "1h foo"))
        XCTAssertNil(DurationParser.minutes(from: "30 1h"))
    }

    func testTimeOfDay() {
        XCTAssertEqual(TimeOfDay.parse("17:30"), TimeOfDay(hour: 17, minute: 30))
        XCTAssertEqual(TimeOfDay.parse("5:30pm"), TimeOfDay(hour: 17, minute: 30))
        XCTAssertEqual(TimeOfDay.parse("5 PM"), TimeOfDay(hour: 17, minute: 0))
        XCTAssertEqual(TimeOfDay.parse("12am"), TimeOfDay(hour: 0, minute: 0))
        XCTAssertEqual(TimeOfDay.parse("12pm"), TimeOfDay(hour: 12, minute: 0))
        XCTAssertEqual(TimeOfDay.parse("1730"), TimeOfDay(hour: 17, minute: 30))
        XCTAssertEqual(TimeOfDay.parse("9"), TimeOfDay(hour: 9, minute: 0))
        XCTAssertNil(TimeOfDay.parse("25:00"))
        XCTAssertNil(TimeOfDay.parse("13pm"))
        XCTAssertNil(TimeOfDay.parse("noon"))
    }

    func testBlockLengthUntilPicksNextOccurrence() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let at = { (h: Int, m: Int) in cal.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: h, minute: m))! }

        // 2:00 PM, until 5:00 PM -> same day
        XCTAssertEqual(BlockLength.until(hour: 17, minute: 0).endDate(from: at(14, 0), calendar: cal), at(17, 0))
        // 6:00 PM, until 5:00 PM -> tomorrow
        let tomorrow = cal.date(byAdding: .day, value: 1, to: at(17, 0))!
        XCTAssertEqual(BlockLength.until(hour: 17, minute: 0).endDate(from: at(18, 0), calendar: cal), tomorrow)
        // exactly 5:00 PM, until 5:00 PM -> tomorrow, never a zero-length block
        XCTAssertEqual(BlockLength.until(hour: 17, minute: 0).endDate(from: at(17, 0), calendar: cal), tomorrow)
        // duration
        XCTAssertEqual(BlockLength.duration(minutes: 90).endDate(from: at(14, 0), calendar: cal), at(15, 30))
    }

    func testFormatting() {
        XCTAssertEqual(Format.duration(2 * 3600 + 14 * 60), "2h 14m")
        XCTAssertEqual(Format.duration(45 * 60), "45m")
        XCTAssertEqual(Format.duration(3600), "1h")
        XCTAssertEqual(Format.duration(86_400 + 7_200), "1d 2h")
        XCTAssertEqual(Format.clock(2 * 3600 + 14 * 60 + 5), "02:14:05")
        XCTAssertEqual(Format.clock(-4), "00:00:00")
    }
}

final class AuthorizationRuleTests: XCTestCase {
    func testRuleMatchesAppleStockAdminRuleShape() {
        // Regression: a custom "mechanisms" list made authd loop on "Mechanism failed to return a valid UID",
        // so no password was ever accepted and Touch ID never appeared.
        let rule = SCAuthorization.rule
        XCTAssertNil(rule["mechanisms"])
        XCTAssertEqual(rule["class"] as? String, "user")
        XCTAssertEqual(rule["group"] as? String, "admin")
        XCTAssertEqual(rule["shared"] as? Bool, true)
    }
}

final class AuthorizationLifetimeTests: XCTestCase {
    private func restore(_ data: Data) -> OSStatus {
        var ext = AuthorizationExternalForm()
        withUnsafeMutableBytes(of: &ext) { _ = data.copyBytes(to: $0) }
        var ref: AuthorizationRef?
        let status = AuthorizationCreateFromExternalForm(&ext, &ref)
        if let ref { AuthorizationFree(ref, []) }
        return status
    }

    func testExternalFormOnlyWorksWhileTheOriginalReferenceIsAlive() throws {
        // Regression: freeing the AuthorizationRef right after externalizing it made the daemon reject every
        // request, even with the right password.
        var ref: AuthorizationRef?
        try XCTSkipUnless(AuthorizationCreate(nil, nil, [], &ref) == errAuthorizationSuccess, "needs a login session")
        var ext = AuthorizationExternalForm()
        XCTAssertEqual(AuthorizationMakeExternalForm(ref!, &ext), errAuthorizationSuccess)
        let data = withUnsafeBytes(of: &ext) { Data($0) }

        XCTAssertEqual(restore(data), errAuthorizationSuccess)
        AuthorizationFree(ref!, [])
        XCTAssertNotEqual(restore(data), errAuthorizationSuccess)
    }

    func testTicketKeepsAuthorizationAliveUntilReleased() throws {
        var ref: AuthorizationRef?
        try XCTSkipUnless(AuthorizationCreate(nil, nil, [], &ref) == errAuthorizationSuccess, "needs a login session")
        var ext = AuthorizationExternalForm()
        _ = AuthorizationMakeExternalForm(ref!, &ext)
        var ticket: SCAuthorization.Ticket? = SCAuthorization.Ticket(ref: ref!, externalForm: withUnsafeBytes(of: &ext) { Data($0) })
        let data = ticket!.externalForm
        XCTAssertEqual(restore(data), errAuthorizationSuccess)
        ticket = nil
        XCTAssertNotEqual(restore(data), errAuthorizationSuccess, "the ticket frees the reference when released")
    }

    func testVerifyRejectsGarbageWithoutCrashing() {
        XCTAssertFalse(SCAuthorization.verify(Data(), right: SC.startRight))
        XCTAssertFalse(SCAuthorization.verify(Data(repeating: 7, count: 32), right: SC.startRight))
    }
}

final class InstallerScriptTests: XCTestCase {
    func testInstallScriptIsValidShell() throws {
        let script = HelperInstaller.installScript(sourceBinary: "/Applications/Holdfast.app/Contents/MacOS/it's odd/holdfastd")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("install-\(UUID().uuidString).sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let result = ProcessRunner().run("/bin/sh", ["-n", file.path])
        XCTAssertEqual(result.status, 0, "syntax error in generated script: \(result.output)")
    }

    func testUninstallScriptIsValidShell() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("uninstall-\(UUID().uuidString).sh")
        try HelperInstaller.uninstallScript().write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(ProcessRunner().run("/bin/sh", ["-n", file.path]).status, 0)
    }

    func testLegacyHelperIsOnlyRemovedWhenIdle() {
        let script = HelperInstaller.installScript(sourceBinary: "/x/holdfastd")
        guard let guardRange = script.range(of: "--can-uninstall; then"),
              let removeRange = script.range(of: "rm -f", range: guardRange.upperBound..<script.endIndex) else {
            return XCTFail("legacy cleanup missing or unguarded")
        }
        XCTAssertTrue(guardRange.upperBound < removeRange.lowerBound, "removal must come after the idle check")
    }

    func testNewHelperUsesDistinctIdentityFromTheLegacyAndOriginalApps() {
        XCTAssertNotEqual(SC.serviceName, SC.legacyServiceName)
        XCTAssertFalse(SC.serviceName.contains("eyebeam"))
        XCTAssertNotEqual(SC.hostsBegin, "# BEGIN SELFCONTROL BLOCK")
        XCTAssertNotEqual(SC.pfAnchorName, "org.eyebeam")
    }
}

final class NetworkTimeLiveTests: XCTestCase {
    func testParsesHTTPDateHeaders() throws {
        let date = try XCTUnwrap(NetworkTime.parseHTTPDate("Tue, 03 Nov 2026 12:34:56 GMT"))
        XCTAssertEqual(date.timeIntervalSince1970, 1_793_709_296, accuracy: 0.5)
        XCTAssertNil(NetworkTime.parseHTTPDate("not a date"))
    }

    /// Opt-in: one real HTTPS request. `HOLDFAST_NETWORK_TESTS=1 swift test --filter NetworkTimeLiveTests`
    func testLiveHTTPSDateAgreesWithTheSystemClock() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HOLDFAST_NETWORK_TESTS"] == "1", "set HOLDFAST_NETWORK_TESTS=1")
        let network = try XCTUnwrap(NetworkTime.queryHTTPS(), "no HTTPS answer (offline?)")
        let skew = network.timeIntervalSince(Date())
        print("HTTPS time skew vs system clock: \(skew) s")
        XCTAssertLessThan(abs(skew), 5)
    }

    /// Opt-in: sends one real SNTP request to time.apple.com. `HOLDFAST_NETWORK_TESTS=1 swift test --filter NetworkTimeLiveTests`
    func testLiveQueryAgreesWithTheSystemClock() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HOLDFAST_NETWORK_TESTS"] == "1", "set HOLDFAST_NETWORK_TESTS=1")
        let network = try XCTUnwrap(NetworkTime.query(), "no NTP answer (offline?)")
        let skew = network.timeIntervalSince(Date())
        print("NTP skew vs system clock: \(skew) s")
        XCTAssertLessThan(abs(skew), 5, "a correctly synced Mac should be within a few seconds")
    }
}
