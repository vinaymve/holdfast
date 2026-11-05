// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import Foundation

public enum SC {
    public static let version = "1.0.1"
    public static let serviceName = "dev.holdfast.daemon"
    public static let helperPath = "/Library/PrivilegedHelperTools/dev.holdfast.daemon"
    public static let launchDaemonPlistPath = "/Library/LaunchDaemons/dev.holdfast.daemon.plist"
    public static let supportDirectory = "/Library/Application Support/Holdfast"
    public static let stateFilePath = supportDirectory + "/state.json"

    // The first development build of this app was called "SelfControl (Swift)". Its helper is removed on install.
    public static let legacyServiceName = "dev.selfcontrol.swift.daemon"
    public static let legacyHelperPath = "/Library/PrivilegedHelperTools/dev.selfcontrol.swift.daemon"
    public static let legacyLaunchDaemonPlistPath = "/Library/LaunchDaemons/dev.selfcontrol.swift.daemon.plist"

    // New names (not "...startBlock"): the first release registered those with a broken rule definition, and an
    // existing right can only be edited by the exact code that created it.
    public static let startRight = "dev.holdfast.right.startBlock"
    public static let modifyRight = "dev.holdfast.right.modifyBlock"

    public static let configurationChangedNotification = "dev.holdfast.configurationChanged"

    // Deliberately different from the original SelfControl's markers ("# BEGIN SELFCONTROL BLOCK", pf anchor
    // "org.eyebeam", /etc/SelfControlPFToken). Sharing them would make this daemon "clean up" (i.e. tear down)
    // a block started by the original app, which can be installed side by side.
    public static let hostsBegin = "# BEGIN HOLDFAST BLOCK"
    public static let hostsEnd = "# END HOLDFAST BLOCK"
    public static let pfAnchorName = "dev.holdfast"

    /// Hard ceiling enforced by the daemon, independent of the UI's (lower, configurable) limit.
    public static let maxBlockSeconds: TimeInterval = 7 * 86_400
    /// A single "extend" call can add at most this much.
    public static let maxExtensionSeconds: TimeInterval = 86_400
}

/// Every file the engine touches, so tests and the dev daemon can run against a scratch directory.
public struct SystemPaths {
    public var hosts = "/etc/hosts"
    public var pfConf = "/etc/pf.conf"
    public var pfAnchor = "/etc/pf.anchors/\(SC.pfAnchorName)"
    public var pfToken = "/etc/HoldfastPFToken"
    public var state = SC.stateFilePath
    public var usersDirectory = "/Users"
    public var pfctl = "/sbin/pfctl"
    /// When true, system-wide side effects (DNS flush, cache deletion, pf status polling) are skipped.
    public var isSandbox = false

    public init() {}

    public static let production = SystemPaths()

    /// Scratch layout under `root`, seeded with default hosts and pf.conf files.
    public static func sandbox(root: String) throws -> SystemPaths {
        var p = SystemPaths()
        let fm = FileManager.default
        for dir in ["etc/pf.anchors", "support", "Users"] {
            try fm.createDirectory(atPath: root + "/" + dir, withIntermediateDirectories: true)
        }
        p.hosts = root + "/etc/hosts"
        p.pfConf = root + "/etc/pf.conf"
        p.pfAnchor = root + "/etc/pf.anchors/\(SC.pfAnchorName)"
        p.pfToken = root + "/etc/HoldfastPFToken"
        p.state = root + "/support/state.json"
        p.usersDirectory = root + "/Users"
        p.isSandbox = true
        if !fm.fileExists(atPath: p.hosts) {
            try HostsFileEditor.defaultContents.write(toFile: p.hosts, atomically: true, encoding: .utf8)
        }
        if !fm.fileExists(atPath: p.pfConf) {
            try "scrub-anchor \"com.apple/*\"\nnat-anchor \"com.apple/*\"\n".write(toFile: p.pfConf, atomically: true, encoding: .utf8)
        }
        return p
    }
}

public struct SCError: Error, LocalizedError, CustomNSError, Equatable {
    public enum Code: Int {
        case busy = 300
        case blockAlreadyRunning = 301
        case invalidRequest = 302
        case noBlockRunning = 304
        case allowlistCannotBeUpdated = 305
        case endDateInPast = 308
        case extensionTooLong = 309
        case notAuthorized = 310
        case installFailed = 311
        case helperUnavailable = 312
        case invalidSchedule = 313
        case ioFailure = 314
    }

    public let code: Code
    public let detail: String?

    public init(_ code: Code, _ detail: String? = nil) {
        self.code = code
        self.detail = detail
    }

    public static var errorDomain: String { "dev.holdfast" }
    public var errorCode: Int { code.rawValue }
    public var errorUserInfo: [String: Any] {
        var info: [String: Any] = [NSLocalizedDescriptionKey: errorDescription ?? "Unknown error"]
        if let detail { info["SCDetail"] = detail }
        return info
    }

    public var errorDescription: String? {
        let base: String
        switch code {
        case .busy: base = "The helper is busy. Please try again in a moment."
        case .blockAlreadyRunning: base = "A block is already running."
        case .invalidRequest: base = "The block request isn't valid."
        case .noBlockRunning: base = "No block is currently running."
        case .allowlistCannotBeUpdated: base = "Sites can't be added to an allowlist block that's already running."
        case .endDateInPast: base = "A block's end time can't be moved earlier."
        case .extensionTooLong: base = "A block can be extended by at most 24 hours at a time."
        case .notAuthorized: base = "Administrator authorization was not granted."
        case .installFailed: base = "The helper tool couldn't be installed."
        case .helperUnavailable: base = "Couldn't reach the Holdfast helper tool."
        case .invalidSchedule: base = "The schedule isn't valid."
        case .ioFailure: base = "A system file couldn't be updated."
        }
        if let detail, !detail.isEmpty { return base + " " + detail }
        return base
    }

    public var nsError: NSError { self as NSError }

    /// Rebuilds an `SCError` from an error that crossed the XPC boundary; other errors pass through.
    public static func unwrap(_ error: Error) -> Error {
        let ns = error as NSError
        if ns.domain == errorDomain, let code = Code(rawValue: ns.code) {
            return SCError(code, ns.userInfo["SCDetail"] as? String)
        }
        return error
    }
}
