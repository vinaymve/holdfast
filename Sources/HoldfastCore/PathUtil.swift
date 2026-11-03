// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import Foundation
import Darwin

public enum PathUtil {
    /// The real on-disk path, via realpath(3). Foundation's `resolvingSymlinksInPath()` is not a substitute:
    /// it strips a leading "/private", but the kernel (proc_pidpath, etc.) reports "/private/tmp/...".
    public static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
