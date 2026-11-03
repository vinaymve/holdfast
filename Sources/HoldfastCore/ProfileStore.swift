// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import Foundation

/// Per-user profiles (named blocklists). Shared by the app and CLI.
/// Profiles are just templates; the block itself is snapshotted into the daemon when it starts.
public final class ProfileStore {
    public let url: URL

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Holdfast/profiles.json")
    }

    public init(url: URL = ProfileStore.defaultURL) {
        self.url = url
    }

    /// Profiles saved by the first development build (before the rename).
    private var legacyURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SelfControl/profiles.json")
    }

    public func load() -> [Profile] {
        let source = FileManager.default.fileExists(atPath: url.path) ? url : legacyURL
        guard let data = try? Data(contentsOf: source),
              let profiles = try? Coding.decoder().decode([Profile].self, from: data), !profiles.isEmpty else {
            return Presets.starterProfiles
        }
        return profiles
    }

    public func save(_ profiles: [Profile]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? Coding.encoder().encode(profiles) { try? data.write(to: url, options: .atomic) }
    }
}

extension BlockedApp {
    /// Reads name and bundle id from an .app bundle on disk.
    public init?(appURL: URL) {
        let bundle = Bundle(url: appURL)
        guard appURL.pathExtension == "app", let bundle else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? appURL.deletingPathExtension().lastPathComponent
        self.init(bundleID: bundle.bundleIdentifier ?? "", name: name, path: appURL.path)
    }
}
