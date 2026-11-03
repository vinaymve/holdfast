// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import Foundation
import Darwin

public struct RunningProcess: Equatable {
    public let pid: Int32
    public let path: String
    public init(pid: Int32, path: String) {
        self.pid = pid
        self.path = path
    }
}

public protocol ProcessListing {
    func running() -> [RunningProcess]
}

public protocol ProcessSignaling {
    func terminate(_ pid: Int32)
    func kill(_ pid: Int32)
}

public struct SystemProcessList: ProcessListing, ProcessSignaling {
    public init() {}

    public func running() -> [RunningProcess] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) * 2)
        let bytes = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard bytes > 0 else { return [] }

        var result: [RunningProcess] = []
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(bytes)) where pid > 1 {
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            if length > 0 { result.append(RunningProcess(pid: pid, path: String(cString: buffer))) }
        }
        return result
    }

    public func terminate(_ pid: Int32) { Darwin.kill(pid, SIGTERM) }
    public func kill(_ pid: Int32) { Darwin.kill(pid, SIGKILL) }
}

/// Add-on: stops chosen apps from running for the length of a block.
/// Processes are matched by executable path inside the .app bundle, so helper processes go too.
/// The daemon calls `enforce` every second, so a relaunched app is gone again almost immediately.
public final class AppBlocker {
    private let lister: ProcessListing
    private let signaler: ProcessSignaling
    private let ownPID: Int32
    private var terminationSentAt: [Int32: Date] = [:]
    /// Grace period between SIGTERM and SIGKILL.
    public var killDelay: TimeInterval = 1.5

    public init(lister: ProcessListing = SystemProcessList(), signaler: ProcessSignaling = SystemProcessList(),
                ownPID: Int32 = getpid()) {
        self.lister = lister
        self.signaler = signaler
        self.ownPID = ownPID
    }

    /// The kernel reports canonical executable paths (e.g. /private/tmp/...), while the path the user picked
    /// may go through a symlink, so compare against both spellings.
    static func bundlePaths(for app: BlockedApp) -> [String] {
        guard app.hasValidBundlePath else { return [] }
        let trimmed = app.path.hasSuffix("/") ? String(app.path.dropLast()) : app.path
        let canonical = PathUtil.canonical(trimmed)
        return canonical == trimmed ? [trimmed] : [trimmed, canonical]
    }

    static func matches(_ process: RunningProcess, bundlePaths: [String]) -> Bool {
        bundlePaths.contains { process.path == $0 || process.path.hasPrefix($0 + "/") }
    }

    static func matches(_ process: RunningProcess, app: BlockedApp) -> Bool {
        matches(process, bundlePaths: bundlePaths(for: app))
    }

    // MARK: Matching by bundle identifier
    //
    // Path matching alone is defeated by copying or renaming the app, or by App Translocation. A running
    // process inside "X.app" is matched by that bundle's CFBundleIdentifier as well.

    private var bundleIDCache: [String: String] = [:]   // bundle root -> identifier ("" = none)
    private static let maxPlistBytes = 1_000_000

    /// Identifier of the outermost .app bundle containing `processPath`, if any.
    func bundleIdentifier(containing processPath: String) -> String? {
        guard let marker = processPath.range(of: ".app/") else { return nil }
        let root = String(processPath[..<processPath.index(before: marker.upperBound)])
        if let cached = bundleIDCache[root] { return cached.isEmpty ? nil : cached }
        if bundleIDCache.count > 2_000 { bundleIDCache.removeAll() }

        // This runs as root on files any user can create, so refuse anything that isn't a small regular file.
        let plist = root + "/Contents/Info.plist"
        var identifier = ""
        if let attrs = try? FileManager.default.attributesOfItem(atPath: plist),
           attrs[.type] as? FileAttributeType == .typeRegular,
           (attrs[.size] as? Int ?? .max) <= Self.maxPlistBytes,
           let dict = NSDictionary(contentsOfFile: plist), let id = dict["CFBundleIdentifier"] as? String {
            identifier = id
        }
        bundleIDCache[root] = identifier
        return identifier.isEmpty ? nil : identifier
    }

    /// Terminates matching processes and returns the pids it acted on.
    @discardableResult
    public func enforce(apps: [BlockedApp], now: Date = Date()) -> [Int32] {
        let targets = apps.filter(\.isBlockable)
        guard !targets.isEmpty else {
            terminationSentAt.removeAll()
            return []
        }

        let targetPaths = targets.map { Self.bundlePaths(for: $0) }
        let targetIDs = Set(targets.map(\.bundleID).filter { !$0.isEmpty })
        let processes = lister.running()
        let alive = Set(processes.map(\.pid))
        terminationSentAt = terminationSentAt.filter { alive.contains($0.key) }

        var acted: [Int32] = []
        for process in processes where process.pid != ownPID && process.pid > 1 {
            let byPath = targetPaths.contains { Self.matches(process, bundlePaths: $0) }
            let byID = !byPath && !targetIDs.isEmpty && bundleIdentifier(containing: process.path).map(targetIDs.contains) == true
            guard byPath || byID else { continue }
            if let sent = terminationSentAt[process.pid] {
                if now.timeIntervalSince(sent) >= killDelay {
                    signaler.kill(process.pid)
                    acted.append(process.pid)
                }
            } else {
                signaler.terminate(process.pid)
                terminationSentAt[process.pid] = now
                acted.append(process.pid)
            }
        }
        return acted
    }
}
