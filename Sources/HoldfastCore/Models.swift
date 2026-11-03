// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import Foundation

public struct BlockOptions: Codable, Equatable, Hashable {
    public var clearCaches = true
    public var allowLocalNetworks = true
    public var evaluateCommonSubdomains = true
    public var includeLinkedDomains = true
    public var playEndSound = false
    public var endSoundName = "Glass"

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clearCaches = try c.decodeIfPresent(Bool.self, forKey: .clearCaches) ?? true
        allowLocalNetworks = try c.decodeIfPresent(Bool.self, forKey: .allowLocalNetworks) ?? true
        evaluateCommonSubdomains = try c.decodeIfPresent(Bool.self, forKey: .evaluateCommonSubdomains) ?? true
        includeLinkedDomains = try c.decodeIfPresent(Bool.self, forKey: .includeLinkedDomains) ?? true
        playEndSound = try c.decodeIfPresent(Bool.self, forKey: .playEndSound) ?? false
        endSoundName = try c.decodeIfPresent(String.self, forKey: .endSoundName) ?? "Glass"
    }
}

/// An application the daemon will refuse to let run during a block.
public struct BlockedApp: Codable, Hashable, Identifiable {
    public var bundleID: String
    public var name: String
    /// Absolute path of the .app bundle; running processes are matched by executable path prefix.
    public var path: String

    public var id: String { bundleID.isEmpty ? path : bundleID }

    public init(bundleID: String, name: String, path: String) {
        self.bundleID = bundleID
        self.name = name
        self.path = path
    }

    private static let protectedBundleIDs: Set<String> = [
        "com.apple.finder", "com.apple.dock", "com.apple.loginwindow",
        "com.apple.systemuiserver", "com.apple.WindowServer", "com.apple.controlcenter",
        "dev.holdfast.app",
    ]
    private static let protectedPaths: [String] = [
        "/System/Library/CoreServices/Finder.app",
        "/System/Library/CoreServices/Dock.app",
        "/System/Library/CoreServices/loginwindow.app",
        "/System/Library/CoreServices/SystemUIServer.app",
        "/System/Library/CoreServices/ControlCenter.app",
    ]

    /// Apps that would wreck the session if killed (or that would defeat the point of the app).
    public var isProtected: Bool {
        Self.protectedBundleIDs.contains(bundleID) || Self.protectedPaths.contains(path)
    }

    /// An absolute path to something named "*.app". The daemon is the authority on this: it gets app lists over XPC
    /// and from saved schedules, and a path like "/" or "/Applications" would otherwise match every process.
    public var hasValidBundlePath: Bool {
        guard path.hasPrefix("/") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let last = parts.last, last.hasSuffix(".app"), last.count > 4 else { return false }
        return !parts.contains("..") && !parts.contains(".")
    }

    /// Safe for the daemon to act on.
    public var isBlockable: Bool { !isProtected && hasValidBundlePath }
}

public enum BlockSource: Codable, Equatable, Hashable {
    case manual
    case schedule(id: UUID, name: String)

    public var label: String {
        switch self {
        case .manual: return "Manual"
        case .schedule(_, let name): return "Schedule: \(name)"
        }
    }
}

/// What the client asks the daemon to start.
public struct BlockRequest: Codable, Equatable {
    public var entries: [String]
    public var isAllowlist: Bool
    public var endDate: Date
    public var apps: [BlockedApp]
    public var options: BlockOptions
    public var profileName: String?
    public var source: BlockSource

    public init(entries: [String], isAllowlist: Bool, endDate: Date, apps: [BlockedApp] = [],
                options: BlockOptions = BlockOptions(), profileName: String? = nil, source: BlockSource = .manual) {
        self.entries = entries
        self.isAllowlist = isAllowlist
        self.endDate = endDate
        self.apps = apps
        self.options = options
        self.profileName = profileName
        self.source = source
    }
}

public struct ActiveBlock: Codable, Equatable {
    public var entries: [String]
    public var isAllowlist: Bool
    public var startDate: Date
    public var endDate: Date
    public var apps: [BlockedApp]
    public var options: BlockOptions
    public var profileName: String?
    public var source: BlockSource
    /// False for app-only blocks, which never touch /etc/hosts or pf.
    public var usesNetworkRules: Bool
    /// Trusted time minus the system clock. Non-zero if someone changed the date during the block.
    /// `endDate` is in trusted time; use `displayEnd` for the wall-clock moment the block really ends.
    public var clockOffset: TimeInterval = 0

    public init(request: BlockRequest, startDate: Date, usesNetworkRules: Bool) {
        entries = request.entries
        isAllowlist = request.isAllowlist
        endDate = request.endDate
        apps = request.apps
        options = request.options
        profileName = request.profileName
        source = request.source
        self.startDate = startDate
        self.usesNetworkRules = usesNetworkRules
    }

    /// `now` is the system clock; the block's own trusted time is derived from it.
    public func remaining(at now: Date) -> TimeInterval {
        max(0, endDate.timeIntervalSince(now.addingTimeInterval(clockOffset)))
    }

    public func progress(at now: Date) -> Double {
        let total = endDate.timeIntervalSince(startDate)
        guard total > 0 else { return 1 }
        return min(1, max(0, now.addingTimeInterval(clockOffset).timeIntervalSince(startDate) / total))
    }

    /// When the block ends according to the system clock as it reads right now.
    public var displayEnd: Date { endDate.addingTimeInterval(-clockOffset) }

    private enum CodingKeys: String, CodingKey {
        case entries, isAllowlist, startDate, endDate, apps, options, profileName, source, usesNetworkRules, clockOffset
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decode([String].self, forKey: .entries)
        isAllowlist = try c.decode(Bool.self, forKey: .isAllowlist)
        startDate = try c.decode(Date.self, forKey: .startDate)
        endDate = try c.decode(Date.self, forKey: .endDate)
        apps = try c.decode([BlockedApp].self, forKey: .apps)
        options = try c.decode(BlockOptions.self, forKey: .options)
        profileName = try c.decodeIfPresent(String.self, forKey: .profileName)
        source = try c.decode(BlockSource.self, forKey: .source)
        usesNetworkRules = try c.decode(Bool.self, forKey: .usesNetworkRules)
        clockOffset = try c.decodeIfPresent(TimeInterval.self, forKey: .clockOffset) ?? 0
    }
}

public struct HistoryEntry: Codable, Identifiable, Equatable {
    public var id: UUID
    public var startDate: Date
    public var endDate: Date
    public var profileName: String?
    public var source: BlockSource
    public var entryCount: Int
    public var appCount: Int
    public var isAllowlist: Bool

    public var duration: TimeInterval { max(0, endDate.timeIntervalSince(startDate)) }

    public init(id: UUID = UUID(), block: ActiveBlock, endedAt: Date) {
        self.id = id
        startDate = block.startDate
        endDate = endedAt
        profileName = block.profileName
        source = block.source
        entryCount = block.entries.count
        appCount = block.apps.count
        isAllowlist = block.isAllowlist
    }
}

/// A named, reusable set of sites and apps.
public struct Profile: Codable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var symbol: String
    public var entries: [String]
    public var isAllowlist: Bool
    public var apps: [BlockedApp]

    public init(id: UUID = UUID(), name: String, symbol: String = "shield.lefthalf.filled",
                entries: [String] = [], isAllowlist: Bool = false, apps: [BlockedApp] = []) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.entries = entries
        self.isAllowlist = isAllowlist
        self.apps = apps
    }

    public var isEmpty: Bool { entries.isEmpty && apps.isEmpty && !isAllowlist }
}

/// A recurring block window, e.g. weekdays 9:00-17:00. Stored in (and fired by) the root daemon.
public struct Schedule: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    /// `Calendar` weekday numbers: 1 = Sunday ... 7 = Saturday.
    public var weekdays: [Int]
    public var startHour: Int
    public var startMinute: Int
    public var durationMinutes: Int
    /// Snapshot of the profile taken when the schedule was saved.
    public var profile: Profile
    public var options: BlockOptions

    public init(id: UUID = UUID(), name: String, enabled: Bool = true, weekdays: [Int],
                startHour: Int, startMinute: Int, durationMinutes: Int, profile: Profile,
                options: BlockOptions = BlockOptions()) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.weekdays = weekdays
        self.startHour = startHour
        self.startMinute = startMinute
        self.durationMinutes = durationMinutes
        self.profile = profile
        self.options = options
    }
}

public struct BlockAddition: Codable {
    public var entries: [String]
    public var apps: [BlockedApp]

    public init(entries: [String] = [], apps: [BlockedApp] = []) {
        self.entries = entries
        self.apps = apps
    }
}

public struct DaemonState: Codable, Equatable {
    public var version: Int
    public var activeBlock: ActiveBlock?
    public var schedules: [Schedule]
    public var history: [HistoryEntry]
    /// Schedule id -> start of the window we last fired for (prevents double-firing a window).
    public var scheduleFires: [String: Date]

    public init(version: Int = 1, activeBlock: ActiveBlock? = nil, schedules: [Schedule] = [],
                history: [HistoryEntry] = [], scheduleFires: [String: Date] = [:]) {
        self.version = version
        self.activeBlock = activeBlock
        self.schedules = schedules
        self.history = history
        self.scheduleFires = scheduleFires
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        activeBlock = try c.decodeIfPresent(ActiveBlock.self, forKey: .activeBlock)
        schedules = try c.decodeIfPresent([Schedule].self, forKey: .schedules) ?? []
        history = try c.decodeIfPresent([HistoryEntry].self, forKey: .history) ?? []
        scheduleFires = try c.decodeIfPresent([String: Date].self, forKey: .scheduleFires) ?? [:]
    }
}

public enum Coding {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// Reads and writes daemon state. Only root (the daemon) can write the production file.
public final class StateStore {
    public let path: String
    private let lock = NSLock()

    public init(path: String = SC.stateFilePath) {
        self.path = path
    }

    public func load() -> DaemonState {
        lock.lock(); defer { lock.unlock() }
        guard let data = FileManager.default.contents(atPath: path) else { return DaemonState() }
        guard let state = try? Coding.decoder().decode(DaemonState.self, from: data) else {
            preserveCorruptFile(data)
            return DaemonState()
        }
        return state
    }

    /// An unreadable state file is about to be replaced by an empty one on the next save, which would lose the
    /// history and schedules (and the running block). Keep a copy first. Named by content so repeated reads
    /// (the app polls) don't pile up copies; a read-only caller simply can't write and skips this.
    private func preserveCorruptFile(_ data: Data) {
        var hash: UInt64 = 0xcbf29ce484222325               // FNV-1a
        for byte in data { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        let backup = path + ".corrupt-" + String(hash, radix: 16)
        guard !FileManager.default.fileExists(atPath: backup) else { return }
        try? data.write(to: URL(fileURLWithPath: backup))
    }

    public func save(_ state: DaemonState) throws {
        lock.lock(); defer { lock.unlock() }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Coding.encoder().encode(state)
        try data.write(to: url, options: .atomic)
        // World-readable so the app can show status without talking to the daemon; only root can write.
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
    }
}
