// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import Foundation

/// Port of SCHelperToolUtilities' cache clearing: so already-cached pages don't survive a block.
public enum SystemMaintenance {
    static let cacheSubpaths = [
        "Library/Caches/Google/Chrome/Default",
        "Library/Caches/Google/Chrome/com.google.Chrome",
        "Library/Caches/Firefox/Profiles",
        "Library/Caches/com.apple.Safari",
        "Library/Containers/com.apple.Safari/Data/Library/Caches",
    ]

    public static func clearBrowserCaches(paths: SystemPaths) {
        // Never let a sandboxed run delete the real users' caches.
        if paths.isSandbox && paths.usersDirectory == "/Users" { return }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: paths.usersDirectory) else { return }
        for name in names where !name.hasPrefix(".") && name != "Shared" {
            let home = "\(paths.usersDirectory)/\(name)"
            for sub in cacheSubpaths {
                guard let target = safeTarget(home: home, relativePath: sub) else { continue }
                try? fm.removeItem(atPath: target)
            }
        }
    }

    /// This runs as root over every user's home, and users control what's inside theirs. A planted symlink such as
    /// ~/Library/Caches/Firefox -> /Users/bob/Library/Application Support/Firefox would make root delete bob's
    /// profile. So resolve the real path first and only delete if it is still inside this user's own home.
    static func safeTarget(home: String, relativePath: String) -> String? {
        let realHome = PathUtil.canonical(home)
        guard PathUtil.canonical(home) != "/", FileManager.default.fileExists(atPath: realHome) else { return nil }
        let candidate = PathUtil.canonical(home + "/" + relativePath)
        // realpath returns its input unchanged if the path doesn't exist; there's nothing to delete then.
        guard FileManager.default.fileExists(atPath: candidate), candidate.hasPrefix(realHome + "/") else { return nil }
        return candidate
    }

    public static func flushDNS(paths: SystemPaths, runner: CommandRunner) {
        guard !paths.isSandbox else { return }
        runner.run("/usr/bin/dscacheutil", ["-flushcache"])
        runner.run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
        runner.run("/usr/bin/killall", ["mDNSResponderHelper"])
    }

    public static func clearCachesIfRequested(_ options: BlockOptions, paths: SystemPaths, runner: CommandRunner) {
        guard options.clearCaches else { return }
        clearBrowserCaches(paths: paths)
        flushDNS(paths: paths, runner: runner)
    }
}
