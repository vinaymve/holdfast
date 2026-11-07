// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import Foundation
import Security

/// Installs the daemon as a root LaunchDaemon with a single admin prompt.
///
/// The original used SMJobBless, which needs a Developer ID signature that matches the helper's embedded
/// requirement. This install path works unsigned; the trade-off is that trust in the bundled helper binary
/// rests on the app bundle's own integrity. For distribution, sign everything and move to SMAppService.
public enum HelperInstaller {
    public static func launchDaemonPlist(label: String = SC.serviceName, helperPath: String = SC.helperPath) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(helperPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>MachServices</key>
            <dict>
                <key>\(label)</key>
                <true/>
            </dict>
            <key>Nice</key>
            <integer>5</integer>
        </dict>
        </plist>

        """
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The script run as root. The source binary lives in the app bundle, which the (unprivileged) user can write to,
    /// so it is treated as untrusted: refused if it's a symlink (it could point at a root-only file, which would then
    /// be copied somewhere world-readable), copied to a root-only staging file, and verified *there* before it's moved
    /// into place. Signed builds must carry the same Team ID as the app; unsigned dev builds are only checked to be a
    /// real executable.
    static func installScript(sourceBinary: String, expectedTeamID: String? = nil) -> String {
        let plistB64 = Data(launchDaemonPlist().utf8).base64EncodedString()
        let helper = shellQuote(SC.helperPath)
        let staged = shellQuote(SC.helperPath + ".new")
        let plist = shellQuote(SC.launchDaemonPlistPath)
        let source = shellQuote(sourceBinary)

        var lines = [
            "set -e",
            "umask 077",
            "if [ ! -f \(source) ] || [ -L \(source) ]; then echo 'The bundled helper is missing or is a symlink.' >&2; exit 4; fi",
            "/bin/mkdir -p /Library/PrivilegedHelperTools \(shellQuote(SC.supportDirectory))",
            "/bin/cp -f \(source) \(staged)",
            "/usr/sbin/chown root:wheel \(staged)",
            "/bin/chmod 700 \(staged)",
        ]
        if let team = expectedTeamID, team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil {
            lines += [
                "/usr/bin/codesign --verify --strict \(staged) || { /bin/rm -f \(staged); echo 'The helper signature is invalid.' >&2; exit 5; }",
                "TEAM=$(/usr/bin/codesign -dv \(staged) 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p')",
                "[ \"$TEAM\" = '\(team)' ] || { /bin/rm -f \(staged); echo 'The helper was not signed by the same team as the app.' >&2; exit 5; }",
            ]
        } else {
            lines.append("/usr/bin/file -b \(staged) | /usr/bin/grep -q 'Mach-O' || { /bin/rm -f \(staged); echo 'The bundled helper is not an executable.' >&2; exit 5; }")
        }
        lines += [
            "/bin/chmod 755 \(staged)",
            "/bin/mv -f \(staged) \(helper)",
            "/bin/echo \(shellQuote(plistB64)) | /usr/bin/base64 -D > \(plist)",
            "/usr/sbin/chown root:wheel \(plist)",
            "/bin/chmod 644 \(plist)",
            "/bin/launchctl bootout system/\(SC.serviceName) >/dev/null 2>&1 || true",
            "/bin/launchctl bootstrap system \(plist)",
            // Best effort: retire the helper from the first development build, unless it's mid-block.
            "if [ -x \(shellQuote(SC.legacyHelperPath)) ] && \(shellQuote(SC.legacyHelperPath)) --can-uninstall; then",
            "  /bin/launchctl bootout system/\(SC.legacyServiceName) >/dev/null 2>&1 || true",
            "  /bin/rm -f \(shellQuote(SC.legacyLaunchDaemonPlistPath)) \(shellQuote(SC.legacyHelperPath))",
            "fi",
        ]
        return lines.joined(separator: "\n")
    }

    /// Team ID of the running app, or nil for ad-hoc / unsigned builds.
    static func currentTeamID() -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any], let team = dict[kSecCodeInfoTeamIdentifier as String] as? String else { return nil }
        return team
    }

    static func uninstallScript() -> String {
        let helper = shellQuote(SC.helperPath)
        return [
            "if [ -x \(helper) ]; then \(helper) --can-uninstall || { echo 'A block is still running.' >&2; exit 3; }; fi",
            "/bin/launchctl bootout system/\(SC.serviceName) >/dev/null 2>&1 || true",
            "/bin/rm -f \(shellQuote(SC.launchDaemonPlistPath)) \(helper)",
        ].joined(separator: "\n")
    }

    private static let exitMarker = "__HOLDFAST_EXIT:"

    /// Splits the output of a wrapped admin script into the script's own output and its exit status.
    static func parseAdminOutput(_ raw: String) -> (status: Int, output: String) {
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        guard let last = lines.last, last.hasPrefix(exitMarker), let status = Int(last.dropFirst(exitMarker.count)) else {
            return (-1, raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        lines.removeLast()
        return (status, lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private typealias ExecuteWithPrivileges = @convention(c) (
        AuthorizationRef, UnsafePointer<CChar>, AuthorizationFlags,
        UnsafePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
    ) -> OSStatus

    /// Runs a shell script as root through Authorization Services, the same system prompt (password or Touch ID) as
    /// the block's own authorization, instead of a separate AppleScript dialog. `authorization` lets the caller reuse
    /// a session it already authenticated, so the user isn't asked twice.
    ///
    /// AuthorizationExecuteWithPrivileges is deprecated and hidden from Swift, so it's looked up at runtime. It is
    /// the only Authorization Services call that runs a tool as root without a signed, bundled helper.
    static func runAsAdmin(_ script: String, authorization: SCAuthorization.Ticket? = nil) throws {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "AuthorizationExecuteWithPrivileges") else {
            throw SCError(.installFailed, "This version of macOS no longer supports installing the helper this way.")
        }
        let execute = unsafeBitCast(symbol, to: ExecuteWithPrivileges.self)
        let session = try authorization ?? SCAuthorization.makeSession()
        guard let ref = session.authRef else { throw SCError(.notAuthorized, "(couldn't create an authorization session)") }

        let wrapped = "exec 2>&1\n( \(script)\n)\necho \"\(exitMarker)$?\""
        let argStrings: [String] = ["-c", wrapped]
        var args: [UnsafeMutablePointer<CChar>?] = argStrings.map { strdup($0) }
        args.append(nil)
        defer { args.forEach { free($0) } }

        var pipe: UnsafeMutablePointer<FILE>?
        let status = args.withUnsafeBufferPointer { execute(ref, "/bin/sh", [], $0.baseAddress, &pipe) }
        guard status == errAuthorizationSuccess, let pipe else {
            switch status {
            case errAuthorizationCanceled: throw SCError(.notAuthorized, "The install was cancelled.")
            case errAuthorizationDenied: throw SCError(.notAuthorized, "The password wasn't accepted, or this account isn't an administrator.")
            default: throw SCError(.installFailed, "(authorization error \(status))")
            }
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = fread(&buffer, 1, buffer.count, pipe)
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
        }
        fclose(pipe)

        let result = parseAdminOutput(String(decoding: data, as: UTF8.self))
        guard result.status == 0 else { throw SCError(.installFailed, result.output) }
    }

    public static func install(bundledHelper: URL, authorization: SCAuthorization.Ticket? = nil) async throws {
        let team = currentTeamID()
        let script = installScript(sourceBinary: bundledHelper.path, expectedTeamID: team)
        try await Task.detached { try runAsAdmin(script, authorization: authorization) }.value
    }

    public static func uninstall() async throws {
        try await Task.detached { try runAsAdmin(uninstallScript()) }.value
    }

    public static var isInstalled: Bool { FileManager.default.fileExists(atPath: SC.helperPath) }

    /// True if the installed helper differs from the one bundled with this app.
    public static func isOutdated(comparedTo bundled: URL) -> Bool {
        !FileManager.default.contentsEqual(atPath: SC.helperPath, andPath: bundled.path)
    }
}
