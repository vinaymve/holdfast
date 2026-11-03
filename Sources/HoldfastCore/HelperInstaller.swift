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

    /// Runs a shell script as root via the standard macOS admin prompt.
    static func runAsAdmin(_ script: String) throws {
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            if output.contains("-128") { throw SCError(.notAuthorized, "The install was cancelled.") }
            throw SCError(.installFailed, output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    public static func install(bundledHelper: URL) async throws {
        let team = currentTeamID()
        try await Task.detached { try runAsAdmin(installScript(sourceBinary: bundledHelper.path, expectedTeamID: team)) }.value
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
