// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import Foundation

/// `holdfastd --emergency-clear`: the escape hatch if something goes wrong.
///
/// The running daemon must be stopped *first*. It keeps the block in memory and re-installs missing rules within a
/// second, so clearing rules and editing the state file underneath it would just put the block straight back.
public struct EmergencyClear {
    private let paths: SystemPaths
    private let runner: CommandRunner

    public init(paths: SystemPaths = .production, runner: CommandRunner = ProcessRunner()) {
        self.paths = paths
        self.runner = runner
    }

    /// Returns true if every rule was verifiably removed. Schedules and history are kept.
    @discardableResult
    public func run() -> Bool {
        runner.run("/bin/launchctl", ["bootout", "system/\(SC.serviceName)"])

        let engine = BlockEngine(config: .init(isAllowlist: false), paths: paths, runner: runner,
                                 resolver: SystemResolver(), scraper: NoScraper())
        let cleared = engine.forceClearBlock()

        let store = StateStore(path: paths.state)
        var state = store.load()
        state.activeBlock = nil
        try? store.save(state)
        try? FileManager.default.removeItem(atPath: paths.state + ".clock")

        runner.run("/bin/launchctl", ["bootstrap", "system", SC.launchDaemonPlistPath])
        return cleared
    }
}
