// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import SwiftUI
import HoldfastCore

@main
struct HoldfastApp: App {
    @State private var model = AppModel()

    #if DEBUG
    /// Dev hook (debug builds only): `-forceDark YES` previews dark mode without changing the system setting.
    private static var forcedScheme: ColorScheme? { UserDefaults.standard.bool(forKey: "forceDark") ? .dark : nil }
    #else
    private static var forcedScheme: ColorScheme? { nil }
    #endif

    var body: some Scene {
        Window("Holdfast", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 600)
                .tint(Theme.accent)
                .preferredColorScheme(Self.forcedScheme)
                .task { model.start() }
        }
        .defaultSize(width: 900, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarContent().environment(model)
        } label: {
            MenuBarLabel().environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(model)
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                BrandHeader()
                VStack(spacing: 2) {
                    ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { index, section in
                        SidebarRow(section: section, isSelected: model.section == section, shortcut: index + 1) { model.section = section }
                    }
                }
                .padding(.horizontal, 10)
                Spacer()
                if let block = model.activeBlock {
                    SidebarTimer(remaining: block.remaining(at: model.now))
                        .padding(12)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .background(Theme.sidebar)
        } detail: {
            Group {
                switch model.section {
                case .block: BlockView()
                case .profiles: ProfilesView()
                case .schedules: SchedulesView()
                case .stats: StatsView()
                }
            }
            .background(Theme.paper)
            .toolbarBackground(.hidden, for: .windowToolbar)
        }
    }
}

private struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 30, height: 30)
            Text("Holdfast")
                .font(Theme.display(20))
                .foregroundStyle(Theme.ink)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 16)
    }
}

private struct SidebarRow: View {
    let section: AppSection
    let isSelected: Bool
    /// Command-N switches to this section; the rows themselves stay out of the Tab order so no stray focus ring sits on them.
    let shortcut: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Theme.ink : Theme.inkSecondary)
                Text(section.title)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.ink : Theme.inkSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(isSelected ? Theme.raised : hovering ? Theme.raised.opacity(0.55) : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .strokeBorder(isSelected ? Theme.hairline : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .focusable(false)
        .keyboardShortcut(KeyEquivalent(Character(String(shortcut))), modifiers: .command)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SidebarTimer: View {
    let remaining: TimeInterval

    var body: some View {
        HStack(spacing: 8) {
            StatusDot()
            Text(Format.clock(remaining))
                .font(Theme.display(18, weight: .medium))
                .foregroundStyle(Theme.ink)
                .contentTransition(.numericText(countsDown: true))
            Spacer(minLength: 0)
            Text("left").font(.system(size: 12)).foregroundStyle(Theme.inkSecondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
        .hairline(radius: Theme.controlRadius)
    }
}
