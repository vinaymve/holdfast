// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import SwiftUI
import UniformTypeIdentifiers
import HoldfastCore

struct ProfilesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(model.profiles, selection: $selection) { profile in
                    Label(profile.name, systemImage: profile.symbol).tag(profile.id)
                }
                .listStyle(.sidebar)
                Divider()
                HStack(spacing: 4) {
                    Button { selection = model.addProfile().id } label: { Image(systemName: "plus") }
                        .help("New profile")
                    Button {
                        if let id = selection { model.deleteProfile(id); selection = model.profiles.first?.id }
                    } label: { Image(systemName: "minus") }
                        .help("Delete profile")
                        .disabled(selection == nil)
                    Spacer()
                    Button {
                        if let p = selected { model.duplicateProfile(p) }
                    } label: { Image(systemName: "plus.square.on.square") }
                        .help("Duplicate profile")
                        .disabled(selected == nil)
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(width: 210)

            Divider()

            if let profile = selected {
                ProfileEditor(profile: profile)
                    .id(profile.id)
            } else {
                ContentUnavailableView("Select a profile", systemImage: "list.bullet.rectangle")
            }
        }
        .navigationTitle("Profiles")
        .onAppear { selection = model.selectedProfile?.id }
        .onChange(of: selection) { _, id in if let id { model.selectProfile(id) } }
    }

    private var selected: Profile? { model.profiles.first { $0.id == selection } }
}

struct ProfileEditor: View {
    @Environment(AppModel.self) private var model
    @State private var profile: Profile
    @State private var newSite = ""

    private static let symbols = ["shield.lefthalf.filled", "bubble.left.and.bubble.right.fill", "newspaper.fill", "play.rectangle.fill",
                                  "gamecontroller.fill", "briefcase.fill", "book.fill", "moon.fill", "cart.fill", "brain.head.profile"]

    init(profile: Profile) {
        _profile = State(initialValue: profile)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $profile.name)
                Picker("Icon", selection: $profile.symbol) {
                    ForEach(Self.symbols, id: \.self) { Label("", systemImage: $0).tag($0) }
                }
                .pickerStyle(.menu)
                Picker("Mode", selection: $profile.isAllowlist) {
                    Text("Blocklist: block these sites").tag(false)
                    Text("Allowlist: block everything except these sites").tag(true)
                }
                if profile.isAllowlist {
                    Label("Allowlist blocks all other internet access, including apps. Sites can't be added once the block has started.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                HStack {
                    TextField(profile.isAllowlist ? "Add an allowed site" : "Add a site to block", text: $newSite)
                        .onSubmit(addSites)
                    Button("Add", action: addSites).disabled(newSite.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if profile.entries.isEmpty {
                    Text(profile.isAllowlist ? "With no sites, an allowlist block cuts off the internet entirely." : "No sites yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(profile.entries.enumerated()), id: \.offset) { index, entry in
                        HStack {
                            if BlockEntry.parse(entry) == nil {
                                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                                    .help("This isn't a valid site and will be ignored.")
                            }
                            Text(entry).font(.body.monospaced())
                            Spacer()
                            Button { profile.entries.remove(at: index) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Sites (\(profile.entries.count))")
                    Spacer()
                    Menu("Import") {
                        Button("Common distracting websites") { merge(Presets.commonDistractingWebsites) }
                        Button("News and publications") { merge(Presets.newsAndPublications) }
                        Divider()
                        Button("Clear all sites", role: .destructive) { profile.entries = [] }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            } footer: {
                Text("Use a domain (example.com), domain:port, an IP, or a range like 10.0.0.0/8.")
            }

            Section {
                if profile.apps.isEmpty {
                    Text("No apps. Blocked apps are quit the moment they open, for the whole block.")
                        .foregroundStyle(.secondary)
                }
                ForEach(profile.apps) { app in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 24, height: 24)
                        Text(app.name)
                        Spacer()
                        Button { profile.apps.removeAll { $0.id == app.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Add App…", systemImage: "plus", action: pickApps)
            } header: {
                Text("Apps (\(profile.apps.count))")
            } footer: {
                Text("Blocked apps are force-quit, so unsaved work in them is lost. Finder, Dock and system UI can't be blocked.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: profile) { _, new in model.updateProfile(new) }
    }

    private func addSites() {
        let parts = newSite.split(whereSeparator: { $0.isNewline || $0 == "," || $0 == " " }).map(String.init)
        merge(parts)
        newSite = ""
    }

    private func merge(_ entries: [String]) {
        let existing = Set(profile.entries)
        profile.entries += entries.filter { !existing.contains($0) }
    }

    private func pickApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Block"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let app = BlockedApp(appURL: url) else { continue }
            if app.isProtected {
                model.errorMessage = "\(app.name) can't be blocked: it's required for macOS to work."
            } else if !profile.apps.contains(where: { $0.id == app.id }) {
                profile.apps.append(app)
            }
        }
    }
}
