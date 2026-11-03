// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import Foundation

/// All block logic that the daemon runs, with no XPC or launchd in sight so it can be tested directly.
/// Port of SCDaemonBlockMethods, plus app blocking, schedule firing, and history.
///
/// Not thread-safe by itself: the daemon calls it from one serial queue.
public final class BlockController {
    public private(set) var state: DaemonState
    public var onChange: (() -> Void)?
    public var log: (String) -> Void = { NSLog("%@", $0) }

    private let store: StateStore
    private let paths: SystemPaths
    private let runner: CommandRunner
    private let resolver: DomainResolving
    private let scraper: LinkScraping
    private let appBlocker: AppBlocker
    private let clocks: SystemClocks
    private let trusted: TrustedClock
    private let calendar: Calendar

    private var lastHeavyCheck = Date.distantPast
    private var clearFailures = 0
    private var loggedClockHold = false
    private var scheduleAttempts: [String: (count: Int, retryAt: Date)] = [:]
    private let maxHistory = 2_000

    public init(paths: SystemPaths = .production, runner: CommandRunner = ProcessRunner(),
                resolver: DomainResolving = SystemResolver(), scraper: LinkScraping = HTTPLinkScraper(),
                appBlocker: AppBlocker = AppBlocker(), calendar: Calendar = .current,
                clocks: SystemClocks = RealClocks()) {
        self.paths = paths
        self.runner = runner
        self.resolver = resolver
        self.scraper = scraper
        self.appBlocker = appBlocker
        self.calendar = calendar
        self.clocks = clocks
        self.trusted = TrustedClock(clocks: clocks, path: paths.state + ".clock")
        self.store = StateStore(path: paths.state)
        self.state = store.load()
        // Daemon (re)started in the middle of a block: pick the trusted clock back up.
        if state.activeBlock != nil { trusted.resume() }
    }

    /// The system clock. Only used when no block is running; during a block, `trusted` is used instead,
    /// because changing the date must not be able to shorten (or lengthen) a block.
    private var wall: Date { clocks.wall() }

    public var activeBlock: ActiveBlock? { state.activeBlock }

    private func makeEngine(_ config: BlockEngine.Config) -> BlockEngine {
        BlockEngine(config: config, paths: paths, runner: runner, resolver: resolver, scraper: scraper)
    }

    private func persist() throws {
        do {
            try store.save(state)
        } catch {
            throw SCError(.ioFailure, "Couldn't save state: \(error.localizedDescription)")
        }
        onChange?()
    }

    // MARK: Starting

    public func startBlock(_ request: BlockRequest) throws {
        let now = wall
        guard state.activeBlock == nil else { throw SCError(.blockAlreadyRunning) }

        let validEntries = request.entries.compactMap(BlockEntry.parse)
        var request = request
        request.apps = request.apps.filter(\.isBlockable)
        if !request.isAllowlist && validEntries.isEmpty && request.apps.isEmpty {
            throw SCError(.invalidRequest, "There is nothing to block.")
        }
        guard request.endDate > now else { throw SCError(.invalidRequest, "The end time is in the past.") }
        guard request.endDate.timeIntervalSince(now) <= SC.maxBlockSeconds else {
            throw SCError(.invalidRequest, "Blocks can't be longer than 7 days.")
        }

        let block = ActiveBlock(request: request, startDate: now,
                                usesNetworkRules: request.isAllowlist || !validEntries.isEmpty)

        // Anything left behind by a crash or tampering would confuse the new block.
        if !block.usesNetworkRules, blockRulesFoundOnSystem { _ = makeEngine(.init(isAllowlist: false)).clearBlock() }

        if block.usesNetworkRules {
            do { try installNetworkRules(for: block) } catch {
                _ = makeEngine(.init(block: block)).clearBlock()
                throw error
            }
        }

        state.activeBlock = block
        trusted.begin()
        do { try persist() } catch {
            state.activeBlock = nil
            trusted.end()
            if block.usesNetworkRules { _ = makeEngine(.init(block: block)).clearBlock() }
            throw error
        }

        SystemMaintenance.clearCachesIfRequested(block.options, paths: paths, runner: runner)
        enforceApps(block, now: now)
        log("INFO: Block started, ends \(block.endDate)")
    }

    private func installNetworkRules(for block: ActiveBlock) throws {
        let engine = makeEngine(.init(block: block))
        engine.prepareToAddBlock()
        engine.add(block.entries)
        try engine.finalizeBlock()
    }

    private func enforceApps(_ block: ActiveBlock, now: Date) {
        let acted = appBlocker.enforce(apps: block.apps, now: now)
        if !acted.isEmpty { log("INFO: Stopped blocked app process(es) \(acted)") }
    }

    // MARK: Modifying a running block

    public func addToBlock(_ addition: BlockAddition) throws {
        guard var block = state.activeBlock else { throw SCError(.noBlockRunning) }

        let known = Set(block.entries)
        let newEntries = addition.entries.filter { BlockEntry.parse($0) != nil && !known.contains($0) }
        let newApps = addition.apps.filter { app in app.isBlockable && !block.apps.contains(where: { $0.id == app.id }) }

        if !newEntries.isEmpty {
            if block.isAllowlist { throw SCError(.allowlistCannotBeUpdated) }
            if block.usesNetworkRules {
                let engine = makeEngine(.init(block: block))
                try engine.beginAppending()
                engine.add(newEntries)
                try engine.finishAppending()
                block.entries += newEntries
            } else {
                // An app-only block gaining its first site needs the full network setup.
                block.entries += newEntries
                block.usesNetworkRules = true
                try installNetworkRules(for: block)
            }
        }
        block.apps += newApps

        state.activeBlock = block
        try persist()
        if !newEntries.isEmpty { SystemMaintenance.clearCachesIfRequested(block.options, paths: paths, runner: runner) }
        enforceApps(block, now: trusted.now)
    }

    /// Blocks can only be made longer, and by at most a day per call.
    public func extendBlock(to newEnd: Date) throws {
        guard var block = state.activeBlock else { throw SCError(.noBlockRunning) }
        guard newEnd >= block.endDate else { throw SCError(.endDateInPast) }
        guard newEnd.timeIntervalSince(block.endDate) <= SC.maxExtensionSeconds else { throw SCError(.extensionTooLong) }
        guard newEnd.timeIntervalSince(trusted.now) <= SC.maxBlockSeconds else {
            throw SCError(.invalidRequest, "Blocks can't be longer than 7 days.")
        }
        block.endDate = newEnd
        state.activeBlock = block
        try persist()
    }

    public func saveSchedules(_ schedules: [Schedule]) throws {
        for schedule in schedules { try schedule.validate() }
        state.schedules = schedules
        let ids = Set(schedules.map { $0.id.uuidString })
        state.scheduleFires = state.scheduleFires.filter { ids.contains($0.key) }
        try persist()
    }

    // MARK: Periodic work (called once a second)

    public func tick() {
        guard state.activeBlock != nil else {
            clearRemnantsIfAny()
            fireDueSchedules(now: wall)
            return
        }

        let now = trusted.now
        trusted.saveIfDue()
        publishClockOffset()
        guard let block = state.activeBlock else { return }

        if block.endDate <= now, !holdForClockVerification() {
            endBlock(block, at: now)
        } else {
            enforceApps(block, now: now)
            if block.usesNetworkRules { checkIntegrity(block, now: now) }
        }
    }

    // MARK: Clock tamper resistance

    /// True while the daemon wants an NTP answer (it has been restarted by a reboot and can't yet tell whether the
    /// system clock was moved while it wasn't watching).
    public var wantsNetworkTime: Bool { state.activeBlock != nil && trusted.isRunning && !trusted.verified }

    public func applyNetworkTime(_ date: Date) {
        guard state.activeBlock != nil, trusted.isRunning else { return }
        if trusted.applyNetworkTime(date) {
            log("WARNING: The system clock disagrees with network time; using network time for this block.")
        }
        publishClockOffset()
    }

    /// An unverified clock that says "the block is over" is held for a while, waiting for network time.
    /// The wait is bounded so a Mac with no network can never be stuck in a permanent block.
    private func holdForClockVerification() -> Bool {
        guard !trusted.verified, trusted.unverifiedDuration < TrustedClock.verificationGrace else { return false }
        if !loggedClockHold {
            loggedClockHold = true
            log("INFO: Block looks finished but the clock is unverified after a restart; waiting for network time.")
        }
        return true
    }

    /// Lets the app compute the right countdown even when the wall clock has been moved.
    private func publishClockOffset() {
        guard var block = state.activeBlock else { return }
        let offset = trusted.offset
        guard abs(offset - block.clockOffset) >= 1 else { return }
        block.clockOffset = offset
        state.activeBlock = block
        try? persist()
    }

    /// The block ended on schedule (or we're retrying a failed cleanup).
    private func endBlock(_ block: ActiveBlock, at now: Date) {
        var cleared = true
        if block.usesNetworkRules || blockRulesFoundOnSystem {
            let engine = makeEngine(.init(block: block))
            cleared = engine.clearBlock()
            if !cleared {
                clearFailures += 1
                log("WARNING: Failed to clear block (attempt \(clearFailures))")
                if clearFailures >= 3 { cleared = engine.forceClearBlock() }
            }
        }
        guard cleared else { return }

        clearFailures = 0
        loggedClockHold = false
        trusted.end()
        state.activeBlock = nil
        state.history.append(HistoryEntry(block: block, endedAt: min(now, max(block.endDate, block.startDate))))
        if state.history.count > maxHistory { state.history.removeFirst(state.history.count - maxHistory) }
        do { try persist() } catch { log("ERROR: \(error.localizedDescription)") }
        SystemMaintenance.clearCachesIfRequested(block.options, paths: paths, runner: runner)
        log("INFO: Block ended.")
    }

    public var blockRulesFoundOnSystem: Bool {
        PacketFilter.blockFound(paths: paths) || HostsFileEditor(path: paths.hosts).containsBlock()
    }

    /// If there's no block in our state but rules are on the system, state was lost or tampered with.
    /// We can't know when the block should end, so we remove it rather than risk a permanent block.
    private func clearRemnantsIfAny() {
        guard blockRulesFoundOnSystem else { return }
        log("WARNING: Block rules found with no active block; clearing.")
        let engine = makeEngine(.init(isAllowlist: false))
        if !engine.clearBlock() { _ = engine.forceClearBlock() }
    }

    private func checkIntegrity(_ block: ActiveBlock, now: Date) {
        let hostsOK = block.isAllowlist || HostsFileEditor(path: paths.hosts).containsBlock()
        let anchorOK = FileManager.default.fileExists(atPath: paths.pfAnchor)
        let pfOK = PacketFilter.blockFound(paths: paths) && anchorOK

        if !(hostsOK && pfOK) {
            log("INFO: Block is missing in pf or hosts, re-adding...")
            let engine = makeEngine(.init(block: block))
            engine.clearBlock()
            do { try installNetworkRules(for: block) } catch { log("ERROR: re-adding block failed: \(error)") }
            SystemMaintenance.clearCachesIfRequested(block.options, paths: paths, runner: runner)
            lastHeavyCheck = now
            return
        }

        if now.timeIntervalSince(lastHeavyCheck) >= 15 {
            lastHeavyCheck = now
            let pf = PacketFilter(isAllowlist: block.isAllowlist, paths: paths, runner: runner)
            if !pf.isEnabled() {
                log("INFO: pf was disabled during a block; re-enabling.")
                pf.reenable()
            }
        }
    }

    // MARK: Schedules

    private func fireDueSchedules(now: Date) {
        for schedule in state.schedules where schedule.enabled {
            guard let window = schedule.window(containing: now, calendar: calendar) else { continue }
            let key = schedule.id.uuidString
            if let last = state.scheduleFires[key], last >= window.start { continue }
            // Skip slivers: starting a block with seconds left is pointless.
            guard window.end.timeIntervalSince(now) >= 30 else { continue }

            let attemptKey = key + "@" + String(window.start.timeIntervalSince1970)
            let attempts = scheduleAttempts[attemptKey]
            if let attempts, now < attempts.retryAt { continue }

            // Recorded together with the block when it starts; undone below if it doesn't.
            let previousFire = state.scheduleFires[key]
            state.scheduleFires[key] = window.start
            let request = BlockRequest(entries: schedule.profile.entries, isAllowlist: schedule.profile.isAllowlist,
                                       endDate: window.end, apps: schedule.profile.apps, options: schedule.options,
                                       profileName: schedule.profile.name,
                                       source: .schedule(id: schedule.id, name: schedule.name))
            do {
                try startBlock(request)
                scheduleAttempts.removeValue(forKey: attemptKey)
                log("INFO: Schedule '\(schedule.name)' started a block.")
            } catch {
                // A transient failure (pfctl busy, DNS down) shouldn't cost the whole window.
                let count = (attempts?.count ?? 0) + 1
                scheduleAttempts[attemptKey] = (count, now.addingTimeInterval(SchedulePolicy.retryInterval))
                state.scheduleFires[key] = previousFire
                if count >= SchedulePolicy.maxStartAttempts {
                    state.scheduleFires[key] = window.start        // give up on this window
                    try? persist()
                    log("ERROR: Schedule '\(schedule.name)' failed to start \(count) times; skipping this window: \(error.localizedDescription)")
                } else {
                    log("WARNING: Schedule '\(schedule.name)' couldn't start (attempt \(count)): \(error.localizedDescription)")
                }
            }
            return // one block at a time
        }
    }
}
