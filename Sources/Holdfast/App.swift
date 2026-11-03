// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import SwiftUI
import HoldfastCore

@main
struct HoldfastApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Holdfast", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 600)
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
        @Bindable var model = model
        NavigationSplitView {
            List(AppSection.allCases, selection: Binding(get: { model.section }, set: { model.section = $0 ?? .block })) { section in
                Label(section.title, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
            .safeAreaInset(edge: .bottom) {
                if let block = model.activeBlock {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.shield.fill")
                        Text(Format.clock(block.remaining(at: model.now))).monospacedDigit()
                    }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(10)
                    .frame(maxWidth: .infinity)
                }
            }
        } detail: {
            switch model.section {
            case .block: BlockView()
            case .profiles: ProfilesView()
            case .schedules: SchedulesView()
            case .stats: StatsView()
            }
        }
    }
}
