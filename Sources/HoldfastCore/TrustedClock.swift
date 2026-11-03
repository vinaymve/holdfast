// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import Foundation
import Darwin

/// The time sources the daemon needs, abstracted so tests can move them independently.
public protocol SystemClocks {
    /// The user-settable wall clock. Can't be trusted during a block.
    func wall() -> Date
    /// Seconds from an arbitrary point. Keeps counting while the Mac sleeps, ignores clock changes,
    /// and restarts from ~0 at reboot.
    func monotonic() -> TimeInterval
    /// Changes on every reboot.
    func bootSession() -> String
}

public struct RealClocks: SystemClocks {
    public init() {}

    public func wall() -> Date { Date() }

    public func monotonic() -> TimeInterval {
        // CLOCK_MONOTONIC_RAW counts through sleep; CLOCK_UPTIME_RAW would pause and make every sleep
        // look like a forward clock jump.
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
    }

    public func bootSession() -> String {
        var size = 0
        sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}

/// Time that can't be moved by changing the system date.
///
/// While a block runs, "now" is an anchor plus elapsed monotonic time. Within one boot that is immune to
/// clock changes. A reboot loses the monotonic reference, so afterwards the clock starts out *unverified*
/// (the wall clock might have been moved while we weren't looking) until an NTP answer confirms or corrects it.
public final class TrustedClock {
    struct Saved: Codable {
        var bootSession: String
        var trusted: Date
        var monotonic: Double
        var verified: Bool
    }

    /// Network time must disagree by more than this before we overrule our own clock.
    public static let resyncThreshold: TimeInterval = 60
    /// While unverified, a block that looks expired is held at most this long, so offline Macs can't get stuck.
    public static let verificationGrace: TimeInterval = 30 * 60

    public private(set) var verified = true
    public private(set) var isRunning = false

    private let clocks: SystemClocks
    private let path: String
    private var anchorTrusted = Date()
    private var anchorMono: Double = 0
    private var unverifiedSinceMono: Double = 0
    private var lastSaveMono: Double = -.infinity

    public init(clocks: SystemClocks, path: String) {
        self.clocks = clocks
        self.path = path
    }

    /// Trusted "now". Only meaningful while `isRunning`.
    public var now: Date {
        isRunning ? anchorTrusted.addingTimeInterval(clocks.monotonic() - anchorMono) : clocks.wall()
    }

    /// Trusted time minus wall time. Zero unless the wall clock has been moved (or drifted).
    public var offset: TimeInterval { now.timeIntervalSince(clocks.wall()) }

    /// How long we've been waiting for the first network confirmation.
    public var unverifiedDuration: TimeInterval { verified ? 0 : clocks.monotonic() - unverifiedSinceMono }

    /// A block just started: the wall clock is taken as correct right now, then ignored.
    public func begin() {
        anchorTrusted = clocks.wall()
        anchorMono = clocks.monotonic()
        verified = true
        isRunning = true
        save(force: true)
    }

    /// The daemon (re)started with a block already running.
    public func resume() {
        let wall = clocks.wall()
        let mono = clocks.monotonic()
        isRunning = true
        anchorMono = mono

        guard let data = FileManager.default.contents(atPath: path),
              let saved = try? Coding.decoder().decode(Saved.self, from: data) else {
            // No record at all (deleted?). Trust the wall clock but demand confirmation.
            anchorTrusted = wall
            markUnverified(mono)
            save(force: true)
            return
        }

        if saved.bootSession == clocks.bootSession() {
            // Same boot: the monotonic clock carried on while we were down, so nothing is lost.
            anchorTrusted = saved.trusted.addingTimeInterval(mono - saved.monotonic)
            verified = saved.verified
            if !verified { unverifiedSinceMono = mono }
        } else {
            // Rebooted. Time can't go backwards; going forwards might be real downtime or a changed clock.
            anchorTrusted = max(wall, saved.trusted)
            markUnverified(mono)
        }
        save(force: true)
    }

    /// Returns true if the network disagreed enough that our time was corrected.
    @discardableResult
    public func applyNetworkTime(_ network: Date) -> Bool {
        guard isRunning else { return false }
        let difference = network.timeIntervalSince(now)
        var corrected = false
        if abs(difference) > Self.resyncThreshold {
            anchorTrusted = network
            anchorMono = clocks.monotonic()
            corrected = true
        }
        verified = true
        save(force: true)
        return corrected
    }

    public func saveIfDue() {
        if clocks.monotonic() - lastSaveMono >= 5 { save(force: true) }
    }

    public func end() {
        isRunning = false
        verified = true
        try? FileManager.default.removeItem(atPath: path)
    }

    private func markUnverified(_ mono: Double) {
        verified = false
        unverifiedSinceMono = mono
    }

    private func save(force: Bool) {
        guard isRunning else { return }
        let saved = Saved(bootSession: clocks.bootSession(), trusted: now, monotonic: clocks.monotonic(), verified: verified)
        lastSaveMono = saved.monotonic
        guard let data = try? Coding.encoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
