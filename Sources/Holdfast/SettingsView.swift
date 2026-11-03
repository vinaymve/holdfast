// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import SwiftUI
import AppKit
import HoldfastCore

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            BlockingSettings().tabItem { Label("Blocking", systemImage: "shield") }
            HelperSettings().tabItem { Label("Helper", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 500, height: 360)
    }
}

private struct GeneralSettings: View {
    @AppStorage(Pref.maxBlockMinutes) private var maxBlockMinutes = 1440
    @AppStorage(Pref.notifyOnEnd) private var notifyOnEnd = true
    @AppStorage(Pref.playEndSound) private var playEndSound = false
    @AppStorage(Pref.endSoundName) private var endSoundName = "Glass"
    @AppStorage(Pref.suppressLongBlockWarning) private var suppressLongWarning = false

    var body: some View {
        Form {
            Picker("Longest block allowed", selection: $maxBlockMinutes) {
                Text("1 hour").tag(60)
                Text("4 hours").tag(240)
                Text("8 hours").tag(480)
                Text("24 hours").tag(1440)
                Text("3 days").tag(4320)
                Text("7 days").tag(10080)
            }
            Text("A safety limit for the length picker. Shorter limits make it harder to start a block by mistake.")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("Notify me when a block ends", isOn: $notifyOnEnd)
            Toggle("Play a sound when a block ends", isOn: $playEndSound)
            Picker("Sound", selection: $endSoundName) {
                ForEach(Pref.soundNames, id: \.self) { Text($0).tag($0) }
            }
            .disabled(!playEndSound)
            .onChange(of: endSoundName) { _, name in NSSound(named: NSSound.Name(name))?.play() }

            Toggle("Warn before starting very long blocks", isOn: Binding(get: { !suppressLongWarning }, set: { suppressLongWarning = !$0 }))
        }
        .formStyle(.grouped)
    }
}

private struct BlockingSettings: View {
    @AppStorage(Pref.clearCaches) private var clearCaches = true
    @AppStorage(Pref.allowLocalNetworks) private var allowLocal = true
    @AppStorage(Pref.evaluateCommonSubdomains) private var commonSubdomains = true
    @AppStorage(Pref.includeLinkedDomains) private var linked = true

    var body: some View {
        Form {
            Toggle("Clear browser caches when a block starts", isOn: $clearCaches)
            Text("Stops already-loaded pages from being shown from cache.").font(.caption).foregroundStyle(.secondary)

            Toggle("Block common subdomains (like www.) automatically", isOn: $commonSubdomains)
            Toggle("Allow connections to local networks", isOn: $allowLocal)
            Text("Only affects allowlist blocks.").font(.caption).foregroundStyle(.secondary)

            Toggle("Also allow sites linked from allowlisted pages", isOn: $linked)
            Text("Only affects allowlist blocks. Helps pages that load assets from other hosts.").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct HelperSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            LabeledContent("Status", value: statusText)
            LabeledContent("Location", value: SC.helperPath)
            LabeledContent("Version", value: SC.version)

            HStack {
                Button(model.helper == .notInstalled ? "Install Helper" : "Reinstall Helper") {
                    Task { await model.installHelper() }
                }
                Button("Remove Helper", role: .destructive) {
                    Task { await model.uninstallHelper() }
                }
                .disabled(model.helper == .notInstalled || model.activeBlock != nil)
            }
            .disabled(model.isBusy)

            if model.activeBlock != nil {
                Text("The helper can't be removed while a block is running.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .errorAlert(Bindable(model).errorMessage)
    }

    private var statusText: String {
        switch model.helper {
        case .checking: return "Checking…"
        case .notInstalled: return "Not installed"
        case .notRunning: return "Installed, not responding"
        case .outdated: return "Installed, update available"
        case .ready: return "Running"
        }
    }
}
