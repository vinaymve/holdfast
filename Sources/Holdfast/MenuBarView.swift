// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import SwiftUI
import HoldfastCore

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let block = model.activeBlock {
            HStack(spacing: 4) {
                Image(systemName: "lock.shield.fill")
                Text(Format.clock(block.remaining(at: model.now))).monospacedDigit()
            }
        } else {
            Image(systemName: "shield.lefthalf.filled")
        }
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let block = model.activeBlock {
                running(block)
            } else {
                idle
            }
            Divider()
            HStack {
                Button("Open Holdfast") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.link)
        }
        .padding(16)
        .frame(width: 320)
        .background(Theme.paper)
        .tint(Theme.accent)
    }

    private func running(_ block: ActiveBlock) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusDot()
                Text("Blocking" + (block.profileName.map { " · \($0)" } ?? ""))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ink)
            }
            Text(Format.clock(block.remaining(at: model.now)))
                .font(Theme.display(40, weight: .medium))
                .foregroundStyle(Theme.ink)
                .contentTransition(.numericText(countsDown: true))
            TimeBar(progress: block.progress(at: model.now))
            Text("Ends at \(block.displayEnd.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.inkSecondary)
        }
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 12) {
            Heading("Quick start")
            Picker("Profile", selection: Binding(get: { model.selectedProfile?.id ?? UUID() }, set: { model.selectProfile($0) })) {
                ForEach(model.profiles) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            HStack(spacing: 6) {
                ForEach([(30, "30 min"), (60, "1 hour"), (120, "2 hours"), (240, "4 hours")], id: \.0) { minutes, title in
                    Button(title) { Task { await model.startBlock(minutes: minutes) } }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(model.isBusy || (model.selectedProfile?.isEmpty ?? true))
                }
            }
            if let schedule = nextSchedule {
                Text("Next: \(schedule.name), \(schedule.start.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
    }

    private var nextSchedule: (name: String, start: Date)? {
        model.state.schedules
            .compactMap { s in s.nextStart(after: model.now).map { (s.name, $0) } }
            .min { $0.1 < $1.1 }
    }
}
